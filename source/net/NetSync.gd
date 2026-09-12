extends Node

## 挂在 Match 下：客户端把命令转发到服务器，服务器按 10Hz 广播单位快照。

const SNAPSHOT_INTERVAL_FRAMES := 6
# GDScript 的 `is` 右侧不能用局部变量（parse error），用脚本资源等价比较代替。
const HumanScript := preload("res://source/match/players/human/Human.gd")
# 命令可视化（纯表现层）：客户端侧动态挂载，画副官指令的信标与路径；专用服不挂载。
const CommandVisualizerScript := preload("res://source/match/hud/CommandVisualizer.gd")

var _match: Node = null
var _frame := 0
var _live := false
var _local_match_started := false

# 复核 P0-1：初始实体清单——NodePath 一致性的启动期硬校验，错了拒绝 go-live。
var _own_manifest: PackedStringArray = PackedStringArray()
var _client_manifests: Dictionary = {}  # peer_id -> PackedStringArray
var _go_live_blocked := false

# 复核 P1-1：客户端两快照线性插值（渲染落后一个快照周期，消除 10Hz 瞬移感）。
var _interp_prev: Dictionary = {}  # Match 相对路径 -> Vector3
var _interp_target: Dictionary = {}  # Match 相对路径 -> Vector3
var _interp_prev_yaw: Dictionary = {}  # Match 相对路径 -> float（平面朝向，弧度）
var _interp_target_yaw: Dictionary = {}  # Match 相对路径 -> float
var _last_snap_msec := 0
var _snap_interval_msec := 100

# 监督 HUD：右上角显示 延迟/FPS（云服显示 RTT，本机房显示"本机"，离线显示"单机"）。
var _hud_label: Label = null
var _hud_accum := 0.0
var _authoritative_stance_by_path := {}
var _authoritative_fire_policy_by_path := {}


func _ready() -> void:
	_match = get_parent()
	# 表现层挂载点在 is_networked() 早退之前：单机局也能看到命令可视化。
	if not NetSession.is_dedicated_server():
		_ensure_order_visualizer()
	set_physics_process(NetSession.is_networked())
	if not NetSession.is_networked():
		return
	MatchSignals.match_started.connect(_on_any_match_started)
	# 对局结束广播(2026-08-31): 服务器结算后通知所有客户端回主菜单,
	# 否则客户端滞留死亡对局——视野归零全黑+HUD(黑屏假象), 且专用服不回收。
	MatchSignals.match_finished_with_defeat.connect(_on_match_finished.bind("失败"))
	MatchSignals.match_finished_with_victory.connect(_on_match_finished.bind("胜利"))
	if NetSession.is_server():
		MatchSignals.unit_spawned.connect(_on_unit_spawned)
		NetSession.player_dropped.connect(_on_player_dropped)
	if not NetSession.is_dedicated_server():
		_ensure_hud()


func _ensure_hud() -> void:
	if _hud_label != null:
		return
	var layer := CanvasLayer.new()
	layer.layer = 60
	add_child(layer)
	_hud_label = Label.new()
	_hud_label.add_theme_font_size_override("font_size", 14)
	_hud_label.add_theme_color_override("font_color", Color(0.95, 0.93, 0.85))
	_hud_label.add_theme_color_override("font_outline_color", Color(0.1, 0.08, 0.05, 0.75))
	_hud_label.add_theme_constant_override("outline_size", 4)
	layer.add_child(_hud_label)
	_hud_label.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	_hud_label.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_hud_label.offset_right = -12.0
	_hud_label.offset_top = 8.0


## 命令可视化器：只在有渲染的角色上挂载（专用服 headless 不建节点）。
func _ensure_order_visualizer() -> void:
	if _match == null or _match.get_node_or_null("CommandVisualizer") != null:
		return
	var visualizer := CommandVisualizerScript.new()
	visualizer.name = "CommandVisualizer"
	_match.add_child(visualizer)


func _hud_tick(delta: float) -> void:
	if _hud_label == null:
		return
	_hud_accum += delta
	if _hud_accum < 0.5:
		return
	_hud_accum = 0.0
	var ping_text := "单机"
	if NetSession.is_networked():
		if NetSession.is_server():
			ping_text = "本机房 %d 人" % NetSession.connected_human_count()
		else:
			NetSession.send_ping()
			var ping := NetSession.get_ping_ms()
			# 0 = RTT 样本未积累（刚连上），显示 -- 避免误读成"0 延迟"。
			ping_text = ("%d ms" % ping) if ping > 0 else "-- ms"
	_hud_label.text = "%s · %d FPS" % [ping_text, Engine.get_frames_per_second()]


