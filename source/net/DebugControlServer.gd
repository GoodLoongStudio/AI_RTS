extends Node

## 调试控制端点：游戏内嵌 TCP 服务器，接受 JSON 指令操控对局。
## 两类指令：
##   1) 输入模拟：click/drag/key —— 合成真实 InputEvent 走引擎输入管线，
##      与玩家鼠标完全同路径(HUD/框选/相机拾取全部真实反应)。
##   2) 结构化命令：move/gather/build/produce/attack/status/screenshot。
## autoload 自挂载：带 --debugport 参数的进程（客户端/专用服均可）启用，
## 未带参数的进程（正常玩家/编辑器）在 _ready 自毁不监听；跨场景存活。

const DEFAULT_PORT := 24568

## ---------- 本机副官服务（2026-09-11 本地完整副官重构） ----------
## 背景：此前本节点在**未传 `--debugport`** 时直接 `queue_free()`，于是玩家从
## 正常入口进自定义对局时，本机 Python runner **没有任何数据通道**（观测读不到、
## 意图下不去），只能靠云端 daemon —— 与"本机全链路"目标冲突。
## 现在：正常启动也开放服务，但走**受限白名单**，只暴露副官所需的只读观测与控制 op，
## 不开放 click/drag/key 等输入模拟与其余调试能力（避免为方便副官而无条件开放全部调试操作）。
const ADJUTANT_PORT := 24579
const ADJUTANT_OPS := [
	"status", "tactical", "strategic", "rules", "commands",
	"adjutant_intent", "adjutant_batch", "adjutant_leases", "adjutant_reserves",
]
var _adjutant_only := false

var _server := TCPServer.new()
var _clients: Array = []
var _buffers := {}
var _port := DEFAULT_PORT

## 命令终态登记上限，防止无限增长（见 _record_command）。
const COMMAND_LOG_LIMIT := 64
## 最近命令终态记录：produce/build 两条转发路径与服务器直执行路径共用，
## 供副官按 command_id 在下一轮复核最终 Accepted/Rejected（PendingAuthority 不落账）。
var _command_log: Array = []

# ---------- 副官双层改造（第一阶段） ----------
## 副官幂等账本上限：满时显式拒绝新命令（LedgerFull），不静默遗忘未完成命令。
## 与 _command_log（展示历史，64 条）分离：去重能力不随展示历史裁剪丢失。
const ADJUTANT_LEDGER_LIMIT := 256

## C# AdjutantObservationRuntime 实例（_ready 动态挂载，不进场景文件）。
var _adjutant_observation: Node = null
## 幂等账本："<match_id>|<player_id>" -> {command_id: {"receipt": Dict, "params": String}}
var _adjutant_ledger := {}
## 副官控制租约："<match_id>|<player_id>" -> {unit_name: {"generation": int, "active": bool}}
var _adjutant_leases := {}
## 副官租约代际（对局内自增）；玩家手动命令使租约失效，重新接管需要显式授权。
var _adjutant_lease_generation := 0
## 规则视图缓存：match_id -> rules（Catalog 对局生命周期内不可变）。
var _adjutant_rules_cache := {}
## 敌情情报（last_seen）："<match_id>|<player_id>" -> {unit_name: intel_dict}
## 迷雾公平性：只记录该玩家自己视野确认过的敌情；失去视野冻结数据不更新，
## 不向模型提供 full_vision（旧 op=status 的 full_vision 参数保留兼容不变）。
var _adjutant_intel := {}
## 副官命令执行标志：复用旧 op 路径时避免把自己的命令误判为玩家手动接管。
var _adjutant_executing := false
## 意图登记表（LangGraph 战术意图）："<match_id>|<player_id>" -> {intent_id: record}。
## 只做校验留痕与幂等回放，不改变玩法：真正执行仍走 op=adjutant_command 的权威链。
var _adjutant_intents := {}
## 意图登记容量上限：满时显式拒绝新意图（背压），不静默遗忘未完成意图。
const ADJUTANT_INTENT_LIMIT := 128
## 副官资源预留（方案 §6）："<match_id>|<player_id>" -> {initialized, percent, values:{A,B}}。
## 预留是**玩家设定**：首次按当时余额的 20% 取整初始化，之后玩家可改，**不按剩余余额重算**；
## 关闭重开副官不清零（键挂在"对局身份"上），重开对局自然重建。
var _adjutant_reserves := {}
const ADJUTANT_RESERVE_PERCENT := 20


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	var port_index := args.find("--debugport")
	if port_index >= 0:
		# 显式调试模式：全量 op，端口由参数指定（自动化/联机测试用）。
		if port_index + 1 < args.size():
			_port = int(args[port_index + 1])
	elif not args.has("--no-adjutant"):
		# 正常启动：开放**受限**的本机副官服务（仅白名单 op），供本机 runner 使用。
		# `--no-adjutant` 可显式关闭（如纯观战/纯净启动）。
		_port = ADJUTANT_PORT
		_adjutant_only = true
	else:
		# autoload 模式下未请求调试、且显式关闭副官的进程直接退出，不占资源。
		queue_free()
		return
	if _server.listen(_port, "127.0.0.1") != OK:
		print("[DBGCTL] 端口 %d 被占用, 调试控制端点未启动" % _port)
		set_process(false)
		return
	_mount_adjutant_observation()
	print("[DBGCTL] 调试控制端点已启动 127.0.0.1:%d" % _port)


## 动态挂载 C# 副官观测运行时（规则导出 + 公共包头）。
## Mono 环境 set_script(load("....cs")) 模式已由 BalanceConfigRuntimeSmokeTest 验证。
func _mount_adjutant_observation() -> void:
	var script: Script = load(
		"res://source/csharp/GodotAdapter/Adjutant/AdjutantObservationRuntime.cs"
	) as Script
	if script == null:
		push_error("[DBGCTL] AdjutantObservationRuntime.cs 加载失败，副官 rules/tactical 端点不可用")
		return
	var node := Node.new()
	node.name = "AdjutantObservationRuntime"
	node.set_script(script)
	add_child(node)
	_adjutant_observation = node


func _process(_delta: float) -> void:
	if _server.is_connection_available():
		var client := _server.take_connection()
		_clients.append(client)
		_buffers[client.get_instance_id()] = ""
	for client in _clients.duplicate():
		if client.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			_buffers.erase(client.get_instance_id())
			_clients.erase(client)
			continue
		var available: int = client.get_available_bytes()
		if available > 0:
			_buffers[client.get_instance_id()] += client.get_utf8_string(available)
		var buffer: String = _buffers.get(client.get_instance_id(), "")
		while "\n" in buffer:
			var line_end := buffer.find("\n")
			var line := buffer.substr(0, line_end).strip_edges()
			buffer = buffer.substr(line_end + 1)
			if not line.is_empty():
				client.put_utf8_string(_dispatch(line) + "\n")
		_buffers[client.get_instance_id()] = buffer


func _dispatch(line: String) -> String:
	var parsed = JSON.parse_string(line)
	if parsed == null or not (parsed is Dictionary):
		return JSON.stringify({"error": "bad json"})
	# 正常启动下的受限模式：只允许副官所需的观测/控制 op，
	# 拒绝输入模拟（click/drag/key）等调试能力，避免副官常态化开启全量调试面。
	if _adjutant_only:
		var requested := str(parsed.get("op", ""))
		if requested not in ADJUTANT_OPS:
			return JSON.stringify({
				"error": "op not allowed in adjutant-only mode",
				"op": requested,
				"allowed": ADJUTANT_OPS,
			})
	var tree := get_tree()
	var match_node = tree.current_scene
	# 大厅阶段（无对局场景）也要能用的 op：只读查询 + 输入模拟（不依赖 match 节点）。
	# lobby 用于核验“同一台电脑只有一个指挥官”，screenshot/click/drag/key 用于大厅 UI 自动化。
	if parsed.get("op", "") not in ["status", "start", "lobby", "screenshot", "click", "drag",
			"key", "controller"] and (
		match_node == null or not match_node.has_method("get_local_player")
	):
		return JSON.stringify({"error": "no match scene"})
	match str(parsed.get("op", "")):
		"status":
			return JSON.stringify(_collect_status(match_node, parsed))
		"start":
			return _op_start(parsed)
		"click":
			return _op_click(parsed)
		"drag":
			return _op_drag(parsed)
		"key":
			return _op_key(parsed)
		"screenshot":
			return _op_screenshot(parsed)
		"fog":
			return _op_fog(match_node, parsed)
		"fog_status":
			return _op_fog_status(match_node)
		"move":
			return _op_move(match_node, parsed)
		"gather":
			return _op_gather(match_node, parsed)
		"build":
			return _op_build(match_node, parsed)
		"produce":
			return _op_produce(match_node, parsed)
		"attack":
			return _op_attack(match_node, parsed)
		"commands":
			return JSON.stringify({"ok": true, "commands": _query_commands(parsed)})
		"combat":
			return JSON.stringify({"ok": true, "combat": _combat_snapshot(match_node, parsed)})
		"force_attack":
			return _op_force_attack(match_node, parsed)
		"rules":
			return JSON.stringify(_op_rules(match_node))
		"tactical":
			return JSON.stringify(_op_tactical(match_node, parsed))
		"strategic":
			return JSON.stringify(_op_strategic(match_node, parsed))
		"adjutant_command":
			return JSON.stringify(_op_adjutant_command(match_node, parsed))
		"adjutant_batch":
			return JSON.stringify(_op_adjutant_batch(match_node, parsed))
		"adjutant_intent":
			return JSON.stringify(_op_adjutant_intent(match_node, parsed))
		"adjutant_leases":
			return JSON.stringify(_op_adjutant_leases(match_node, parsed))
		"adjutant_reserves":
			return JSON.stringify(_op_adjutant_reserves(match_node, parsed))
		"lobby":
			return JSON.stringify(_op_lobby())
		"controller":
			return _op_controller(parsed)
	return JSON.stringify({"error": "unknown op"})


# ---------- 输入模拟 ----------

func _synth_motion(x: float, y: float, button_mask: int = 0) -> void:
	var motion := InputEventMouseMotion.new()
	motion.position = Vector2(x, y)
	motion.global_position = Vector2(x, y)
	motion.button_mask = button_mask
	Input.parse_input_event(motion)


func _synth_button(x: float, y: float, button_index: int, pressed: bool, double_click := false) -> void:
	var button := InputEventMouseButton.new()
	button.button_index = button_index
	button.pressed = pressed
	button.position = Vector2(x, y)
	button.global_position = Vector2(x, y)
	button.double_click = double_click
	Input.parse_input_event(button)


func _op_click(parsed) -> String:
	var x := float(parsed.get("x", 0))
	var y := float(parsed.get("y", 0))
	var button_name := str(parsed.get("button", "left"))
	var button_index := MOUSE_BUTTON_LEFT
	if button_name == "right":
		button_index = MOUSE_BUTTON_RIGHT
	var double_click := bool(parsed.get("double", false))
	_synth_motion(x, y)
	_synth_button(x, y, button_index, true, double_click)
	_synth_button(x, y, button_index, false, double_click)
	return JSON.stringify({"ok": true, "clicked": [x, y], "button": button_name})


func _op_drag(parsed) -> String:
	var x1 := float(parsed.get("x1", 0))
	var y1 := float(parsed.get("y1", 0))
	var x2 := float(parsed.get("x2", 0))
	var y2 := float(parsed.get("y2", 0))
	_synth_motion(x1, y1)
	_synth_button(x1, y1, MOUSE_BUTTON_LEFT, true)
	var steps := 12
	for i in range(1, steps + 1):
		var t := float(i) / float(steps)
		_synth_motion(lerp(x1, x2, t), lerp(y1, y2, t), MOUSE_BUTTON_MASK_LEFT)
	_synth_button(x2, y2, MOUSE_BUTTON_LEFT, false)
	return JSON.stringify({"ok": true, "dragged": [[x1, y1], [x2, y2]]})


func _op_key(parsed) -> String:
	var key_event := InputEventKey.new()
	key_event.keycode = int(parsed.get("keycode", 0))
	key_event.physical_keycode = int(parsed.get("keycode", 0))
	key_event.pressed = true
	Input.parse_input_event(key_event)
	var release := key_event.duplicate()
	release.pressed = false
	Input.parse_input_event(release)
	return JSON.stringify({"ok": true, "key": int(parsed.get("keycode", 0))})


func _op_screenshot(parsed) -> String:
	var image := get_viewport().get_texture().get_image()
	var path := str(parsed.get("path", "user://debug_screenshot.png"))
	var absolute := path if path.is_absolute_path() else ProjectSettings.globalize_path(path)
	var error := image.save_png(absolute)
	return JSON.stringify({"ok": error == OK, "path": absolute, "size": [
		image.get_width(), image.get_height()
	]})


func _op_fog(match_node, parsed) -> String:
	if match_node == null:
		return JSON.stringify({"error": "no match scene"})
	var fog = match_node.get_node_or_null("FogOfWar")
	var visibility = match_node.get_node_or_null("UnitVisibilityHandler")
	if fog == null:
		return JSON.stringify({"error": "no fog of war"})
	var enabled := bool(parsed.get("enabled", not fog.visible))
	fog.visible = enabled
	if visibility != null:
		visibility.visible = enabled
	return JSON.stringify({"ok": true, "enabled": enabled})