func _on_any_match_started() -> void:
	NetSession.notify_match_ready()
	# match_started 在初始单位装配完成后发射（Match.gd:88），此时清单已稳定。
	_own_manifest = _collect_unit_paths()
	if not NetSession.is_server():
		_rpc_submit_manifest.rpc_id(1, _own_manifest)
	if NetSession.is_server():
		_local_match_started = true
		_try_go_live()


func _try_go_live() -> void:
	if not NetSession.is_server() or not _local_match_started:
		return
	if _go_live_blocked:
		return
	if not NetSession.all_human_matches_ready():
		return
	# 每个客户端（不含服务器自己）都必须提交清单且与服务器一致，否则拒绝开局。
	for peer_id in NetSession.human_peer_ids():
		if peer_id == multiplayer.get_unique_id():
			continue
		if not _client_manifests.has(peer_id):
			return
		var diff := _manifest_diff(_own_manifest, _client_manifests[peer_id])
		if not diff.is_empty():
			_go_live_blocked = true
			var reason := "初始单位清单与服务器不一致（%s）——请确认所有玩家使用同一份工程版本" % diff
			push_error("联机: " + reason)
			NetSession._rpc_abort.rpc(reason)
			return
	if _live:
		return
	_live = true
	# 复核 P1-5：go-live 对账——补齐窗口期漏掉的 spawn、清掉多余单位。
	_rpc_reconcile.rpc(_collect_reconcile_entries())
	for unit in get_tree().get_nodes_in_group("units"):
		_watch_unit(unit)


func _collect_unit_paths() -> PackedStringArray:
	var paths: PackedStringArray = PackedStringArray()
	for unit in get_tree().get_nodes_in_group("units"):
		if unit == null or not is_instance_valid(unit):
			continue
		paths.append(str(_match.get_path_to(unit)))
	paths.sort()
	return paths


func _manifest_diff(a: PackedStringArray, b: PackedStringArray) -> String:
	if a.size() != b.size():
		return "单位数 %d vs %d" % [a.size(), b.size()]
	for i in range(a.size()):
		if a[i] != b[i]:
			return "第 %d 个路径不同: %s vs %s" % [i, a[i], b[i]]
	return ""


func _collect_reconcile_entries() -> Array:
	var entries: Array = []
	for unit in get_tree().get_nodes_in_group("units"):
		if unit == null or not is_instance_valid(unit):
			continue
		var scene_path := String(unit.scene_file_path)
		if scene_path.is_empty():
			continue
		entries.append(
			{
				"path": str(_match.get_path_to(unit)),
				"parent": str(_match.get_path_to(unit.get_parent())),
				"scene": scene_path,
				"xf": unit.global_transform,
				"hp": unit.hp if "hp" in unit else 0.0,
				"stance": _authoritative_stance(unit),
				"fire_policy": _authoritative_fire_policy(unit),
			}
		)
	return entries


func _authoritative_stance(unit: Node, runtime: Node = null) -> String:
	if runtime == null:
		runtime = _match.get_node_or_null("CommandRuntime")
	if runtime != null and runtime.has_method("GetEngagementStance"):
		return str(runtime.GetEngagementStance(unit))
	return "Aggressive"


func _authoritative_fire_policy(unit: Node, runtime: Node = null) -> String:
	if runtime == null:
		runtime = _match.get_node_or_null("CommandRuntime")
	if runtime != null and runtime.has_method("GetFirePolicy"):
		return str(runtime.GetFirePolicy(unit))
	return "FireAtWill"


## 复核 P1-2：玩家掉线 → 服务器清掉其全部单位（歼灭规则随之自然结算，掉线算负）。
func _on_player_dropped(slot: int) -> void:
	if not NetSession.is_server():
		return
	var players := get_tree().get_nodes_in_group("players")
	if slot < 0 or slot >= players.size():
		return
	var dropped = players[slot]
	for unit in get_tree().get_nodes_in_group("units"):
		if is_instance_valid(unit) and unit.get_parent() == dropped:
			unit.queue_free()