func _op_fog_status(match_node) -> String:
	if match_node == null:
		return JSON.stringify({"error": "no match scene"})
	var fog = match_node.get_node_or_null("FogOfWar")
	var fog_viewport = fog.get_node_or_null("CombinedViewport/FogViewportContainer/FogViewport") if fog != null else null
	var revealed := 0
	for unit in get_tree().get_nodes_in_group("units"):
		if unit.is_in_group("revealed_units"):
			revealed += 1
	return JSON.stringify({
		"ok": true,
		"fog_visible": fog.visible if fog != null else false,
		"revealed_units": revealed,
		"mapped_units": int(fog.get("_unit_to_circles_mapping").size()) if fog != null else -1,
		"fog_circle_count": fog_viewport.get_child_count() if fog_viewport != null else -1,
		"viewport_size": [fog_viewport.size.x, fog_viewport.size.y] if fog_viewport != null else null,
	})


# ---------- 结构化命令 ----------

## 副官模式：以指定玩家身份执行命令。as_player 按玩家节点名（Player_N）
## 精确匹配；找不到或未指定时回退本地玩家。服务器权威进程没有本地玩家，
## 外部副官（如 Hermes Agent）全靠 as_player 指挥真人玩家的部队。
func _resolve_player(match_node, parsed):
	var player = match_node.get_local_player()
	var wanted := str(parsed.get("as_player", ""))
	if wanted.is_empty():
		return player
	for p in get_tree().get_nodes_in_group("players"):
		if str(p.name) == wanted:
			return p
	return player


func _is_human_player(p) -> bool:
	var script_path := str(p.get_script().resource_path) if p.get_script() != null else ""
	return "players/human/" in script_path


func _resolve_own_units(player, wanted: Array) -> Array:
	var nodes: Array = []
	for unit in get_tree().get_nodes_in_group("units"):
		if unit == null or not is_instance_valid(unit):
			continue
		if unit.get_parent() == player and unit.name in wanted:
			nodes.append(unit)
	return nodes


## op=controller：A/B 基线开关（GPT Q2(a)/Q6 授权）。
## `{"op":"controller","rule_ai_slot":0}` → 让 0 号槽在**下一局**由 SIMPLE_CLAIRVOYANT_AI 驱动；
## `rule_ai_slot=-1` 恢复默认（人类槽由玩家/副官控制）。
## 只改"控制器选择"，不动地图、经济规则、执行器与观测接口；默认 -1 时行为与从前完全一致。
func _op_controller(parsed) -> String:
	var slot := int(parsed.get("rule_ai_slot", -1))
	NetSession.force_rule_ai_slot = slot
	print("[DBGCTL] A/B 控制器开关: force_rule_ai_slot=%d（下一局生效）" % slot)
	return JSON.stringify({
		"ok": true,
		"force_rule_ai_slot": slot,
		"note": "下一局生效；-1 = 默认（不干预）",
	})


func _op_start(parsed) -> String:
	if not NetSession.is_networked():
		return JSON.stringify({"error": "not networked"})
	var with_ai := bool(parsed.get("with_ai", false))
	var passive_ai_test := bool(parsed.get("passive_ai_test", false))
	# peaceful：和平模式，AI 首波进攻延迟 600s —— 副官练发展与探索用。
	var peaceful := bool(parsed.get("peaceful", false))
	NetSession.start_solo(with_ai, passive_ai_test, peaceful)
	return JSON.stringify({
		"ok": true,
		"with_ai": with_ai,
		"passive_ai_test": passive_ai_test,
		"peaceful": peaceful,
	})

func _op_move(match_node, parsed) -> String:
	var player = _resolve_player(match_node, parsed)
	var gateway = NetSession.command_gateway_for(player)
	if gateway == null:
		return JSON.stringify({
			"ok": false,
			"accepted": false,
			"status": "NoGateway",
			"reason": "该玩家没有可用的命令网关（对局未就绪或角色不支持手动命令）。",
			"error": "no gateway",
		})
	var nodes := _resolve_own_units(player, parsed.get("units", []))
	if nodes.is_empty():
		return JSON.stringify({
			"ok": false,
			"accepted": false,
			"status": "UnitsNotFound",
			"reason": "找不到属于该玩家的移动单位，请先从 status 的 units 里选择我方单位。",
			"error": "no units",
		})
	var dest_raw: Array = parsed.get("dest", [0.0, 0.0])
	if dest_raw.is_empty():
		dest_raw = [0.0, 0.0]
	var destination := Vector3(float(dest_raw[0]), 0.0, float(dest_raw[1]))
	var result: Dictionary = gateway.MoveUnits(nodes, destination, player)
	notify_player_override(str(player.name), nodes.map(func(n): return str(n.name)))
	_visualize_command(match_node, "move", nodes, destination)
	return JSON.stringify(_unified_receipt(result, {
		"moved": nodes.map(func(n): return n.name),
	}))


func _op_gather(match_node, parsed) -> String:
	var player = _resolve_player(match_node, parsed)
	var gateway = NetSession.command_gateway_for(player)
	if gateway == null:
		return JSON.stringify({
			"ok": false,
			"accepted": false,
			"status": "NoGateway",
			"reason": "该玩家没有可用的命令网关（对局未就绪或角色不支持手动命令）。",
			"error": "no gateway",
		})
	var nodes := _resolve_own_units(player, parsed.get("units", []))
	if nodes.is_empty():
		return JSON.stringify({
			"ok": false,
			"accepted": false,
			"status": "UnitsNotFound",
			"reason": "找不到属于该玩家的采集单位，请先从 status 的 units 里选择我方工人。",
			"error": "no units",
		})
	var kind := str(parsed.get("kind", "a"))
	var origin: Vector3 = nodes[0].global_position
	var target = null
	var best_distance := 1e12
	for resource in get_tree().get_nodes_in_group("resource_units"):
		if resource == null or not is_instance_valid(resource):
			continue
		var matches_kind := (kind == "a" and "resource_a" in resource) or (
			kind == "b" and "resource_b" in resource
		)
		if not matches_kind:
			continue
		var distance: float = resource.global_position.distance_to(origin)
		if distance < best_distance:
			best_distance = distance
			target = resource
	if target == null:
		return JSON.stringify({
			"ok": false,
			"status": "ResourceNotFound",
			"reason": "找不到该类型资源点，请换个采集类型或先侦察。",
			"kind": kind,
			"error": "no resource of kind " + kind,
		})
	var result: Dictionary = gateway.GatherResources(nodes, target, player)
	notify_player_override(str(player.name), nodes.map(func(n): return str(n.name)))
	_visualize_command(match_node, "gather", nodes, target.global_position)
	return JSON.stringify(_unified_receipt(result, {
		"resource": target.name,
	}))


func _op_build(match_node, parsed) -> String:
	var player = _resolve_player(match_node, parsed)
	var builders := _resolve_own_units(player, parsed.get("units", []))
	if builders.is_empty():
		return JSON.stringify({
			"ok": false,
			"status": "UnitsNotFound",
			"reason": "找不到属于该玩家的建造单位，请先从 status 的 units 里选择我方工人。",
			"error": "no builders",
		})
	var pos_raw: Array = parsed.get("pos", [0.0, 0.0])
	if pos_raw.is_empty():
		pos_raw = [0.0, 0.0]
	var position := Vector3(float(pos_raw[0]), 0.0, float(pos_raw[1]))
	var scene_path := str(parsed.get("scene", "res://source/match/units/VehicleFactory.tscn"))
	# ---------- 续建路由（2026-09-12 已授权，见 docs/程序文档/AI副官_当前执行入口.md Q6） ----------
	# 背景（实测）：`build` 走 `StructurePlacementRuntime.Place()` = **新建一座**；
	# 目标是"已放置但未完工"的建筑时，同位置再 Place 必然被判 `Occupied`
	# （实测同一意图被连续 `Rejected/Occupied ×32`，工地永远建不完）。
	# 游戏本身已有正确通道：`Constructing.is_applicable`（工人 + 己方未完工建筑）
	# → `gateway.ConstructUnits(units, target, issuer)`（人类 UI 走的就是它）。
	# 这里只做**路由**：仅当目标类型的**己方未完工建筑确实存在**时才改走续建，
	# 其它情况原样走新建路径（默认行为不变）。
	var existing_site = _find_own_unfinished_structure(player, scene_path, position)
	if existing_site != null:
		return _construct_on_existing_site(player, builders, existing_site, scene_path)
	# The debug endpoint runs inside the authority process for local listen-server
	# tests. Calling forward_command there sends an RPC to peer 1 but does not
	# reliably execute the command locally, so apply placement directly on server.
	# 单机（未联网）对局同样没有转发目标，也直接权威执行（副官单机冒烟依赖此路径）。
	if NetSession.is_server() or not NetSession.is_networked():
		var placement_runtime = match_node.get_node_or_null("StructurePlacementRuntime")
		if placement_runtime == null:
			return JSON.stringify({
				"ok": false,
				"status": "NoPlacementRuntime",
				"reason": "权威端缺少建筑放置服务，无法执行建造。",
				"error": "no placement runtime",
			})
		var structure_transform := Transform3D(Basis.IDENTITY, position)
		var place_result: Dictionary = placement_runtime.Place(
			player, load(scene_path), structure_transform, {}
		)
		if bool(place_result.get("accepted", false)):
			placement_runtime.AssignBuilders(
				builders,
				place_result["structure"],
				player,
				place_result.get("displaced_unit_ids", [])
			)
		var place_ok := bool(place_result.get("accepted", false))
		var place_status := "Accepted" if place_ok else "Rejected"
		var place_issue := str(place_result.get("primary_issue", ""))
		if place_ok:
			notify_player_override(str(player.name), builders.map(func(n): return str(n.name)))
			_visualize_command(match_node, "build", builders, position)
		# 直执行没有客户端上送的 command_id，服务器补发一个便于副官复核。
		var server_command_id := _new_command_id()
		var structure_node = place_result.get("structure")
		record_command(server_command_id, "build", str(player.name),
			"|".join(builders.map(func(n): return str(n.name))), scene_path,
			place_status, place_issue,
			str(structure_node.name) if structure_node != null and is_instance_valid(structure_node) else "")
		return JSON.stringify({
			"ok": place_ok,
			"accepted": place_ok,
			"status": place_status,
			"reason": place_issue,
			"command_id": server_command_id,
			"issue": place_issue,
			"builders": builders.map(func(n): return n.name),
			"result": place_result,
		})
	# 客户端转发：生成稳定 command_id 随命令上送，服务器保留同一 ID 落账，
	# 副官下一轮可用 op=commands 复核最终 Accepted/Rejected。
	var sync = match_node.get_node_or_null("NetSync")
	if sync == null:
		return JSON.stringify({
			"ok": false,
			"status": "NoNetSync",
			"reason": "对局网络层未初始化，无法提交建造。",
			"error": "no netsync",
		})
	var command_id := _new_command_id()
	sync.forward_command(
		"place_structure", builders, position, null, player,
		scene_path + "|0|" + command_id
	)
	record_command(command_id, "build", str(player.name),
		"|".join(builders.map(func(n): return str(n.name))), scene_path,
		"PendingAuthority", "命令已发送，等待服务器确认建造位置和资源。")
	return JSON.stringify({
		"ok": false,
		"accepted": false,
		"status": "PendingAuthority",
		"reason": "命令已发送，等待服务器确认建造位置和资源。",
		"command_id": command_id,
		"builders": builders.map(func(n): return n.name),
	})


## 找出"己方 + 类型匹配 + 未完工"的建筑实体（续建目标）。
##
## 只认：属于该玩家 + 有 `is_constructed()` 且为 false + 类型与请求的 scene 匹配。
## 找不到就返回 null —— 调用方必须保持原有"新建"路径（默认行为不变）。
func _find_own_unfinished_structure(player, scene_path: String, near_position: Vector3):
	var wanted := scene_path.get_file().get_basename().to_lower()
	if wanted.is_empty():
		return null
	var best = null
	var best_distance := INF
	for unit in get_tree().get_nodes_in_group("units"):
		if unit == null or not is_instance_valid(unit):
			continue
		if unit.get_parent() != player:
			continue
		if not unit.has_method("is_constructed") or unit.is_constructed():
			continue
		var type_id := str(unit.get("unit_type_id")) if "unit_type_id" in unit else ""
		var script_name := ""
		if unit.get_script() != null:
			script_name = str(unit.get_script().resource_path).get_file().get_basename().to_lower()
		if type_id.to_lower() != wanted and script_name != wanted:
			continue
		var distance: float = unit.global_position.distance_to(near_position)
		if distance < best_distance:
			best_distance = distance
			best = unit
	return best


## 对"已存在但未完工"的建筑下达续建（权威入口 = `ConstructUnits`）。
## 不做无限重试：被拒就如实返回拒绝原因，由协调器决定是否换人/等待。
func _construct_on_existing_site(player, builders: Array, site, scene_path: String) -> String:
	var gateway = player.find_child("UnitCommandGateway")
	if gateway == null:
		return JSON.stringify({
			"ok": false, "accepted": false, "status": "NoGateway",
			"reason": "权威端缺少命令网关，无法下达续建。", "error": "no gateway",
		})
	var result: Dictionary = gateway.ConstructUnits(builders, site, player)
	var accepted := bool(result.get("accepted", false))
	var reason := ""
	if not accepted:
		# GDScript 不能用 `a or b` 做字符串回退（`or` 是布尔运算符）——
		# 写成那样会编译失败，导致整个 DebugControlServer 加载不了、对局起不来（2026-09-12 踩过）。
		reason = str(result.get("error_code", ""))
		if reason.is_empty():
			reason = str(result.get("reason", ""))
	var command_id := _new_command_id()
	record_command(command_id, "construct", str(player.name),
		"|".join(builders.map(func(n): return str(n.name))), scene_path,
		"Accepted" if accepted else "Rejected", reason, str(site.name))
	return JSON.stringify({
		"ok": accepted, "accepted": accepted,
		"status": "Accepted" if accepted else "Rejected",
		"reason": reason,
		"command_id": command_id,
		"site": str(site.name),
		"result": result,
	})