func _watch_unit(unit: Node) -> void:
	if unit == null or not is_instance_valid(unit):
		return
	if unit.tree_exited.is_connected(_on_unit_tree_exited):
		return
	var path := str(_match.get_path_to(unit))
	unit.tree_exited.connect(_on_unit_tree_exited.bind(path))


func _on_unit_spawned(unit: Node) -> void:
	if not NetSession.is_server() or not _live:
		return
	_watch_unit(unit)
	var scene_path := String(unit.scene_file_path)
	if scene_path.is_empty():
		return
	_rpc_spawn.rpc(
		scene_path,
		str(_match.get_path_to(unit.get_parent())),
		unit.global_transform,
		unit.hp if "hp" in unit else 0.0,
		str(unit.name)
	)


func _on_unit_tree_exited(path: String) -> void:
	if not NetSession.is_server() or not _live:
		return
	_rpc_despawn.rpc(path)


func _physics_process(delta: float) -> void:
	if not NetSession.is_networked():
		return
	_hud_tick(delta)
	if NetSession.is_server():
		_server_tick()
	else:
		_client_interp_tick()


func _server_tick() -> void:
	if not _live:
		_try_go_live()
	if not _live:
		return
	_frame += 1
	if _frame % SNAPSHOT_INTERVAL_FRAMES != 0:
		return
	_broadcast_snapshot()


func _client_interp_tick() -> void:
	if _interp_target.is_empty() or _last_snap_msec <= 0:
		return
	var t := clampf(
		float(Time.get_ticks_msec() - _last_snap_msec) / float(_snap_interval_msec),
		0.0,
		1.0
	)
	for path in _interp_target.keys():
		var unit := _match.get_node_or_null(NodePath(path))
		if unit == null or not is_instance_valid(unit):
			continue
		var prev: Vector3 = _interp_prev.get(path, _interp_target[path])
		var target: Vector3 = _interp_target[path]
		unit.global_position = prev.lerp(target, t)
		if _interp_target_yaw.has(path):
			var prev_yaw: float = float(_interp_prev_yaw.get(path, _interp_target_yaw[path]))
			var target_yaw: float = float(_interp_target_yaw[path])
			unit.rotation.y = lerp_angle(prev_yaw, target_yaw, t)


func forward_command(
	op: String,
	unit_nodes: Array,
	destination: Vector3,
	target: Node,
	_issuer: Node,
	extra: String = ""
) -> Dictionary:
	var paths: PackedStringArray = PackedStringArray()
	for unit in unit_nodes:
		if unit != null and is_instance_valid(unit):
			paths.append(str(_match.get_path_to(unit)))
	var target_path := ""
	if target != null and is_instance_valid(target):
		target_path = str(_match.get_path_to(target))
	print("[CMD] 客户端提交 op=%s units=%s dest=%s" % [op, paths, destination])
	_rpc_command.rpc_id(1, op, paths, destination, target_path, extra)
	return {"status": "Accepted", "unit_results": []}


## 客户端 HUD 只读取最近一次服务器快照确认的策略。
func get_authoritative_engagement_stance(unit) -> String:
	if unit == null or not is_instance_valid(unit):
		return "Aggressive"
	return str(_authoritative_stance_by_path.get(str(_match.get_path_to(unit)), "Aggressive"))


func get_authoritative_fire_policy(unit) -> String:
	if unit == null or not is_instance_valid(unit):
		return "FireAtWill"
	return str(_authoritative_fire_policy_by_path.get(str(_match.get_path_to(unit)), "FireAtWill"))