func _op_produce(match_node, parsed) -> String:
	var player = _resolve_player(match_node, parsed)
	var producer_name := str(parsed.get("unit", parsed.get("producer", "")))
	var nodes := _resolve_own_units(player, [producer_name])
	if nodes.is_empty():
		return JSON.stringify({
			"ok": false,
			"accepted": false,
			"status": "ProducerNotFound",
			"reason": "找不到属于该玩家的生产建筑，请使用 status 中带 queue=true 的建筑名称。",
			"producer": producer_name,
		})
	var queue = nodes[0].find_child("ProductionQueue", false, false)
	if queue == null:
		return JSON.stringify({
			"ok": false,
			"accepted": false,
			"status": "NoProductionQueue",
			"reason": "这个单位不是可生产单位的建筑。",
			"producer": producer_name,
		})
	var scene_path := str(parsed.get("scene", ""))
	var product = load(scene_path)
	if product == null:
		return JSON.stringify({
			"ok": false,
			"accepted": false,
			"status": "DefinitionNotFound",
			"reason": "找不到要生产的单位定义。",
			"producer": producer_name,
			"scene": scene_path,
		})
	var submitted = queue.produce(product)
	var receipt: Dictionary = queue.get_last_result() if queue.has_method("get_last_result") else {}
	if receipt.is_empty():
		receipt = {
			"accepted": submitted != null,
			"status": "Accepted" if submitted != null else "Rejected",
		}
	var produce_status := str(receipt.get("status", ""))
	var produce_ok := produce_status == "Accepted"
	var item_id := ""
	if receipt.get("item") is Dictionary:
		item_id = str(receipt["item"].get("item_id", ""))
	record_command(str(receipt.get("command_id", "")), "produce", str(player.name),
		producer_name, scene_path, produce_status, "" if produce_ok else _production_reason(produce_status),
		item_id)
	if produce_ok:
		notify_player_override(str(player.name), [producer_name])
		if not nodes.is_empty():
			_visualize_command(match_node, "produce", nodes, nodes[0].global_position)
	receipt["producer"] = producer_name
	receipt["scene"] = scene_path
	receipt["queue_size"] = queue.size() if queue.has_method("size") else -1
	if not item_id.is_empty():
		receipt["item_id"] = item_id
	receipt["ok"] = produce_ok
	receipt["accepted"] = produce_ok
	receipt["reason"] = "" if produce_ok else _production_reason(produce_status)
	return JSON.stringify(receipt)


func _production_reason(status: String) -> String:
	match status:
		"ProductNotAllowed":
			return "这个生产建筑不能制造该单位；请把坦克订单发给车辆工厂，把工人订单发给指挥中心。"
		"InsufficientResources":
			return "资源不足，暂不下单。"
		"QueueFull":
			return "生产队列已满，等待当前项目完成。"
		"PendingAuthority":
			return "命令已送达服务器，等待权威服确认。"
		"ProducerNotFound":
			return "找不到指定生产建筑。"
		_:
			return "生产命令未被接受，请根据 status 重试或更换生产建筑。"


func _op_attack(match_node, parsed) -> String:
	var player = _resolve_player(match_node, parsed)
	var gateway = NetSession.command_gateway_for(player)
	if gateway == null:
		return JSON.stringify({
			"ok": false,
			"accepted": false,
			"status": "NoGateway",
			"reason": "该玩家没有可用的命令网关（对局未就绪或角色不支持手动命令）。",
			"error": "no gateway",
		})
	var target_name := str(parsed.get("target", ""))
	var attackers := _resolve_own_units(player, parsed.get("units", []))
	if attackers.is_empty():
		return JSON.stringify({
			"ok": false,
			"accepted": false,
			"status": "UnitsNotFound",
			"reason": "找不到属于该玩家的攻击单位，请先从 status 的 units 里选择我方单位。",
			"target": target_name,
			"error": "no units",
		})
	var target = null
	for unit in get_tree().get_nodes_in_group("units"):
		if unit == null or not is_instance_valid(unit):
			continue
		if unit.name == target_name and unit.get_parent() != player:
			target = unit
			break
	if target == null:
		return JSON.stringify({
			"ok": false,
			"accepted": false,
			"status": "TargetNotFound",
			"reason": "找不到目标单位；战争迷雾下未侦察的敌人不可见，请先侦察确认目标再攻击。",
			"target": target_name,
			"error": "target not found",
		})
	var result: Dictionary = gateway.AttackUnits(attackers, target, player)
	notify_player_override(str(player.name), attackers.map(func(n): return str(n.name)))
	_visualize_command(match_node, "attack", attackers, target.global_position)
	return JSON.stringify(_unified_receipt(result, {
		"target": target_name,
	}))


## RA3 侧栏 UI 元素实时坐标（供外部驱动自适应窗口尺寸点击）。
func _collect_sidebar_ui() -> Dictionary:
	var result := {"tabs": [], "cells": []}
	var sidebars := get_tree().get_nodes_in_group("ra3_sidebar")
	if sidebars.is_empty():
		return result
	var sidebar: Control = sidebars[0]
	if not is_instance_valid(sidebar) or not sidebar.is_visible_in_tree():
		result["visible"] = false
		return result
	for tab_button in sidebar.find_children("*", "Button", true, false):
		if not is_instance_valid(tab_button):
			continue
		if tab_button.has_meta("tab_id"):
			result["tabs"].append({
				"id": str(tab_button.get_meta("tab_id")),
				"text": str(tab_button.text),
				"center": _control_center(tab_button),
				"disabled": tab_button.disabled,
			})
		elif tab_button.has_meta("cell_caption"):
			result["cells"].append({
				"caption": str(tab_button.get_meta("cell_caption")),
				"center": _control_center(tab_button),
				"disabled": tab_button.disabled,
			})
	return result


func _control_center(control: Control) -> Array:
	var center := control.get_global_rect().get_center()
	return [center.x, center.y]


## 轻量战况快照：只回统计数字（无逐单位明细），供高频采样器秒级轮询。
func _collect_status_lite(match_node, player, out: Dictionary, full_vision: bool) -> Dictionary:
	out["lite"] = true
	out.erase("units")
	out.erase("resources")
	out.erase("viewport_size")
	out.erase("window_size")
	out["players"] = get_tree().get_nodes_in_group("players").map(
		func(p): return {
			"name": str(p.name),
			"human": _is_human_player(p),
			"a": int(p.resource_a) if (p == player or full_vision) else -1,
			"b": int(p.resource_b) if (p == player or full_vision) else -1,
		})
	if player != null:
		out["local_player_name"] = str(player.name)
		out["balance"] = {"a": int(player.resource_a), "b": int(player.resource_b)}
	var counts := {"total": 0, "mine": 0, "scouted_enemy": 0, "mine_by_type": {}}
	var production: Array = []
	for unit in get_tree().get_nodes_in_group("units"):
		if not _is_real_unit(unit):
			continue
		var mine: bool = unit.get_parent() == player
		if not mine and not full_vision and not _unit_scouted(unit, player):
			continue
		counts["total"] += 1
		if mine:
			counts["mine"] += 1
			var key := str(unit.get("unit_type_id")) if "unit_type_id" in unit else "unknown"
			counts["mine_by_type"][key] = int(counts["mine_by_type"].get(key, 0)) + 1
			var producer_view = _production_snapshot(match_node, unit)
			if producer_view != null:
				production.append(producer_view)
		elif not full_vision:
			counts["scouted_enemy"] += 1
	out["counts"] = counts
	out["production"] = production
	var outcome_runtime = match_node.get_node_or_null("MatchOutcomeRuntime")
	if outcome_runtime != null and outcome_runtime.has_method("InspectOutcome"):
		out["outcome"] = outcome_runtime.InspectOutcome()
	return out


func _collect_status(match_node, parsed = null) -> Dictionary:
	var tree := get_tree()
	var viewport := get_viewport()
	var window := get_window()
	var out := {
		"match": false,
		"local_slot": NetSession.local_slot,
		# 联网/权威状态：外部测试在发 op=start 前必须确认 networked=true，
		# 否则 start_solo 会走 join(默认云端地址) 分支误连玩家局服。
		"networked": NetSession.is_networked(),
		"is_server": NetSession.is_server(),
		"units": [],
		"resources": [],
		"balance": null,
		"passive_ai_test": NetSession.passive_ai_test,
		"passive_ai_test_server": NetSession.passive_ai_test_server,
		"viewport_size": [viewport.size.x, viewport.size.y],
		"window_size": [window.size.x, window.size.y],
	}
	if match_node == null or not match_node.has_method("get_local_player"):
		return out
	var player = _resolve_player(match_node, parsed if parsed != null else {})
	out["match"] = true
	var settings_node = match_node.get_node_or_null("FogOfWar")
	var fog_active: bool = settings_node != null and bool(settings_node.visible)
	var full_vision: bool = bool((parsed if parsed != null else {}).get("full_vision", false)) \
		or not fog_active
	out["full_vision"] = full_vision
	# 轻量模式：只回统计（几百字节），供 5 秒级高频采样器使用。
	# 全量 status 在单位较多时可达 24KB+，受 Godot TCP 逐帧写出限制需 20~60s 才传完，
	# 无法支撑高频采样；lite 只回计数与战况版本，秒级返回。
	if bool((parsed if parsed != null else {}).get("lite", false)):
		return _collect_status_lite(match_node, player, out, full_vision)
	# 玩家明细：副官（外部 AI）靠它选定 as_player 指挥对象（human 标记真人）。
	# 战争迷雾公平性：敌方经济余额对迷雾内的对手不可见，统一脱敏为 -1。
	out["players"] = get_tree().get_nodes_in_group("players").map(
		func(p): return {
			"name": str(p.name),
			"human": _is_human_player(p),
			"a": int(p.resource_a) if (p == player or full_vision) else -1,
			"b": int(p.resource_b) if (p == player or full_vision) else -1,
		})
	if player == null:
		_append_unit_entries(out, match_node, null)
		return out
	out["local_player_name"] = str(player.name)
	out["player_nodes"] = get_tree().get_nodes_in_group("players").map(func(p): return str(p.name))
	out["balance"] = {"a": int(player.resource_a), "b": int(player.resource_b)}
	out["ra3_sidebar_ui"] = _collect_sidebar_ui()
	out["all_balances"] = get_tree().get_nodes_in_group("players").map(
		func(p): return {
			"player": str(p.name),
			"a": int(p.resource_a) if (p == player or full_vision) else -1,
			"b": int(p.resource_b) if (p == player or full_vision) else -1,
		}
	)
	var outcome_runtime = match_node.get_node_or_null("MatchOutcomeRuntime")
	if outcome_runtime != null and outcome_runtime.has_method("InspectOutcome"):
		out["outcome"] = outcome_runtime.InspectOutcome()
	var camera := tree.current_scene.get_viewport().get_camera_3d()
	if camera != null:
		out["camera"] = {
			"pos": [camera.global_position.x, camera.global_position.y, camera.global_position.z],
			"rotation": [camera.rotation.x, camera.rotation.y, camera.rotation.z],
			"projection": camera.projection,
			"size": camera.size,
			"near": camera.near,
			"far": camera.far,
			"frustum_visible": camera.is_position_in_frustum(player.global_position),
		}
	var fog = match_node.get_node_or_null("FogOfWar")
	if fog != null:
		out["fog_visible"] = fog.visible
		var fog_viewport = fog.get_node_or_null("CombinedViewport/FogViewportContainer/FogViewport")
		out["fog_debug"] = {
			"viewport_size": [fog_viewport.size.x, fog_viewport.size.y] if fog_viewport != null else null,
			"fog_circle_count": fog_viewport.get_child_count() if fog_viewport != null else -1,
			"combined_child_count": fog.get_node("CombinedViewport").get_child_count(),
		}
	_append_unit_entries(out, match_node, player, full_vision)
	return out


func _append_unit_entries(out: Dictionary, _match_node, player, full_vision := false) -> void:
	var tree := get_tree()
	var camera := tree.current_scene.get_viewport().get_camera_3d() if tree.current_scene != null else null
	for unit in tree.get_nodes_in_group("units"):
		if not _is_real_unit(unit):
			continue
		var mine: bool = unit.get_parent() == player
		# 迷雾公平性：非本方且未被侦察的单位不进入 status 输出。
		var scouted := mine or full_vision or _unit_scouted(unit, player)
		if not mine and not scouted:
			continue
		var carried := [0, 0]
		if "resource_a" in unit and "resource_b" in unit:
			carried = [int(unit.resource_a), int(unit.resource_b)]
		var entry := {
			"name": unit.name,
			"owner": unit.get_parent().name if unit.get_parent() != null else "",
			"unit_type": str(unit.get("unit_type_id")) if "unit_type_id" in unit else "",
			"hp": float(unit.hp) if "hp" in unit and unit.hp != null else null,
			"hp_max": float(unit.hp_max) if "hp_max" in unit and unit.hp_max != null else null,
			"pos": [
				unit.global_position.x, unit.global_position.y, unit.global_position.z
			],
			# 平面朝向角（弧度，绕 Y）；供移动监控脚本计算角速度、判定瞬转残留。
			"yaw": unit.global_transform.basis.get_euler().y,
			"mine": unit.get_parent() == player,
			"selected": unit.is_in_group("selected_units"),
			"visible": unit.visible,
			"revealed": scouted,
			"movement": unit.find_child("Movement", false, false) != null,
			"queue": unit.find_child("ProductionQueue", false, false) != null,
			"attack": "attack_range" in unit,
			"carried": carried,
		}
		if mine:
			var producer_view = _production_snapshot(_match_node, unit)
			if producer_view != null:
				entry["production"] = producer_view
		if "action" in unit and unit.action != null and is_instance_valid(unit.action):
			entry["action"] = str(unit.action.get_script().resource_path) if unit.action.get_script() != null else str(unit.action)
		if "is_constructed" in unit:
			entry["constructed"] = bool(unit.is_constructed())
		if camera != null:
			var screen: Vector2 = camera.unproject_position(unit.global_position)
			entry["screen"] = [screen.x, screen.y]
		out["units"].append(entry)
	for resource in tree.get_nodes_in_group("resource_units"):
		if resource == null or not is_instance_valid(resource):
			continue
		var resource_entry := {"name": resource.name}
		if "resource_a" in resource:
			resource_entry["kind"] = "a"
		elif "resource_b" in resource:
			resource_entry["kind"] = "b"
		if camera != null:
			var resource_screen: Vector2 = camera.unproject_position(
				resource.global_position
			)
			resource_entry["screen"] = [resource_screen.x, resource_screen.y]
		out["resources"].append(resource_entry)