func apply_client_snapshot(
	units_payload: Array, resources_payload: Array, server_frame: int
) -> void:
	if NetSession.is_server():
		return
	# 复核 P1-1：快照只更新插值目标，位置由 _client_interp_tick 每物理帧过渡。
	var now := Time.get_ticks_msec()
	if _last_snap_msec > 0:
		_snap_interval_msec = clampi(now - _last_snap_msec, 50, 300)
	_last_snap_msec = now
	var seen: Dictionary = {}
	for item in units_payload:
		var path: String = item["path"]
		seen[path] = true
		if item.has("stance"):
			_authoritative_stance_by_path[path] = str(item["stance"])
		if item.has("fire_policy"):
			_authoritative_fire_policy_by_path[path] = str(item["fire_policy"])
		var unit := _match.get_node_or_null(NodePath(path))
		if unit == null or not is_instance_valid(unit):
			continue
		_interp_prev[path] = _interp_target.get(path, item["pos"])
		_interp_target[path] = item["pos"]
		if item.has("yaw"):
			# 朝向与位置同走插值：直接赋值会让客户端朝向按快照频率(≈10Hz)阶跃跳变，
			# 视觉表现为单位原地高频抖动/瞬转（2026-09-02 移动故障视频定位）。
			_interp_prev_yaw[path] = _interp_target_yaw.get(path, float(item["yaw"]))
			_interp_target_yaw[path] = float(item["yaw"])
		if item.has("hp") and "hp" in unit:
			unit.hp = item["hp"]
		if item.has("action") and unit.has_method("apply_presentation_action"):
			unit.apply_presentation_action(str(item["action"]))
		# 施工进度：只改外观与进度镜像，**不动 hp**（客户端 hp 由上面的快照结算）。
		if item.has("construction") and unit.has_method("present_construction"):
			var report: Array = item["construction"]
			if report.size() >= 2:
				unit.present_construction(int(report[0]), int(report[1]))
		# 生产队列镜像：让客户端 HUD 与服务器一致（增/改/删都在这一个入口收敛）。
		if item.has("production") and "production_queue" in unit \
				and unit.production_queue != null \
				and unit.production_queue.has_method("apply_presentation_snapshot"):
			unit.production_queue.apply_presentation_snapshot(item["production"])
	for path in _interp_target.keys():
		if not seen.has(path):
			_interp_prev.erase(path)
			_interp_target.erase(path)
			_interp_prev_yaw.erase(path)
			_interp_target_yaw.erase(path)
	var players := get_tree().get_nodes_in_group("players")
	for item in resources_payload:
		var slot := int(item["slot"])
		if slot < 0 or slot >= players.size():
			continue
		var player = players[slot]
		if player != null and player.has_method("apply_authoritative_resource_snapshot"):
			player.apply_authoritative_resource_snapshot(
				int(item["a"]), int(item["b"]), server_frame
			)


func _broadcast_snapshot() -> void:
	var command_runtime = _match.get_node_or_null("CommandRuntime")
	var units_payload: Array = []
	for unit in get_tree().get_nodes_in_group("units"):
		if unit == null or not is_instance_valid(unit):
			continue
		var entry := {
			"path": str(_match.get_path_to(unit)),
			"pos": unit.global_position,
			"yaw": unit.rotation.y,
			"hp": unit.hp if "hp" in unit else 0,
			"stance": _authoritative_stance(unit, command_runtime),
			"fire_policy": _authoritative_fire_policy(unit, command_runtime),
		}
		# 当前动作路径：傀儡本地拿不到 `action`（Unit._set_action 主动丢弃），
		# 表现层与 UI 需要它来判断"在建造/采集/攻击"（例如建造预览要避开建造中的工人）。
		if "action" in unit and unit.action != null and unit.action.get_script() != null:
			entry["action"] = str(unit.action.get_script().resource_path)
		# 施工进度：建造中的建筑必须让客户端也"看得见在造"。
		# 为什么走**快照**而不是一次性事件：快照 10Hz、幂等、可自愈 ——
		# 丢包、事件早于生成、重连都不会让客户端卡在错误外观（2026-09-11）。
		if unit.has_method("construction_progress_report"):
			var report: Array = unit.construction_progress_report()
			if report.size() >= 2 and int(report[1]) > 0:
				entry["construction"] = report
		# 生产队列镜像：客户端 HUD（RA3 侧栏）据此显示排队与建造进度动画。
		# **空数组也必须下发**：客户端的 apply_presentation_snapshot 靠"本次收到的
		# 集合"收敛增/改/删 —— 字段缺失时它整段跳过，删除分支永不执行，于是服务器
		# 已经造完、客户端仍永久残留最后一个元素。
		# 2026-09-11 实测症状：服务器 barracks 队列已空（命令账本 4 条 produce 全
		# Accepted、场上已出 4 个步兵），客户端 legacy_mirror 仍挂着
		# `state=Producing completed_work=118/120` → RA3 侧栏步兵卡片卡住不消失。
		if "production_queue" in unit and unit.production_queue != null \
				and unit.production_queue.has_method("presentation_snapshot"):
			entry["production"] = unit.production_queue.presentation_snapshot()
		units_payload.append(entry)
	var resources_payload: Array = []
	var players := get_tree().get_nodes_in_group("players")
	for i in range(players.size()):
		var player = players[i]
		resources_payload.append(
			{"slot": i, "a": int(player.resource_a), "b": int(player.resource_b)}
		)
	if _frame % 100 == 0:
		print("[SNAP] 服务器镜像余额: ", resources_payload)
	# 复核 P2：快照携带服务器帧号，客户端用它做资源版本去重（原来传客户端本地 _frame 恒为 0）。
	_rpc_snapshot.rpc(units_payload, resources_payload, _frame)


## 把转发命令的终态登记到调试端点命令历史，供副官按 command_id 复核。
## （仅本地调用，不是 RPC；@rpc 注解属于下方的 _rpc_command。）
func _record_command_terminal(command_id: String, op: String, issuer: Node,
		subject: String, scene: String, status: String, reason: String,
		artifact_id := "") -> void:
	if command_id.is_empty():
		return
	var dbg = get_node_or_null("/root/DebugControlServer")
	if dbg == null or not dbg.has_method("record_command"):
		return
	dbg.record_command(command_id, op, str(issuer.name), subject, scene,
		status, reason, artifact_id)


@rpc("any_peer", "reliable")
func _rpc_command(
	op: String,
	paths: PackedStringArray,
	destination: Vector3,
	target_path: String,
	extra: String = ""
) -> void:
	if not NetSession.is_server():
		return
	var slot := NetSession.slot_of(multiplayer.get_remote_sender_id())
	var players := get_tree().get_nodes_in_group("players")
	if slot < 0 or slot >= players.size():
		print("[CMD][服务器] 拒绝: 槽位无效 slot=%d" % slot)
		return
	var issuer = players[slot]
	if issuer == null or issuer.get_script() != HumanScript:
		print("[CMD][服务器] 拒绝: issuer 非人类玩家 slot=%d" % slot)
		return
	var units: Array = []
	for path in paths:
		var unit = _match.get_node_or_null(NodePath(path))
		# 客户端和服务器的根节点路径可能不同（例如 /root/Online/Match
		# 与 /root/Match）。命令协议以全局 Unit 名称兜底解析，归属仍由
		# issuer 严格校验，避免跨玩家操控。
		if unit == null:
			var wanted_name := String(path).get_file()
			for candidate in get_tree().get_nodes_in_group("units"):
				if candidate.name == wanted_name and candidate.get_parent() == issuer:
					unit = candidate
					break
		if unit != null and is_instance_valid(unit) and unit.get_parent() == issuer:
			units.append(unit)
	if op == "produce":
		# extra 协议：scene_path[|command_id]；command_id 由客户端生成用于复核关联。
		var extra_parts: PackedStringArray = extra.split("|")
		var produce_scene := str(extra_parts[0])
		var produce_command_id := str(extra_parts[1]) if extra_parts.size() > 1 else ""
		if units.is_empty() or produce_scene.is_empty():
			print("[CMD][服务器] produce 拒绝: units=%d extra='%s' paths=%s" % [
				units.size(), extra, paths])
			return
		var queue = units[0].find_child("ProductionQueue")
		if queue == null:
			print("[CMD][服务器] produce 拒绝: %s 无 ProductionQueue" % units[0].name)
			return
		var produced = queue.produce(load(produce_scene))
		var receipt: Dictionary = queue.get_last_result() if queue.has_method("get_last_result") else {}
		print("[CMD][服务器] produce %s element=%s receipt=%s" % [
			produce_scene, str(produced != null), str(receipt)])
		var item_id := ""
		if receipt.get("item") is Dictionary:
			item_id = str(receipt["item"].get("item_id", ""))
		_record_command_terminal(produce_command_id, "produce", issuer, str(units[0].name),
			produce_scene, str(receipt.get("status", "")),
			str(receipt.get("reason", "")) if receipt.has("reason") else "", item_id)
		return
	if op == "place_structure":
		# 人类玩家放置建筑（复核 2026-08-31：此前傀儡端 Place 只在本地生成, 服务器毫不知情）。
		var placement_runtime = _match.get_node_or_null("StructurePlacementRuntime")
		if placement_runtime == null or units.is_empty() or extra.is_empty():
			print("[CMD][服务器] place_structure 拒绝: runtime/参数缺失")
			return
		# extra 协议：scene_path|yaw[|command_id]；command_id 由客户端生成用于复核关联。
		var parts: PackedStringArray = extra.split("|")
		var yaw: float = float(parts[1]) if parts.size() > 1 else 0.0
		var build_command_id := str(parts[2]) if parts.size() > 2 else ""
		var structure_transform := Transform3D(
			Basis.IDENTITY.rotated(Vector3.UP, yaw), destination
		)
		var place_result: Dictionary = placement_runtime.Place(
			issuer, load(parts[0]), structure_transform, {}
		)
		var place_ok := bool(place_result.get("accepted", false))
		print(
			"[CMD][服务器] place_structure accepted=",
			place_ok,
			" issue=",
			str(place_result.get("primary_issue", ""))
		)
		if place_ok:
			placement_runtime.AssignBuilders(
				units, place_result["structure"], issuer, place_result["displaced_unit_ids"]
			)
		var structure_node = place_result.get("structure")
		_record_command_terminal(build_command_id, "build", issuer,
			"|".join(units.map(func(u): return str(u.name))), str(parts[0]),
			"Accepted" if place_ok else "Rejected",
			str(place_result.get("primary_issue", "")),
			str(structure_node.name) if structure_node != null and is_instance_valid(structure_node) else "")
		return
	if units.is_empty():
		print("[CMD][服务器] 拒绝: 单位解析为空 op=%s paths=%s" % [op, paths])
		return
	var gateway = issuer.find_child("UnitCommandGateway")
	if gateway == null:
		print("[CMD][服务器] 拒绝: 人类玩家无 UnitCommandGateway")
		return
	var target = _match.get_node_or_null(NodePath(target_path)) if target_path != "" else null
	if target == null and target_path != "":
		var wanted_target_name := String(target_path).get_file()
		for candidate in get_tree().get_nodes_in_group("units"):
			if candidate.name == wanted_target_name:
				target = candidate
				break
		if target == null:
			for candidate in get_tree().get_nodes_in_group("resource_units"):
				if candidate.name == wanted_target_name:
					target = candidate
					break
	if target == null and op == "gather" and not units.is_empty():
		# 最后一道兼容兜底：不同端地图节点路径可能不同，按发起者
		# 单位最近的同类资源选择目标，避免客户端命令静默丢失。
		var origin: Vector3 = units[0].global_position
		var nearest := INF
		for candidate in get_tree().get_nodes_in_group("resource_units"):
			# 显式 float：distance_to 在此上下文返回 Variant，:= 无法推断类型，
			# 会让整个 NetSync.gd 解析失败（表现为联机黑屏且 NetSync 缺失）。
			var d: float = candidate.global_position.distance_to(origin)
			if d < nearest:
				nearest = d
				target = candidate
	print("[CMD][服务器] 应用 op=%s units=%d dest=%s" % [op, units.size(), destination])
	match op:
		"move":
			var move_result: Dictionary = gateway.MoveUnits(units, destination, issuer)
			var child_names: Array = units[0].get_children().map(
				func(c): return str(c.name)
			)
			print(
				"[CMD][服务器] MoveUnits 结果: ",
				move_result,
				" | unit=", units[0].name,
				" children=", child_names,
				" FindChild(Movement)=",
				units[0].find_child("Movement", false, false) != null
			)
		"force_move":
			gateway.ForceMoveUnits(units, destination, issuer)
		"halt":
			gateway.HaltMovement(units, issuer)
		"stop":
			gateway.StopUnits(units, issuer)
		"withdraw":
			gateway.TacticalWithdrawUnits(units, destination, issuer)
		"ground_attack_move":
			gateway.GroundAttackMoveUnits(units, destination, issuer)
		"attack":
			if target != null:
				gateway.AttackUnits(units, target, issuer)
		"force_attack":
			if target != null:
				gateway.ForceAttackUnits(units, target, issuer)
		"force_attack_ground":
			gateway.ForceAttackGround(units, destination, issuer)
		"entity_attack_move":
			if target != null:
				gateway.EntityAttackMoveUnits(units, target, issuer)
		"follow":
			if target != null:
				gateway.FollowEntityUnits(units, target, issuer)
		"approach":
			if target != null:
				gateway.ApproachEntityUnits(units, target, issuer)
		"gather":
			if target != null:
				var gather_result: Dictionary = gateway.GatherResources(units, target, issuer)
				print("[CMD][服务器] GatherResources 结果: ", gather_result)
		"construct":
			if target != null:
				gateway.ConstructUnits(units, target, issuer)
		"cancel_construct":
			if target != null:
				gateway.CancelConstruction(target, issuer)
		"set_engagement_stance":
			var stance_result: Dictionary = gateway.SetEngagementStance(units, extra, issuer)
			print("[CMD][服务器] SetEngagementStance 结果: ", stance_result)
		"set_fire_policy":
			var policy_result: Dictionary = gateway.SetFirePolicy(units, extra, issuer)
			print("[CMD][服务器] SetFirePolicy 结果: ", policy_result)