## 战争迷雾下按玩家隔离的只读侦察判定（2026-09-06 公平性复核）：
## - 只统计 as_player 自己拥有的存活单位的视野；其他玩家侦察过不等于本玩家看到，
##   因此不使用全局 revealed_units 组（那是观战/跨玩家可见性，可能泄露敌情）。
## - sight_range 必须是有限且 >0 的数值；为空、非法或 <=0 的单位不计入侦察，
##   不使用默认值（避免无侦察能力的建筑泄露敌情）。
## - 跳过无效节点、死亡单位（hp<=0）与未建成建筑。
## - 只读计算，不修改任何全局迷雾组或渲染状态。
func _unit_scouted(unit, player) -> bool:
	if player == null:
		return false
	var target_pos: Vector3 = unit.global_position
	for mine_unit in get_tree().get_nodes_in_group("units"):
		if not _is_real_unit(mine_unit):
			continue
		if mine_unit.get_parent() != player:
			continue
		# 死亡与未建成单位不具备侦察视野。
		if "hp" in mine_unit and mine_unit.hp != null and float(mine_unit.hp) <= 0.0:
			continue
		if mine_unit.has_method("is_constructed") and not mine_unit.is_constructed():
			continue
		var sight_value = mine_unit.get("sight_range")
		if sight_value == null:
			continue
		var sight := float(sight_value)
		if not is_finite(sight) or sight <= 0.0:
			continue
		var delta: Vector3 = mine_unit.global_position - target_pos
		delta.y = 0.0
		if delta.length() <= sight:
			return true
	return false


## units 组的防御性过滤：历史上出现过 @Area3D@NNN 等编辑器遗留节点混入的记录。
## 注意：本项目单位本体派生自 Area3D（Unit.gd extends Area3D，用 Area3D 做
## 单位碰撞是既有设计），因此不能用"是否 Area3D"排除伪单位；改用三重特征：
## 1) 挂着 source/match/units/ 下的单位脚本（投射物等子目录脚本被父节点检查排除）；
## 2) 父节点在 players 组（真单位都由 _setup_and_spawn_unit 挂到玩家下）；
## 3) 带 hp 属性（Area3D 触发器/辅助节点没有）。
## counts.total/counts.mine 与全量 units 必须共用本判定，避免口径分裂。
func _is_real_unit(unit) -> bool:
	if unit == null or not is_instance_valid(unit):
		return false
	if not (unit is Node3D):
		return false
	var script = unit.get_script()
	if script == null or not str(script.resource_path).contains("/units/"):
		return false
	var parent = unit.get_parent()
	if parent == null or not parent.is_in_group("players"):
		return false
	if not ("hp" in unit):
		return false
	return true


## 把底层命令结果规范化为统一顶层回执。
## - accepted 只在真实 status 为 Accepted/PartiallyAccepted 时为 true；
##   单位级命令还要求至少一个 unit_result.accepted=true；
## - 真实状态提升到顶层，不再只存在于嵌套 result；
## - 旧字段经 legacy 参数原样保留（moved/resource/target/builders 等）。
func _unified_receipt(result: Dictionary, legacy: Dictionary = {}) -> Dictionary:
	var status := str(result.get("status", ""))
	if status.is_empty():
		status = "Rejected"
	var unit_results: Array = result.get("unit_results", []) if result.get("unit_results") is Array else []
	var any_unit_accepted := true
	if not unit_results.is_empty():
		any_unit_accepted = false
		for unit_result in unit_results:
			if unit_result is Dictionary and bool(unit_result.get("accepted", false)):
				any_unit_accepted = true
				break
	var accepted := (status == "Accepted" or status == "PartiallyAccepted") and any_unit_accepted
	var reason := ""
	if not accepted:
		reason = _unit_error_reason(unit_results)
		if reason.is_empty():
			reason = _status_reason(status, str(result.get("reason", "")))
	var receipt := {
		"ok": accepted,
		"accepted": accepted,
		"status": status,
		"reason": reason,
		"command_id": str(result.get("command_id", "")),
		"result": result,
	}
	receipt.merge(legacy, true)
	return receipt


## 面向 Hermes 的失败原因文案（统一回执用；生产类原因见 _production_reason）。
## 底层 unit_result 带 error_code 时优先用它生成更精确的原因（见 _unified_receipt）。
func _status_reason(status: String, from_source := "") -> String:
	if not from_source.is_empty():
		return from_source
	match status:
		"Rejected":
			return "命令被服务器拒绝，请检查目标与位置后调整策略。"
		"TargetNotFound":
			return "找不到目标单位；战争迷雾下未侦察的敌人不可见，请先侦察确认目标再攻击。"
		"Unreachable":
			return "目的地不可达，请换一个更近或更平坦的目标点。"
		_:
			return "命令未被接受（%s），请根据 status 复核后调整策略。" % status


## 把单位级 error_code 翻译成面向 Hermes 的明确原因（如对空/对地不匹配）。
func _unit_error_reason(unit_results: Array) -> String:
	for unit_result in unit_results:
		if not (unit_result is Dictionary) or bool(unit_result.get("accepted", false)):
			continue
		match str(unit_result.get("error_code", "")):
			"WeaponCannotTargetDomain":
				return "当前武器无法攻击该目标所处的域（地面/空中不匹配），请改打地面目标或用对空单位。"
			"TargetNotVisible":
				return "目标已脱离视野，请先重新侦察确认位置。"
			"OutOfRange":
				return "目标在武器射程之外，请先接近目标。"
			"UnitCannotMove":
				return "该单位不具备移动能力，请换可移动单位。"
	return ""


## 生成转发命令的稳定关联 ID：客户端生成、随命令上送、服务器保留同一 ID 落账。
func _new_command_id() -> String:
	return "%08x-%04x-4%03x-%04x-%012x" % [
		randi(), randi() & 0xFFFF, randi() & 0xFFF,
		randi() & 0xFFFF, Time.get_ticks_msec() * 4096 + (randi() & 0xFFF),
	]


## 登记命令终态（转发路径由 NetSync 调用，直执行路径在本文件内调用）。
## PendingAuthority 阶段先落 PendingAuthority，服务器终态到达后覆盖同名记录。
func record_command(command_id: String, op: String, player_name: String,
		subject: String, scene: String, status: String, reason: String,
		artifact_id := "") -> void:
	if command_id.is_empty():
		return
	for entry in _command_log:
		if entry.get("command_id", "") == command_id:
			entry["status"] = status
			entry["reason"] = reason
			if not artifact_id.is_empty():
				entry["artifact_id"] = artifact_id
			return
	_command_log.append({
		"command_id": command_id,
		"op": op,
		"player": player_name,
		"subject": subject,
		"scene": scene,
		"status": status,
		"reason": reason,
		"artifact_id": artifact_id,
	})
	if _command_log.size() > COMMAND_LOG_LIMIT:
		_command_log = _command_log.slice(_command_log.size() - COMMAND_LOG_LIMIT)


## op=combat：**只读**交火遥测（开火总数 + 最近开火事件）。
##
## 为什么需要它（2026-09-11 用户指出）：单位会**自动攻击**靠近的敌人，因此
## "敌我血量变化"既不能证明"副官在指挥交火"，也不能证明"真的开了火"；
## 交火同时也没有特效/音效可供肉眼确认 → 验收缺一条可判定信号。
## 这里只读 `CombatSfx` 的表现层日志（谁、在哪、何时开火），
## **不读取也不改变任何权威状态**，纯粹给验收/自动化一个证据通道。
func _combat_snapshot(match_node, parsed) -> Dictionary:
	var limit := int(parsed.get("limit", 20))
	if limit <= 0:
		limit = 20
	var log: Array = CombatSfx.shot_log
	var recent: Array = []
	var start := maxi(0, log.size() - limit)
	for index in range(start, log.size()):
		recent.append(log[index])
	# 弹道/投射物**视觉节点**当前数量：这是"攻击特效到底有没有被创建"的直接读数，
	# 而且能区分**哪个进程**创建的（权威端创建 ≠ 客户端能看到）。
	var container = match_node.get_node_or_null("Projectiles") if match_node != null else null
	return {
		"fire_total": int(CombatSfx.fire_total),
		"log_size": log.size(),
		"projectile_nodes": container.get_child_count() if container != null else -1,
		"recent": recent,
	}


## op=force_attack：**强制攻击**（与玩家侧栏「强制攻击 [X]」走同一条
## `gateway.ForceAttackUnits` 权威链，允许显式己方/友军目标）。
##
## 为什么需要这个调试入口：不开电脑 AI 时局内没有敌人，无法用普通 attack 触发开火，
## 而"看不到攻击特效"必须能**可控地开一枪**才能查（弹道节点、开火事件、命中结算）。
## 它不新增任何玩法：目标合法性、伤害结算、友伤规则全部由既有权威链裁决。
func _op_force_attack(match_node, parsed) -> String:
	var player = _resolve_player(match_node, parsed)
	var gateway = NetSession.command_gateway_for(player)
	if gateway == null:
		return JSON.stringify({"ok": false, "accepted": false, "status": "NoGateway",
			"reason": "该玩家没有可用的命令网关（对局未就绪或角色不支持手动命令）。"})
	var target_name := str(parsed.get("target", ""))
	var attackers := _resolve_own_units(player, parsed.get("units", []))
	if attackers.is_empty():
		return JSON.stringify({"ok": false, "accepted": false, "status": "UnitsNotFound",
			"reason": "找不到属于该玩家的攻击单位。", "target": target_name})
	var target = null
	for unit in get_tree().get_nodes_in_group("units"):
		if unit == null or not is_instance_valid(unit):
			continue
		if str(unit.name) == target_name:
			target = unit
			break
	if target == null:
		return JSON.stringify({"ok": false, "accepted": false, "status": "TargetNotFound",
			"reason": "找不到目标单位（强制攻击允许己方目标）。", "target": target_name})
	var result: Dictionary = gateway.ForceAttackUnits(attackers, target, player)
	notify_player_override(str(player.name), attackers.map(func(n): return str(n.name)))
	_visualize_command(match_node, "attack", attackers, target.global_position)
	return JSON.stringify(_unified_receipt(result, {"target": target_name}))


## op=commands 查询：带 command_id 精确复核单条，否则返回全部历史（新→旧）。
## 副官统一入口的命令优先查幂等账本（adjutant_command 的权威回执即终态）；
## 旧 op 直执行/转发路径仍查 _command_log 展示历史。
func _query_commands(parsed) -> Array:
	var wanted := str(parsed.get("command_id", ""))
	if wanted.is_empty():
		return _command_log.duplicate(true)
	for view_key in _adjutant_ledger.keys():
		var ledger: Dictionary = _adjutant_ledger[view_key]
		if ledger.has(wanted):
			var receipt: Dictionary = (ledger[wanted]["receipt"] as Dictionary).duplicate(true)
			receipt["source"] = "adjutant_ledger"
			return [receipt]
	for entry in _command_log:
		if entry.get("command_id", "") == wanted:
			return [entry.duplicate(true)]
	return []


## 返回副官作决策所需的生产事实，避免只暴露 queue=true 造成盲下单。
func _production_snapshot(match_node, unit):
	var queue = unit.find_child("ProductionQueue", false, false)
	if queue == null:
		return null
	var items: Array = []
	var runtime = match_node.get_node_or_null("ProductionRuntime")
	if runtime != null and runtime.has_method("GetQueue"):
		for item in runtime.GetQueue(unit):
			items.append({
				"item_id": str(item.get("item_id", "")),
				"producer_id": str(item.get("producer_id", "")),
				"definition_id": str(item.get("definition_id", "")),
				"state": str(item.get("state", "")),
				"completed_work": int(item.get("completed_work", 0)),
				"required_work": int(item.get("required_work", 0)),
				"version": int(item.get("version", 0)),
			})
	else:
		for element in queue.get_elements() if queue.has_method("get_elements") else []:
			items.append({
				"item_id": str(element.item_id),
				"state": str(element.state),
				"completed_work": int(element.completed_work),
				"required_work": int(element.required_work),
			})
	var result := {
		"producer": str(unit.name),
		"producer_type": str(unit.get("unit_type_id")) if "unit_type_id" in unit else "",
		"queue_size": items.size(),
		"items": items,
	}
	if queue.has_method("get_last_result"):
		result["last_command"] = queue.get_last_result()
	# Legacy 只读镜像单独暴露：客户端 HUD 的排队/进度动画就靠它，
	# 而客户端的 `ProductionRuntime.GetQueue` 存在但**恒空**（C# 生产服务客户端不跑），
	# 只看 `items` 会掩盖"镜像到底有没有同步过来"（2026-09-11 表现层核对）。
	if queue.has_method("get_elements"):
		var mirror: Array = []
		for element in queue.get_elements():
			mirror.append({
				"item_id": str(element.item_id),
				"state": str(element.state),
				"completed_work": int(element.completed_work),
				"required_work": int(element.required_work),
			})
		result["legacy_mirror"] = mirror
		result["legacy_mirror_size"] = mirror.size()
	return result