@rpc("authority", "unreliable")
func _rpc_snapshot(units_payload: Array, resources_payload: Array, server_frame: int) -> void:
	apply_client_snapshot(units_payload, resources_payload, server_frame)


@rpc("any_peer", "reliable")
func _rpc_submit_manifest(paths: PackedStringArray) -> void:
	if not NetSession.is_server():
		return
	var peer_id := multiplayer.get_remote_sender_id()
	if NetSession.slot_of(peer_id) < 0:
		return
	_client_manifests[peer_id] = paths


@rpc("authority", "reliable")
func _rpc_reconcile(entries: Array) -> void:
	if NetSession.is_server():
		return
	_interp_prev.clear()
	_interp_target.clear()
	var wanted: Dictionary = {}
	for entry in entries:
		var path: String = entry["path"]
		wanted[path] = true
		if _match.get_node_or_null(NodePath(path)) != null:
			continue
		_spawn_unit(entry["scene"], entry["parent"], entry["xf"], entry["hp"], path)
	for unit in get_tree().get_nodes_in_group("units"):
		if unit == null or not is_instance_valid(unit):
			continue
		if not wanted.has(str(_match.get_path_to(unit))):
			unit.queue_free()


@rpc("authority", "reliable")
func _rpc_spawn(scene_path: String, parent_path: String, xf: Transform3D, hp: float,
		unit_name := "") -> void:
	if NetSession.is_server():
		return
	_spawn_unit(scene_path, parent_path, xf, hp, "", unit_name)