# =====================================================================
# 副官双层改造第一阶段：动态规则导出 / 战术观测 / 统一命令协议
# ---------------------------------------------------------------------
# 设计要点（与 docs/ai-adjutant-dual-layer/architecture.md 对应）：
# - 规则视图来自当前 Match 实际加载的 Catalog（对局内不可变），不读磁盘最新配置。
# - 战术快照带公共包头，敌方数据遵守 as_player 自己的视野；历史情报带
#   last_seen_tick，失去视野冻结不更新，确认死亡是独立事件。
# - 命令协议带对局/玩家身份与版本，幂等作用域 (match_id, player_id, command_id)，
#   过期命令显式拒绝，玩家手动命令立即取消副官租约（PlayerOverride）。
# - 幂等账本与 _command_log 展示历史分离，容量满显式背压。
# =====================================================================

## 挂载状态检查：C# 观测运行时缺失时统一拒绝（不伪造身份）。
func _adjutant_require_observation() -> Dictionary:
	if _adjutant_observation == null or not is_instance_valid(_adjutant_observation):
		return {"error": "no observation runtime"}
	return {}


## 当前权威 match_id；对局未就绪或配置降级时为空，调用方必须拒绝命令。
func _adjutant_match_id(match_node) -> String:
	if _adjutant_require_observation().has("error"):
		return ""
	return str(_adjutant_observation.ResolveMatchId(match_node))


## 当前对局规则版本键（Catalog content hash）。
func _adjutant_rules_version(match_node) -> String:
	if _adjutant_require_observation().has("error"):
		return ""
	return str(_adjutant_observation.ResolveRulesVersion(match_node))


## 副官视角玩家节点：按 player_id 精确匹配 players 组，不回退本地玩家。
## 服务器权威进程没有本地玩家，外接副官全靠显式 player_id 指挥。
func _adjutant_resolve_player(wanted: String):
	if wanted.is_empty():
		return null
	for p in get_tree().get_nodes_in_group("players"):
		if str(p.name) == wanted:
			return p
	return null


## 单机自定义对局下的唯一玩家（仅当 players 组里**恰好一个**时才返回，否则 null）。
## 用途：本机 HUD 调整自己的预留时不必自报身份；有歧义（联机多玩家）时坚决不猜。
func _adjutant_lone_player():
	var players := get_tree().get_nodes_in_group("players")
	if players.size() != 1:
		return null
	return players[0]


## op=rules：从当前对局 Catalog 导出规则视图（对局内缓存，Catalog 不可变）。
func _op_rules(match_node) -> Dictionary:
	var guard := _adjutant_require_observation()
	if not guard.is_empty():
		return guard
	var match_id := _adjutant_match_id(match_node)
	if match_id.is_empty():
		return {"error": "match unavailable", "reason": "当前对局没有稳定 match_id（对局未就绪或配置降级）。"}
	if _adjutant_rules_cache.has(match_id):
		return _adjutant_rules_cache[match_id]
	var rules: Dictionary = _adjutant_observation.ExportRules(match_node)
	if rules.has("error"):
		return rules
	rules["match_id"] = match_id
	_adjutant_rules_cache[match_id] = rules
	return rules


## op=tactical：战术快照（三视图之三）。
## 参数：as_player（必填）、center:[x,z]、radius、limit（默认 128）、offset（续取）。
## 实体统一放 entities 数组，kind ∈ unit_self / unit_enemy / unit_enemy_frozen /
## unit_enemy_dead / resource；truncated + next_offset 显式截断续取。
func _op_tactical(match_node, parsed) -> Dictionary:
	var guard := _adjutant_require_observation()
	if not guard.is_empty():
		return guard
	var player = _adjutant_resolve_player(str(parsed.get("as_player", "")))
	if player == null:
		return {"error": "player not found", "reason": "as_player 必须是对局中存在的玩家节点名。"}
	var header: Dictionary = _adjutant_observation.BuildHeader(match_node, player)
	var match_id := str(header["match_id"])
	if match_id.is_empty():
		return {"error": "match unavailable", "reason": "当前对局没有稳定 match_id。"}
	var view_key := "%s|%s" % [match_id, str(player.name)]
	var current_tick := int(header["server_tick"])
	var center_raw: Array = parsed.get("center", [])
	var has_center := center_raw.size() >= 2
	var center := Vector2(float(center_raw[0]) if has_center else 0.0, float(center_raw[1]) if has_center else 0.0)
	var radius := float(parsed.get("radius", 0.0))
	var in_scope := func(position: Vector3) -> bool:
		if not has_center:
			return true
		var delta := Vector2(position.x, position.z) - center
		return delta.length() <= radius
	var limit := int(parsed.get("limit", 128))
	var offset := int(parsed.get("offset", 0))
	if limit <= 0:
		limit = 128
	if offset < 0:
		offset = 0

	var intel: Dictionary = _adjutant_intel.get(view_key, {})
	var world_names := {}
	var entities: Array = []
	var totals := {"self": 0, "enemy": 0, "enemy_frozen": 0, "enemy_dead": 0, "resource": 0}
	var covered := {"self": 0, "enemy": 0, "enemy_frozen": 0, "enemy_dead": 0, "resource": 0}

	for unit in get_tree().get_nodes_in_group("units"):
		if not _is_real_unit(unit):
			continue
		var unit_name := str(unit.name)
		world_names[unit_name] = true
		var mine: bool = unit.get_parent() == player
		if mine:
			totals["self"] += 1
			if not in_scope.call(unit.global_position):
				continue
			covered["self"] += 1
			entities.append(_tactical_self_entry(unit))
		else:
			var scouted: bool = _unit_scouted(unit, player)
			if scouted:
				totals["enemy"] += 1
				if not in_scope.call(unit.global_position):
					continue
				covered["enemy"] += 1
				# 只在本玩家当前视野内才更新情报；绝不写全局组。
				intel[unit_name] = {
					"unit_type": str(unit.get("unit_type_id")) if "unit_type_id" in unit else "",
					"pos": [unit.global_position.x, unit.global_position.y, unit.global_position.z],
					"hp": float(unit.hp) if "hp" in unit and unit.hp != null else 0.0,
					"hp_max": float(unit.hp_max) if "hp_max" in unit and unit.hp_max != null else 0.0,
					"last_seen_tick": current_tick,
					"confirmed_dead": false,
				}
				entities.append(_tactical_enemy_entry(unit_name, intel[unit_name], "unit_enemy"))
			elif intel.has(unit_name):
				totals["enemy_frozen"] += 1
				var frozen: Dictionary = intel[unit_name]
				# 失去视野：只读冻结情报，不更新位置/血量；死亡与否由世界移除单独判定。
				if frozen.get("confirmed_dead", false):
					continue
				entities.append({
					"kind": "unit_enemy_frozen",
					"name": unit_name,
					"unit_type": str(frozen.get("unit_type", "")),
					"pos": frozen.get("pos", [0.0, 0.0, 0.0]),
					"hp": float(frozen.get("hp", 0.0)),
					"hp_max": float(frozen.get("hp_max", 0.0)),
					"last_seen_tick": int(frozen.get("last_seen_tick", 0)),
					"confirmed_dead": false,
				})
				covered["enemy_frozen"] += 1
	# 确认死亡：上一轮已知、本轮世界已无 → 独立于失去视野的事件。
	for unit_name in intel.keys():
		if world_names.has(unit_name):
			continue
		var dead: Dictionary = intel[unit_name]
		if not bool(dead.get("confirmed_dead", false)):
			dead["confirmed_dead"] = true
			dead["confirmed_dead_tick"] = current_tick
		totals["enemy_dead"] += 1
		entities.append({
			"kind": "unit_enemy_dead",
			"name": unit_name,
			"unit_type": str(dead.get("unit_type", "")),
			"pos": dead.get("pos", [0.0, 0.0, 0.0]),
			"hp": 0.0,
			"hp_max": float(dead.get("hp_max", 0.0)),
			"last_seen_tick": int(dead.get("last_seen_tick", 0)),
			"confirmed_dead": true,
			"confirmed_dead_tick": int(dead.get("confirmed_dead_tick", current_tick)),
		})
		covered["enemy_dead"] += 1
	_adjutant_intel[view_key] = intel

	for resource in get_tree().get_nodes_in_group("resource_units"):
		if resource == null or not is_instance_valid(resource):
			continue
		totals["resource"] += 1
		if not in_scope.call(resource.global_position):
			continue
		covered["resource"] += 1
		var kind := "a" if "resource_a" in resource else ("b" if "resource_b" in resource else "unknown")
		entities.append({
			"kind": "resource",
			"name": str(resource.name),
			"resource_kind": kind,
			"pos": [resource.global_position.x, resource.global_position.y, resource.global_position.z],
		})

	# 截断与续取：显式报告，未返回的实体不等于阵亡（模型必须用 next_offset 续取）。
	var truncated := offset + limit < entities.size()
	var window := entities.slice(offset, min(offset + limit, entities.size()))
	var production: Array = []
	for unit in get_tree().get_nodes_in_group("units"):
		if not _is_real_unit(unit):
			continue
		if unit.get_parent() != player:
			continue
		var producer_view = _production_snapshot(match_node, unit)
		if producer_view != null:
			production.append(producer_view)
	var outcome_runtime = match_node.get_node_or_null("MatchOutcomeRuntime")
	header["entities"] = window
	header["covered"] = covered
	header["totals"] = totals
	header["production"] = production
	header["truncated"] = truncated
	header["next_offset"] = offset + limit if truncated else -1
	header["balance"] = {
		"a": int(player.resource_a) if "resource_a" in player else 0,
		"b": int(player.resource_b) if "resource_b" in player else 0,
	}
	# 玩家资源预留随观测一起下发：协调器据此限制副官花费（方案 §6 由权威端定义）。
	# 未初始化时这里会按当前余额建立 20% 基线，语义与 op=adjutant_reserves 完全一致。
	header["reserves"] = _adjutant_reserve_state(match_node, player).get("values", {})
	# 权威租约代际随观测每轮回传（2026-09-12）：协调器/权威端是**两套独立代际计数**，
	# 权威计数器跨对局全局累加，而协调器每轮从本地状态起算——任何单位第一次命令后
	# 租约代际就领先本地，之后所有命令被 StaleGeneration 白拒（实测 5 分钟 336 条、
	# 每单位只吃得到一条命令 = 产量停滞主因）。设计 §3：控制代际以**权威状态为准**。
	header["lease_generations"] = _adjutant_lease_generations(view_key)
	if outcome_runtime != null and outcome_runtime.has_method("InspectOutcome"):
		header["outcome"] = outcome_runtime.InspectOutcome()
	return header


## 该视图的权威租约代际快照（unit -> generation）。
func _adjutant_lease_generations(view_key: String) -> Dictionary:
	var out := {}
	var leases: Dictionary = _adjutant_leases.get(view_key, {})
	for unit_name in leases.keys():
		var lease: Dictionary = leases[unit_name]
		out[str(unit_name)] = int(lease.get("generation", 0))
	return out


## 我方实体条目：完整字段（能力/队列/施工/当前动作），供选择动作与目标。
func _tactical_self_entry(unit) -> Dictionary:
	var entry := {
		"kind": "unit_self",
		"name": str(unit.name),
		"unit_type": str(unit.get("unit_type_id")) if "unit_type_id" in unit else "",
		"hp": float(unit.hp) if "hp" in unit and unit.hp != null else 0.0,
		"hp_max": float(unit.hp_max) if "hp_max" in unit and unit.hp_max != null else 0.0,
		"pos": [unit.global_position.x, unit.global_position.y, unit.global_position.z],
		"movement": unit.find_child("Movement", false, false) != null,
		"queue": unit.find_child("ProductionQueue", false, false) != null,
		"attack": "attack_range" in unit,
		"gather": "resource_a" in unit and "resource_b" in unit,
		"construct": "construction_work_per_tick" in unit and int(unit.get("construction_work_per_tick")) > 0,
		"carried": [
			int(unit.resource_a) if "resource_a" in unit else 0,
			int(unit.resource_b) if "resource_b" in unit else 0,
		],
	}
	if "is_constructed" in unit:
		entry["constructed"] = bool(unit.is_constructed())
	# 施工进度（只读）：客户端傀儡上这个值只能来自 NetSync 快照的 `construction` 字段，
	# 因此**在客户端查 op=tactical 就能判定"施工同步是否真的生效"**，
	# 不必靠肉眼看画面（2026-09-11 用户指出交火/建造缺可视反馈）。
	if unit.has_method("construction_progress_report"):
		entry["construction_work"] = unit.construction_progress_report()
	if "action" in unit and unit.action != null and is_instance_valid(unit.action):
		entry["action"] = str(unit.action.get_script().resource_path) if unit.action.get_script() != null else str(unit.action)
	return entry


## 可见敌方条目（实时视野内数据 + last_seen_tick）。
func _tactical_enemy_entry(unit_name: String, intel_entry: Dictionary, kind: String) -> Dictionary:
	return {
		"kind": kind,
		"name": unit_name,
		"unit_type": str(intel_entry.get("unit_type", "")),
		"pos": intel_entry.get("pos", [0.0, 0.0, 0.0]),
		"hp": float(intel_entry.get("hp", 0.0)),
		"hp_max": float(intel_entry.get("hp_max", 0.0)),
		"last_seen_tick": int(intel_entry.get("last_seen_tick", 0)),
		"confirmed_dead": false,
	}