func _spawn_unit(
	scene_path: String, parent_path: String, xf: Transform3D, hp: float,
	forced_path: String = "", unit_name: String = ""
) -> void:
	var parent := _match.get_node_or_null(NodePath(parent_path))
	if parent == null or scene_path.is_empty():
		return
	var packed = load(scene_path)
	if packed == null:
		return
	var unit = packed.instantiate()
	# 命名必须与服务器一致：客户端上送的命令路径用本机节点名，服务器按同一路径解析；
	# 若客户端沿用场景默认名（Barracks）而服务器叫 Unit_N，服务器会解析不到单位并拒绝
	# （2026-09-10「联机局没法造兵」的根因：produce 拒绝 units=0）。
	var authoritative_name := ""
	if forced_path != "":
		var np := NodePath(forced_path)
		authoritative_name = String(np.get_name(np.get_name_count() - 1))
	elif unit_name != "":
		authoritative_name = unit_name
	if authoritative_name != "":
		unit.name = authoritative_name
	parent.add_child(unit)
	if forced_path != "":
		if str(_match.get_path_to(unit)) != forced_path:
			push_warning(
				"联机: 对账生成路径不符 %s（实际 %s），已移除" % [forced_path, _match.get_path_to(unit)]
			)
			unit.queue_free()
			return
	unit.global_transform = xf
	# 物理插值开启后，进树后的瞬移需显式 reset，避免从原点滑到出生位的拖影。
	unit.reset_physics_interpolation()
	if "hp" in unit:
		unit.hp = hp
	if _match.has_method("_setup_unit_groups"):
		_match._setup_unit_groups(unit, parent)
	MatchSignals.unit_spawned.emit(unit)


@rpc("authority", "reliable")
func _rpc_despawn(path: String) -> void:
	if NetSession.is_server():
		return
	var unit := _match.get_node_or_null(NodePath(path))
	if unit != null and is_instance_valid(unit):
		unit.queue_free()