## op=strategic：战略摘要（三视图之二）：资源、产能、已知敌情及时间、地图边界、
## 可用能力与生产关系。任务进展由协调器管理，不在游戏端伪造。
func _op_strategic(match_node, parsed) -> Dictionary:
	var guard := _adjutant_require_observation()
	if not guard.is_empty():
		return guard
	var player = _adjutant_resolve_player(str(parsed.get("as_player", "")))
	if player == null:
		return {"error": "player not found", "reason": "as_player 必须是对局中存在的玩家节点名。"}
	var header: Dictionary = _adjutant_observation.BuildHeader(match_node, player)
	var match_id := str(header["match_id"])
	if match_id.is_empty():
		return {"error": "match unavailable", "reason": "当前对局没有稳定 match_id。"}
	var view_key := "%s|%s" % [match_id, str(player.name)]

	var production: Array = []
	for unit in get_tree().get_nodes_in_group("units"):
		if not _is_real_unit(unit):
			continue
		if unit.get_parent() != player:
			continue
		var producer_view = _production_snapshot(match_node, unit)
		if producer_view != null:
			production.append(producer_view)

	# 敌情摘要：来自本玩家 last_seen 情报（含确认死亡），带 tick 时间；无 full_vision。
	var intel: Dictionary = _adjutant_intel.get(view_key, {})
	var enemy_entries: Array = []
	for unit_name in intel.keys():
		var item: Dictionary = intel[unit_name]
		enemy_entries.append({
			"name": unit_name,
			"unit_type": str(item.get("unit_type", "")),
			"pos": item.get("pos", [0.0, 0.0, 0.0]),
			"hp": float(item.get("hp", 0.0)),
			"last_seen_tick": int(item.get("last_seen_tick", 0)),
			"confirmed_dead": bool(item.get("confirmed_dead", false)),
		})

	# 地图边界：当前对局实际地图尺寸（Match.map.size）。
	var map_bounds: Array = []
	if match_node.get("map") != null and "size" in match_node.get("map"):
		var map_size: Vector2 = match_node.get("map").size
		map_bounds = [map_size.x, map_size.y]

	# 可用能力：动作集 + 动态生产关系 + 可建造列表（全部来自规则视图，无硬编码名单）。
	var rules := _op_rules(match_node)
	var production_relations: Array = []
	var buildable: Array = []
	if not rules.has("error"):
		for relation in rules.get("productions", []):
			production_relations.append({
				"product_type_id": str(relation.get("product_type_id", "")),
				"cost": relation.get("cost", []),
				"allowed_producer_type_ids": relation.get("allowed_producer_type_ids", []),
			})
		for construction in rules.get("constructions", []):
			buildable.append({
				"id": str(construction.get("id", "")),
				"cost": construction.get("cost", []),
				"scene_path": str(construction.get("blueprint_scene_path", "")),
			})

	header["resources"] = {
		"a": int(player.resource_a) if "resource_a" in player else 0,
		"b": int(player.resource_b) if "resource_b" in player else 0,
	}
	# 战略视图同样带预留：战略层规划时就能看到"副官可用额度"，而不是先规划再被拒。
	header["reserves"] = _adjutant_reserve_state(match_node, player).get("values", {})
	header["enemy_balances_masked"] = true
	header["production"] = production
	header["enemy_intel"] = enemy_entries
	header["map_bounds"] = map_bounds
	header["available_actions"] = ["move", "attack_move", "attack", "gather", "stop", "produce", "build"]
	header["production_relations"] = production_relations
	header["buildable"] = buildable
	return header


## op=adjutant_command：副官统一命令入口（第一阶段动作集）。
## 验证链：结构 → 幂等 → 对局身份 → 玩家授权 → 规则版本 → 快照时效 → 过期 →
## 目标合法性（scene 必须来自规则视图）→ 控制租约 → 权威执行。
func _op_adjutant_command(match_node, parsed) -> Dictionary:
	var guard := _adjutant_require_observation()
	if not guard.is_empty():
		return _adjutant_receipt_error("InternalError", "副官观测运行时不可用。")
	var current_tick := int(_adjutant_observation.CurrentServerTick())
	var command_id := str(parsed.get("command_id", ""))
	var action := str(parsed.get("action", ""))
	if command_id.is_empty() or action.is_empty():
		return _adjutant_receipt_error("InvalidCommand", "command_id 与 action 为必填字段。")
	var match_id := _adjutant_match_id(match_node)
	if match_id.is_empty():
		return _adjutant_receipt_error("MatchUnavailable", "当前对局没有稳定 match_id，拒绝一切命令。")
	var requested_match := str(parsed.get("match_id", ""))
	if requested_match.is_empty():
		return _adjutant_receipt_error("InvalidCommand", "match_id 为必填字段。", command_id, match_id, "", current_tick)
	if requested_match != match_id:
		return _adjutant_receipt_error("MatchMismatch", "命令 match_id 与当前对局不一致，拒绝执行。", command_id, match_id, "", current_tick)
	var player_id := str(parsed.get("player_id", ""))
	var player = _adjutant_resolve_player(player_id)
	if player == null:
		return _adjutant_receipt_error("PlayerNotFound", "player_id 必须是对局中存在的玩家。", command_id, match_id, player_id, current_tick)
	if _is_human_player(player) == false:
		return _adjutant_receipt_error("PlayerNotAuthorized", "副官只能指挥真人玩家部队，不能接管 AI 玩家。", command_id, match_id, player_id, current_tick)
	var as_player := str(parsed.get("as_player", ""))
	if not as_player.is_empty() and as_player != player_id:
		return _adjutant_receipt_error("PlayerMismatch", "as_player 与 player_id 不一致。", command_id, match_id, player_id, current_tick)

	var view_key := "%s|%s" % [match_id, player_id]
	var params := str(parsed.get("params", {}))

	# 幂等：同 (match, player, command_id) 同参数 → 原回执；不同参数 → 显式冲突。
	var ledger: Dictionary = _adjutant_ledger.get(view_key, {})
	if ledger.has(command_id):
		var prior: Dictionary = ledger[command_id]
		if str(prior.get("params", "")) == params:
			var replay: Dictionary = (prior["receipt"] as Dictionary).duplicate(true)
			replay["idempotent_replay"] = true
			return replay
		return _adjutant_receipt_error("DuplicateConflict", "同 command_id 已用不同参数提交，明确拒绝。", command_id, match_id, player_id, current_tick)
	if _adjutant_ledger_size() >= ADJUTANT_LEDGER_LIMIT:
		# 【2026-09-12 实机实测，必须淘汰】幂等账本按 command_id 记录，
		# 而 command_id = "<match>|<intent_id>|<attempt>" 随 tick 只增不减：
		# 一局跑满 256 条之后**所有**新命令（含采集/生产/撤离）全部返回 LedgerFull，
		# 副官从此一条命令都发不出去（实测同局 LedgerFull 273/275、0 接受；
		# 且该表挂在进程上、跨对局不重建，下一局依然是死的）。
		# 背压的本意是"不静默遗忘未完成命令"，不是"永久锁死指挥链"。
		# 淘汰顺序与意图登记表一致：① 先丢已终态的最早记录；② 再丢最早的在途记录。
		if not _adjutant_ledger_evict_one():
			return _adjutant_receipt_error("LedgerFull", "幂等账本已满（背压），请等待旧命令终态复核后重试。", command_id, match_id, player_id, current_tick)

	# 对局与版本校验：新提交按当前版本保守拒绝；不自动取消任何已接受命令。
	var rules_version := str(parsed.get("rules_version", ""))
	var current_rules := _adjutant_rules_version(match_node)
	if rules_version != current_rules:
		return _adjutant_receipt_error("RulesVersionStale", "命令 rules_version 与当前对局规则不一致；请先重新获取规则视图。", command_id, match_id, player_id, current_tick)
	var based_on_snapshot := int(parsed.get("based_on_snapshot", -1))
	if based_on_snapshot >= 0:
		var latest: int = int(_adjutant_observation.NextSnapshotId()) - 1
		if based_on_snapshot > latest:
			return _adjutant_receipt_error("SnapshotInFuture", "based_on_snapshot 晚于当前已知快照，拒绝。", command_id, match_id, player_id, current_tick)

	var issued_tick := int(parsed.get("issued_tick", 0))
	var expires_tick := int(parsed.get("expires_tick", 0))
	if expires_tick <= 0 or current_tick > expires_tick:
		return _adjutant_receipt_error("Expired", "命令已过 expires_tick（服务器 tick 为准），拒绝执行。", command_id, match_id, player_id, current_tick)

	# 执行动作。 PendingAuthority（客户端转发路径）同样落账等待复核。
	# 深拷贝执行参数：不得污染调用方 params（幂等 params 指纹在执行前取样）。
	var params_dict: Dictionary = parsed.get("params", {}) if parsed.get("params", {}) is Dictionary else {}
	var exec_params: Dictionary = params_dict.duplicate(true)
	exec_params["as_player"] = player_id
	var result: Dictionary = _adjutant_execute(match_node, player, action, exec_params, command_id, match_id, player_id, current_tick)
	var receipt := {
		"ok": bool(result.get("accepted", false)),
		"accepted": bool(result.get("accepted", false)),
		"status": str(result.get("status", "Rejected")),
		"reason": str(result.get("reason", "")),
		"command_id": command_id,
		"request_id": str(parsed.get("request_id", "")),
		"task_id": str(parsed.get("task_id", "")),
		"plan_version": str(parsed.get("plan_version", "")),
		"rules_version": rules_version,
		"match_id": match_id,
		"player_id": player_id,
		"action": action,
		"issued_tick": issued_tick,
		"expires_tick": expires_tick,
		"server_tick": current_tick,
		"result": result,
	}
	ledger[command_id] = {"receipt": receipt, "params": params}
	_adjutant_ledger[view_key] = ledger
	return receipt


## op=adjutant_batch：逐条提交批次；明确非原子，前一条花掉资源后
## 后一条按剩余资源重新校验（权威入口天然逐条结算）。
func _op_adjutant_batch(match_node, parsed) -> Dictionary:
	var commands: Array = parsed.get("commands", []) if parsed.get("commands", []) is Array else []
	var receipts: Array = []
	var accepted_count := 0
	var rejected_count := 0
	for command in commands:
		if not (command is Dictionary):
			rejected_count += 1
			receipts.append({"ok": false, "status": "InvalidCommand", "reason": "批次元素必须是命令包对象。"})
			continue
		var receipt := _op_adjutant_command(match_node, command)
		receipts.append(receipt)
		if bool(receipt.get("accepted", false)):
			accepted_count += 1
		else:
			rejected_count += 1
	return {
		"ok": rejected_count == 0,
		"accepted": rejected_count == 0,
		"status": "Accepted" if rejected_count == 0 else ("PartiallyAccepted" if accepted_count > 0 else "Rejected"),
		"batch_total": commands.size(),
		"accepted_count": accepted_count,
		"rejected_count": rejected_count,
		"receipts": receipts,
	}


## op=adjutant_intent：LangGraph 战术意图入口（有限期意图 + 控制代际）。
## 验证链：结构 → 意图登记幂等 → 对局身份 → TTL 过期 → 控制代际/租约 →
##        然后复用 op=adjutant_command 的完整权威链（规则/快照/目标/执行/幂等账本）。
## 纪律：游戏侧不掌握战略计划版本，计划版本一致性由协调器与图负责；
## 游戏侧只做代际、租约、过期、身份、目标与资源合法性校验。
func _op_adjutant_intent(match_node, parsed) -> Dictionary:
	var guard := _adjutant_require_observation()
	if not guard.is_empty():
		return _adjutant_receipt_error("InternalError", "副官观测运行时不可用。")
	var current_tick := int(_adjutant_observation.CurrentServerTick())
	var intent_id := str(parsed.get("intent_id", ""))
	var action := str(parsed.get("action", ""))
	if intent_id.is_empty() or action.is_empty():
		return _adjutant_receipt_error("InvalidCommand", "intent_id 与 action 为必填字段。",
			"", "", "", current_tick)
	var match_id := _adjutant_match_id(match_node)
	if match_id.is_empty():
		return _adjutant_receipt_error("MatchUnavailable", "当前对局没有稳定 match_id，拒绝一切意图。",
			intent_id, "", "", current_tick)
	var player_id := str(parsed.get("player_id", ""))
	var view_key := "%s|%s" % [match_id, player_id]
	var expires_tick := int(parsed.get("expires_tick", 0))
	if expires_tick <= 0 or current_tick > expires_tick:
		return _adjutant_intent_receipt("Expired",
			"意图已过 expires_tick（服务器 tick 为准），拒绝执行。",
			intent_id, match_id, player_id, current_tick, action, parsed, {})

	# 幂等：同 intent_id 重复提交返回原回执（不重复下发、不重复扣费）。
	var registry: Dictionary = _adjutant_intents.get(view_key, {})
	if registry.has(intent_id):
		var prior: Dictionary = registry[intent_id]
		var replay: Dictionary = (prior.get("receipt", {}) as Dictionary).duplicate(true)
		replay["intent_id"] = intent_id
		replay["intent_replay"] = true
		return replay
	if _adjutant_intent_count() >= ADJUTANT_INTENT_LIMIT:
		# 满时先**淘汰最早记录**（见 _adjutant_intent_evict_one 的长注释），
		# 只有实在淘汰不掉才真的回背压拒绝。
		#
		# 【2026-09-11 实机实测，必须保留这条淘汰】意图 id **必须带 tick**
		# （否则重试会命中最早那次回执，是"改了参数却毫无变化"的真凶），
		# 因此一局下来 intent_id 必然持续增长：实测 8 分钟约 300 条
		# （attack 205 / gather 60 / produce 32 / build 2 / move 2 / retreat 6）。
		# 而登记表**原本没有任何删除路径** → 达到 128 上限后**所有**命令
		# （含劣势撤离）一律返回 IntentLedgerFull → 部队从那一刻起完全无法行动，
		# 实测我方基地与全部单位被推平、整局崩盘；且该表挂在进程上、跨对局不重建，
		# 下一局仍然是死的。背压的本意是"不静默遗忘未完成意图"，不是"永久锁死指挥链"。
		if not _adjutant_intent_evict_one():
			return _adjutant_intent_receipt("IntentLedgerFull",
				"意图登记已满（背压），请等待终态复核后重试。",
				intent_id, match_id, player_id, current_tick, action, parsed, {})

	var params_dict: Dictionary = parsed.get("params", {}) if parsed.get("params", {}) is Dictionary else {}
	var units: Array = []
	if params_dict.get("units", []) is Array:
		units = params_dict.get("units", [])
	# Phase 4 翻译层：方案 §6 允许的高层战术动作 → 已实现的执行层动作（不新增玩法）。
	var translation := _adjutant_translate_action(action, params_dict)
	action = str(translation["action"])
	params_dict = translation["params"]
	# 场景目标允许给“规则内的 id”，由权威层解析成规则内的 scene_path；解析不得越出规则。
	var scene_note := ""
	if params_dict.has("scene"):
		var raw_scene := str(params_dict.get("scene", ""))
		var resolved := _adjutant_resolve_scene_path(match_node, raw_scene)
		if resolved != raw_scene:
			scene_note = "%s->%s" % [raw_scene, resolved]
			params_dict["scene"] = resolved
	var generation := int(parsed.get("generation", 0))
	# 显式重新接管申请：只在此请求下才允许越过“租约已被玩家取消”的拦截，
	# 最终是否放行仍由 _adjutant_authorize_units 的 reacquire 分支裁决并记录。
	var reacquire := bool(params_dict.get("reacquire", false))
	if generation > 0:
		var stale_guard := _adjutant_generation_guard(view_key, units, generation, reacquire)
		if not stale_guard.is_empty():
			return _adjutant_intent_receipt(str(stale_guard["status"]),
				str(stale_guard["reason"]), intent_id, match_id, player_id,
				current_tick, action, parsed, {})

	# 复用统一命令入口：规则版本/快照时效/目标合法性/租约/幂等账本全部走同一权威链。
	var command := {
		"command_id": str(parsed.get("command_id", intent_id)),
		"request_id": str(parsed.get("request_id", "")),
		"intent_id": intent_id,
		"match_id": match_id,
		"player_id": player_id,
		"as_player": str(parsed.get("as_player", "")),
		"rules_version": str(parsed.get("rules_version", "")),
		"plan_version": str(parsed.get("plan_version", "")),
		"task_id": str(parsed.get("task_id", "")),
		"based_on_snapshot": int(parsed.get("based_on_snapshot", -1)),
		"issued_tick": int(parsed.get("issued_tick", current_tick)),
		"expires_tick": expires_tick,
		"action": action,
		"params": params_dict.duplicate(true),
	}
	var receipt := _op_adjutant_command(match_node, command)
	receipt["intent_id"] = intent_id
	receipt["intent_action"] = action
	receipt["generation"] = generation
	if not str(translation.get("from", "")).is_empty():
		receipt["action_translated_from"] = str(translation["from"])
	if not scene_note.is_empty():
		receipt["scene_resolved_from"] = scene_note
	registry[intent_id] = {
		"intent_id": intent_id,
		"action": action,
		"action_requested": str(parsed.get("action", "")),
		"unit_ids": units,
		"generation": generation,
		"issue_tick": int(parsed.get("issued_tick", current_tick)),
		"expires_tick": expires_tick,
		"decided_tick": current_tick,
		"status": str(receipt.get("status", "")),
		"accepted": bool(receipt.get("accepted", false)),
		"receipt": receipt,
	}
	_adjutant_intents[view_key] = registry
	return receipt


## 构造意图级回执（未进入权威命令链时使用；字段与命令回执保持兼容）。
func _adjutant_intent_receipt(status: String, reason: String, intent_id: String,
		match_id: String, player_id: String, current_tick: int, action: String,
		parsed, extras: Dictionary) -> Dictionary:
	var receipt := _adjutant_receipt_error(status, reason, intent_id, match_id,
		player_id, current_tick)
	receipt["intent_id"] = intent_id
	receipt["intent_action"] = action
	receipt["generation"] = int(parsed.get("generation", 0))
	receipt["plan_version"] = str(parsed.get("plan_version", ""))
	receipt["task_id"] = str(parsed.get("task_id", ""))
	for key in extras.keys():
		receipt[key] = extras[key]
	return receipt


## Phase 4 翻译层：把方案 §6 允许的高层战术动作映射到已实现的执行层动作。
## 只做语义等价翻译，不新增/不改变任何玩法逻辑：
##   scout/regroup/retreat → move（既有移动）；defend → attack_move（有目标点）或 stop；hold → stop。
## 返回 {"action": 执行层动作, "params": 归一化参数, "from": 原始高层动作（空表示未翻译）}。
func _adjutant_translate_action(action: String, params: Dictionary) -> Dictionary:
	var mapped := action
	var out_params: Dictionary = params.duplicate(true)
	var from := ""
	var has_dest := out_params.has("pos") or out_params.has("dest")
	match action:
		"scout", "regroup", "retreat":
			mapped = "move"
			from = action
		"defend":
			mapped = "attack_move" if has_dest else "stop"
			from = action
		"hold":
			mapped = "stop"
			from = action
		_:
			pass
	if from.is_empty():
		return {"action": mapped, "params": out_params, "from": ""}
	# 移动类动作：统一成执行层使用的 dest（[x,z]）。
	if mapped == "move" or mapped == "attack_move":
		if not out_params.has("dest") and out_params.has("pos"):
			var pos_value = out_params.get("pos", null)
			if pos_value is Array and (pos_value as Array).size() >= 2:
				out_params["dest"] = [(pos_value as Array)[0], (pos_value as Array)[1]]
	out_params["intent_action"] = action
	out_params["translated_action"] = mapped
	return {"action": mapped, "params": out_params, "from": from}


## 场景目标解析：允许模型给“规则内的 id”（生产物类型 id / 建造物 id），
## 解析为规则视图里的 scene_path；非规则来源一律原样返回（后续会被 UntrustedScene 拒绝）。
func _adjutant_resolve_scene_path(match_node, raw_scene: String) -> String:
	if raw_scene.is_empty() or raw_scene.begins_with("res://"):
		return raw_scene
	var rules := _op_rules(match_node)
	if rules.has("error"):
		return raw_scene
	for unit_type in rules.get("unit_types", []):
		if str(unit_type.get("id", "")) == raw_scene:
			var path := str(unit_type.get("scene_path", ""))
			if not path.is_empty():
				return path
	for construction in rules.get("constructions", []):
		if str(construction.get("id", "")) == raw_scene:
			var blueprint := str(construction.get("blueprint_scene_path", ""))
			if not blueprint.is_empty():
				return blueprint
	return raw_scene


## 控制代际守卫：意图代际落后于租约代际 → StaleGeneration；
## 租约已被玩家取消 → PlayerOverride（带 reacquire 的显式重新接管申请除外）。
## 返回空字典表示通过。
func _adjutant_generation_guard(view_key: String, units: Array, generation: int,
		reacquire: bool = false) -> Dictionary:
	var leases: Dictionary = _adjutant_leases.get(view_key, {})
	for unit_name in units:
		var key := str(unit_name)
		if not leases.has(key):
			continue
		var lease: Dictionary = leases[key]
		var lease_generation := int(lease.get("generation", 0))
		if generation < lease_generation:
			return {"status": "StaleGeneration",
				"reason": "意图控制代际 %d 落后于单位 %s 的租约代际 %d；旧模型响应不能抢回控制。" % [
					generation, key, lease_generation]}
		if not bool(lease.get("active", true)) and not reacquire:
			return {"status": "PlayerOverride",
				"reason": "单位 %s 的控制租约已被玩家手动命令取消；重新接管需要显式 reacquire 授权。" % key}
	return {}


## 意图登记总量（跨对局/玩家共享上限，显式背压）。
func _adjutant_intent_count() -> int:
	var total := 0
	for key in _adjutant_intents.keys():
		total += (_adjutant_intents[key] as Dictionary).size()
	return total


## 容量满时淘汰**一条**最早记录（FIFO 环形）。返回是否淘汰成功。
##
## 为什么必须淘汰而不是一味拒绝（2026-09-11 实机实测）：
## 意图 id 必须带 tick（`rule-build-<building>-<builder>-<tick>` /
## `bt-<action>-<unit>-<tick>`），否则重试会一直被游戏侧的幂等回执命中
## 最早那次结果 —— 那是"改了参数却毫无变化"的真凶。代价是 intent_id
## **必然随 tick 持续增长**：实测 8 分钟约 300 条意图。
## 而登记表原先没有任何删除路径，128 条一到就返回 IntentLedgerFull，
## **所有**后续命令（包括劣势撤离）全部被拒 → 部队彻底无法行动、
## 我方基地被推平；且登记表挂在进程上不随对局重建，下一局依然是死的。
##
## 淘汰顺序（既保住背压本意，又不锁死指挥链）：
##   ① 先丢**已终态**（非 PendingAuthority/Deferred）的最早记录；
##   ② 再丢最早的在途记录；
## 并且 `push_warning` 留痕 —— **不做静默遗忘**。
func _adjutant_intent_evict_one() -> bool:
	var terminal: Array = []
	var pending: Array = []
	for key in _adjutant_intents.keys():
		var registry: Dictionary = _adjutant_intents[key]
		for intent_id in registry.keys():
			var record: Dictionary = registry[intent_id]
			var status := str(record.get("status", ""))
			var item := {
				"view": str(key),
				"intent_id": str(intent_id),
				"tick": int(record.get("decided_tick", record.get("issue_tick", 0))),
			}
			if status == "PendingAuthority" or status == "Deferred":
				pending.append(item)
			else:
				terminal.append(item)
	var victim = null
	if not terminal.is_empty():
		terminal.sort_custom(_adjutant_intent_older_first)
		victim = terminal[0]
	elif not pending.is_empty():
		pending.sort_custom(_adjutant_intent_older_first)
		victim = pending[0]
	if victim == null:
		return false
	var victim_view := str(victim["view"])
	var victim_id := str(victim["intent_id"])
	var victim_registry: Dictionary = _adjutant_intents.get(victim_view, {})
	victim_registry.erase(victim_id)
	push_warning("[adjutant] 意图登记已满，淘汰最早记录 %s（避免背压锁死指挥链）" % victim_id)
	return true


func _adjutant_intent_older_first(a: Dictionary, b: Dictionary) -> bool:
	return int(a["tick"]) < int(b["tick"])


## 幂等账本满时淘汰**一条**最早记录（与 `_adjutant_intent_evict_one` 同一纪律）。
##
## 为什么账本也需要淘汰（2026-09-12 实机实测）：
## `command_id` 形如 `<match>|<intent_id>|<attempt>`，而 intent_id 必须带 tick，
## 所以一局下来 command_id 只增不减；账本原先**没有任何删除路径**，
## 达到 256 上限后返回 `LedgerFull`，**所有**后续命令一律被拒
## （实测同一局 273/275 条回执都是 LedgerFull、0 接受）→ 副官看起来在跑，
## 实际一条命令都落不了地。账本的作用是"在途命令幂等"，终态记录只需短暂存。
##
## 淘汰顺序：① 先丢**已终态**（非 PendingAuthority/Deferred）的最早记录；
##           ② 再丢最早的在途记录；并 `push_warning` 留痕（不做静默遗忘）。
func _adjutant_ledger_evict_one() -> bool:
	var terminal: Array = []
	var pending: Array = []
	for key in _adjutant_ledger.keys():
		var ledger: Dictionary = _adjutant_ledger[key]
		for command_id in ledger.keys():
			var entry: Dictionary = ledger[command_id]
			var receipt: Dictionary = entry.get("receipt", {}) if entry.get("receipt", {}) is Dictionary else {}
			var status := str(receipt.get("status", ""))
			var item := {
				"view": str(key),
				"command_id": str(command_id),
				"tick": int(entry.get("tick", receipt.get("server_tick", 0))),
			}
			if status == "PendingAuthority" or status == "Deferred":
				pending.append(item)
			else:
				terminal.append(item)
	var victim = null
	if not terminal.is_empty():
		terminal.sort_custom(_adjutant_intent_older_first)
		victim = terminal[0]
	elif not pending.is_empty():
		pending.sort_custom(_adjutant_intent_older_first)
		victim = pending[0]
	if victim == null:
		return false
	var victim_view := str(victim["view"])
	var victim_id := str(victim["command_id"])
	var victim_ledger: Dictionary = _adjutant_ledger.get(victim_view, {})
	victim_ledger.erase(victim_id)
	push_warning("[adjutant] 幂等账本已满，淘汰最早记录 %s（避免背压锁死指挥链）" % victim_id)
	return true