## 对局结束: 服务器广播结果并回收, 客户端回主菜单(2026-08-31 黑屏修复)。
func _on_match_finished(result: String) -> void:
	# 单人练习房：不以胜负结束，且不回收专用服（设计师需求 2026-09-04）。
	# 否则单人局开局即被判胜利 → 广播 → 5 秒后专用服退出。
	if NetSession.is_solo_practice():
		print("[对局] 单人练习房：跳过结算广播（", result, "），对局继续")
		return
	if not NetSession.is_networked():
		return
	if NetSession.is_server():
		_rpc_match_over.rpc(result)
		print("[对局] 已广播结果: ", result, ", 5 秒后回收专用服")
		await get_tree().create_timer(5.0).timeout
		get_tree().quit(0)
	else:
		_rpc_match_over(result)


@rpc("authority", "reliable")
func _rpc_match_over(result: String) -> void:
	NetSession._match_started = false
	get_tree().paused = false
	NetSession._set_status("对局结束: " + result + "，即将返回主菜单")
	print("[对局] 客户端收到结算: ", result, "，3 秒后返回主菜单")
	await get_tree().create_timer(3.0).timeout
	get_tree().change_scene_to_file.call_deferred("res://source/main-menu/Main.tscn")


## 命令可视化广播（纯表现层，2026-09-10）：权威端把一次命令（含副官指令）广播给表现层，
## 客户端据此在目标点画信标、从受令单位画路径。不改快照结构、不改任何玩法状态；
## unreliable 语义不需要——丢一条只少一次视觉指示，故用 reliable 保证指示完整。
func broadcast_order_visual(payload: Dictionary) -> void:
	# 【2026-09-11 修正：发起方本机也必须看到指示】
	# 原实现在"联机 且 非权威端"（正是**玩家客户端**）时直接什么都不做，
	# 于是"从客户端 DCS 发出的副官命令"在屏幕上**完全没有指示** ——
	# 用户实测："AI 副官在指挥部队，但看不到任何指挥动画"。
	# 命令可视化是纯表现层，谁发起谁就该看到，不能依赖"只有房主才广播"。
	MatchSignals.order_visualized.emit(payload)
	if not NetSession.is_networked():
		return
	if NetSession.is_server():
		_rpc_order_visual.rpc(payload)


@rpc("authority", "reliable")
func _rpc_order_visual(payload: Dictionary) -> void:
	if NetSession.is_server():
		return
	MatchSignals.order_visualized.emit(payload)


## ---------------------------------------------------------------------------
## 表现事件广播（纯表现层，2026-09-11）
##
## 为什么必须补这条通道（用户报"看不到建造动画 / 看不到交火特效与音效 / UI 没进度"）：
## 联机客户端是**傀儡**——`Unit._set_action` 主动丢弃 action（Unit.gd:529-532），
## 快照也只带 pos/yaw/hp/stance/fire_policy，于是下列**纯表现**在客户端全部缺失：
##   - `attack_fired` 只在权威端由 ProjectileRuntime 发（真实创建投射物时）→ 客户端无开火动画/音效；
##   - 采集火花由本地 Action 驱动（CollectingResourcesWhileInRange）→ 客户端无 Action 即无火花。
## 这里沿用 `broadcast_order_visual` 的成熟模式：**只广播表现事件**，
## 不复制第二份权威状态、不改快照结构、不参与任何玩法结算。
##
## 只发给客户端：房主/单机本地已有 Action 驱动表现，再补一次会变成"双份音效/动画"。
## ---------------------------------------------------------------------------
func broadcast_presentation(kind: String, path: String, payload: Dictionary = {}) -> void:
	if not NetSession.is_networked() or not NetSession.is_server():
		return
	var event := payload.duplicate()
	event["kind"] = kind
	event["path"] = path
	_rpc_presentation.rpc(event)


@rpc("authority", "reliable")
func _rpc_presentation(event: Dictionary) -> void:
	if NetSession.is_server():
		return
	var unit := _match.get_node_or_null(NodePath(str(event.get("path", ""))))
	if unit == null or not is_instance_valid(unit):
		# 事件早于生成（可靠 RPC 与生成顺序不保证）：丢弃即可 ——
		# 施工/生产进度走的是幂等快照，会自动补上；开火/采集是一次性表现，少一帧不致命。
		return
	match str(event.get("kind", "")):
		"fired":
			if unit.has_method("present_fired"):
				# 整个 event 传进去：其中可能带权威端算好的 `aim`（真实弹道落点）。
				unit.present_fired(event)
		"gather":
			if unit.has_method("present_gather"):
				unit.present_gather(bool(event.get("active", false)))
		_:
			pass