## 本玩家当前余额（与 op=tactical 的 balance 同源，不另建经济账）。
func _adjutant_balance_of(player) -> Dictionary:
	return {
		"A": int(player.resource_a) if "resource_a" in player else 0,
		"B": int(player.resource_b) if "resource_b" in player else 0,
	}


## 读取（必要时初始化）本局该玩家的预留额度。
## 初始化只发生一次：之后不论余额怎么变，都保持玩家设定的绝对值。
func _adjutant_reserve_state(match_node, player) -> Dictionary:
	var match_id := _adjutant_match_id(match_node)
	if match_id.is_empty() or player == null:
		return {"initialized": false, "percent": ADJUTANT_RESERVE_PERCENT, "values": {}}
	var view_key := "%s|%s" % [match_id, str(player.name)]
	if not _adjutant_reserves.has(view_key):
		var balance := _adjutant_balance_of(player)
		var values := {}
		for kind in balance.keys():
			# 向下取整：预留必须是整数量级，不能出现小数余额。
			values[kind] = int(balance[kind]) * ADJUTANT_RESERVE_PERCENT / 100
		_adjutant_reserves[view_key] = {
			"initialized": true,
			"percent": ADJUTANT_RESERVE_PERCENT,
			"values": values,
		}
	return _adjutant_reserves[view_key]


## op=adjutant_reserves：玩家查看 / 调整资源预留（按类型的**绝对值**）。
## 只改"副官最多能花多少"，不改玩法余额；设为 0 表示该项不预留（副官可使用全部）。
func _op_adjutant_reserves(match_node, parsed) -> Dictionary:
	var guard := _adjutant_require_observation()
	if not guard.is_empty():
		return guard
	var wanted := str(parsed.get("as_player", ""))
	var player = _adjutant_resolve_player(wanted)
	if player == null and wanted.is_empty():
		# 本机 HUD 便利路径：单机自定义对局只有一名玩家时不必自报身份。
		player = _adjutant_lone_player()
	if player == null:
		return {"error": "player not found",
			"reason": "as_player 必须是对局中存在的玩家节点名（联机多玩家时必须显式给出）。"}
	var reserve_state := _adjutant_reserve_state(match_node, player)
	if str(parsed.get("action", "get")) == "set":
		var params = parsed.get("reserves", {})
		if not (params is Dictionary):
			return {"error": "bad reserves",
				"reason": "reserves 必须是 {资源类型: 绝对额度} 字典（如 {\"A\": 500}）。"}
		var values: Dictionary = reserve_state.get("values", {})
		for kind in params.keys():
			values[str(kind).to_upper()] = int(params[kind])
		reserve_state["values"] = values
		reserve_state["initialized"] = true
	return {
		"ok": true,
		"match_id": _adjutant_match_id(match_node),
		"player_id": str(player.name),
		"balance": _adjutant_balance_of(player),
		"reserves": reserve_state.get("values", {}),
		"percent": int(reserve_state.get("percent", ADJUTANT_RESERVE_PERCENT)),
	}


## op=adjutant_leases：只读查询当前租约代际与意图登记（验收/诊断；不改玩法）。
func _op_adjutant_leases(match_node, parsed) -> Dictionary:
	var guard := _adjutant_require_observation()
	if not guard.is_empty():
		return guard
	var match_id := _adjutant_match_id(match_node)
	if match_id.is_empty():
		return {"error": "match unavailable", "reason": "当前对局没有稳定 match_id。"}
	var player_id := str(parsed.get("player_id", parsed.get("as_player", "")))
	var view_key := "%s|%s" % [match_id, player_id]
	return {
		"ok": true,
		"match_id": match_id,
		"player_id": player_id,
		"server_tick": int(_adjutant_observation.CurrentServerTick()),
		"leases": _adjutant_leases.get(view_key, {}),
		"intents": _adjutant_intents.get(view_key, {}),
	}


## op=lobby：只读大厅快照 + 本机身份（用于核验“同一台电脑只有一个指挥官”）。
func _op_lobby() -> Dictionary:
	var net := get_node_or_null("/root/NetSession")
	if net == null:
		return {"error": "NetSessionUnavailable"}
	return net.lobby_snapshot()


## 副官动作执行：优先复用现有 op 实现（同一权威路径），scene 类目标必须来自规则视图。
func _adjutant_execute(match_node, player, action: String, params: Dictionary,
		command_id: String, match_id: String, player_id: String, current_tick: int) -> Dictionary:
	if not _adjutant_authorize_units(player, params, command_id, match_id, player_id, current_tick):
		return {"accepted": false, "status": "PlayerOverride",
			"reason": "目标单位控制租约已被玩家手动命令取消；重新接管需要显式 reacquire 授权。"}
	var scene_guard: Dictionary = _adjutant_check_scene(match_node, action, params, player)
	if not scene_guard.is_empty():
		return scene_guard
	_adjutant_executing = true
	var result: Dictionary
	match action:
		"move":
			result = _parse_op_result(_op_move(match_node, params))
		"gather":
			result = _parse_op_result(_op_gather(match_node, params))
		"attack":
			result = _parse_op_result(_op_attack(match_node, params))
		"attack_move":
			result = _adjutant_execute_attack_move(match_node, player, params)
		"stop":
			result = _adjutant_execute_stop(match_node, player, params)
		"produce":
			result = _parse_op_result(_op_produce(match_node, params))
		"build":
			result = _parse_op_result(_op_build(match_node, params))
		_:
			result = {"accepted": false, "status": "UnsupportedAction",
				"reason": "动作 %s 不在第一阶段副官动作集内（未知机制显式 unsupported）。" % action}
	_adjutant_executing = false
	return result


## 命令可视化登记（纯表现层，2026-09-10）：把一次命令的动作/受令单位/目标点广播给表现层。
## 只影响画面，不改变任何权威状态；副官命令由 _adjutant_executing 标记来源。
## 目标点语义：move/attack_move=dest，gather=资源点，build=放置点，attack=敌方单位，produce=生产建筑。
func _visualize_command(match_node, action: String, unit_nodes: Array, target: Vector3) -> void:
	if match_node == null or unit_nodes.is_empty() or not target.is_finite():
		return
	var sync = match_node.get_node_or_null("NetSync")
	if sync == null or not sync.has_method("broadcast_order_visual"):
		return
	var names: Array = []
	for unit in unit_nodes:
		if unit != null and is_instance_valid(unit):
			names.append(str(unit.name))
	if names.is_empty():
		return
	sync.broadcast_order_visual({
		"action": action,
		"units": names,
		"target": [target.x, target.z],
		"source": "adjutant" if _adjutant_executing else "player",
		"tick": int(_adjutant_observation.CurrentServerTick()) if _adjutant_observation != null else 0,
	})


## 解析旧 op JSON 字符串结果为字典（复用路径的协议适配）。
func _parse_op_result(text: String) -> Dictionary:
	var parsed = JSON.parse_string(text)
	if parsed is Dictionary:
		return parsed
	return {"accepted": false, "status": "Rejected", "reason": "内部执行结果解析失败。"}


## attack_move 直接走权威网关（没有等价旧 op）。
func _adjutant_execute_attack_move(match_node, player, params: Dictionary) -> Dictionary:
	var gateway = NetSession.command_gateway_for(player)
	if gateway == null:
		return {"accepted": false, "status": "NoGateway", "reason": "该玩家没有可用的命令网关。"}
	var nodes := _resolve_own_units(player, params.get("units", []))
	if nodes.is_empty():
		return {"accepted": false, "status": "UnitsNotFound", "reason": "找不到属于该玩家的攻击移动单位。"}
	var dest_raw: Array = params.get("dest", [0.0, 0.0])
	var destination := Vector3(float(dest_raw[0]) if dest_raw.size() > 0 else 0.0, 0.0, float(dest_raw[1]) if dest_raw.size() > 1 else 0.0)
	var result: Dictionary = gateway.GroundAttackMoveUnits(nodes, destination, player)
	_visualize_command(match_node, "attack_move", nodes, destination)
	return _unified_receipt(result, {"moved": nodes.map(func(n): return n.name)})


## stop 直接走权威网关。
func _adjutant_execute_stop(match_node, player, params: Dictionary) -> Dictionary:
	var gateway = NetSession.command_gateway_for(player)
	if gateway == null:
		return {"accepted": false, "status": "NoGateway", "reason": "该玩家没有可用的命令网关。"}
	var nodes := _resolve_own_units(player, params.get("units", []))
	if nodes.is_empty():
		return {"accepted": false, "status": "UnitsNotFound", "reason": "找不到属于该玩家的单位。"}
	var result: Dictionary = gateway.StopUnits(nodes, player)
	return _unified_receipt(result, {})


## scene 类目标校验：场景路径必须命中当前规则视图的受信任映射；
## 生产选择必须匹配动态生产关系（不硬编码坦克/工厂名单）。
func _adjutant_check_scene(match_node, action: String, params: Dictionary, player) -> Dictionary:
	if action != "produce" and action != "build":
		return {}
	var rules := _op_rules(match_node)
	if rules.has("error"):
		return {"accepted": false, "status": "RulesUnavailable", "reason": "规则视图不可用，无法校验场景目标。"}
	var scene_path := str(params.get("scene", ""))
	if scene_path.is_empty():
		return {"accepted": false, "status": "InvalidCommand", "reason": "缺少 scene 目标路径。"}
	var type_by_scene := {}
	for unit_type in rules.get("unit_types", []):
		type_by_scene[str(unit_type.get("scene_path", ""))] = str(unit_type.get("id", ""))
	if not type_by_scene.has(scene_path):
		return {"accepted": false, "status": "UntrustedScene",
			"reason": "scene 不在当前规则视图的受信任映射中；模型不得构造任意资源路径。"}
	var target_type: String = str(type_by_scene[scene_path])
	if action == "produce":
		var producer_name := str(params.get("unit", params.get("producer", "")))
		var producer_type := ""
		for unit in _resolve_own_units(player, [producer_name]):
			producer_type = str(unit.get("unit_type_id")) if "unit_type_id" in unit else ""
		for relation in rules.get("productions", []):
			if str(relation.get("product_type_id", "")) != target_type:
				continue
			if producer_type in (relation.get("allowed_producer_type_ids", []) as Array):
				return {}
			return {"accepted": false, "status": "InvalidProducer",
				"reason": "按当前动态生产关系，%s 不能生产 %s。" % [producer_type, target_type]}
		return {"accepted": false, "status": "ProductNotAllowed",
			"reason": "当前规则没有 %s 的生产定义（未知内容显式 unsupported）。" % target_type}
	# build：目标类型必须存在建筑施工定义。
	for construction in rules.get("constructions", []):
		if str(construction.get("unit_type_id", "")) == target_type:
			return {}
	return {"accepted": false, "status": "NotBuildable",
		"reason": "当前规则没有 %s 的施工定义，不能建造。" % target_type}


## 控制租约：玩家手动命令使租约失效；重新接管必须带 reacquire=true 显式授权。
## 返回 false 表示存在被玩家接管且未重新授权的目标单位（拒绝整条命令）。
func _adjutant_authorize_units(player, params: Dictionary,
		command_id: String, match_id: String, player_id: String, current_tick: int) -> bool:
	var wanted: Array = params.get("units", []) if params.get("units", []) is Array else []
	if wanted.is_empty():
		return true
	var reacquire := bool(params.get("reacquire", false))
	var view_key := "%s|%s" % [match_id, player_id]
	var leases: Dictionary = _adjutant_leases.get(view_key, {})
	var overridden := false
	for unit_name in wanted:
		if leases.has(str(unit_name)) and not bool(leases[str(unit_name)].get("active", true)):
			overridden = true
	if overridden and not reacquire:
		return false
	if overridden and reacquire:
		# 显式重新接管：记录授权事实与命令关联（第一阶段协议字段，UI 属第二阶段）。
		for unit_name in wanted:
			if leases.has(str(unit_name)):
				_adjutant_lease_generation += 1
				leases[str(unit_name)] = {
					"generation": _adjutant_lease_generation,
					"active": true,
					"reacquired_command_id": command_id,
					"reacquired_tick": current_tick,
				}
		_adjutant_leases[view_key] = leases
		return true
	# 首次租用：登记代际。
	for unit_name in wanted:
		if not leases.has(str(unit_name)):
			_adjutant_lease_generation += 1
			leases[str(unit_name)] = {"generation": _adjutant_lease_generation, "active": true}
	_adjutant_leases[view_key] = leases
	return true


## 玩家手动命令收口：立即取消副官对相关单位的控制租约。
## 调用方：本文件内各手动 op（直执行成功后）与 UnitActionsController（真实 UI 路径）。
func notify_player_override(player_name: String, unit_names: Array) -> void:
	if _adjutant_executing or unit_names.is_empty():
		return
	for pair_key in _adjutant_leases.keys():
		var suffix := "|" + player_name
		if not str(pair_key).ends_with(suffix):
			continue
		var leases: Dictionary = _adjutant_leases[pair_key]
		for unit_name in unit_names:
			if leases.has(str(unit_name)):
				leases[str(unit_name)]["active"] = false


## 幂等账本总容量统计（跨对局/玩家共享上限，显式背压）。
func _adjutant_ledger_size() -> int:
	var total := 0
	for view_key in _adjutant_ledger.keys():
		total += (_adjutant_ledger[view_key] as Dictionary).size()
	return total


## 构造带身份上下文的错误回执。
func _adjutant_receipt_error(status: String, reason: String, command_id := "",
		match_id := "", player_id := "", current_tick := -1) -> Dictionary:
	return {
		"ok": false,
		"accepted": false,
		"status": status,
		"reason": reason,
		"command_id": command_id,
		"match_id": match_id,
		"player_id": player_id,
		"server_tick": current_tick,
		"result": {},
	}
