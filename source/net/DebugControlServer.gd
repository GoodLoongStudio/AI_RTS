extends Node

## 调试控制端点：游戏内嵌 TCP 服务器，接受 JSON 指令操控对局。
## 两类指令：
##   1) 输入模拟：click/drag/key —— 合成真实 InputEvent 走引擎输入管线，
##      与玩家鼠标完全同路径(HUD/框选/相机拾取全部真实反应)。
##   2) 结构化命令：move/gather/build/produce/attack/status/screenshot。
## autoload 自挂载：带 --debugport 参数的进程（客户端/专用服均可）启用，
## 未带参数的进程（正常玩家/编辑器）在 _ready 自毁不监听；跨场景存活。

const DEFAULT_PORT := 24568

var _server := TCPServer.new()
var _clients: Array = []
var _buffers := {}
var _port := DEFAULT_PORT

## 命令终态登记上限，防止无限增长（见 _record_command）。
const COMMAND_LOG_LIMIT := 64
## 最近命令终态记录：produce/build 两条转发路径与服务器直执行路径共用，
## 供副官按 command_id 在下一轮复核最终 Accepted/Rejected（PendingAuthority 不落账）。
var _command_log: Array = []


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	var port_index := args.find("--debugport")
	if port_index < 0:
		# autoload 模式下未请求调试的进程直接退出，不占资源。
		queue_free()
		return
	if port_index + 1 < args.size():
		_port = int(args[port_index + 1])
	if _server.listen(_port, "127.0.0.1") != OK:
		print("[DBGCTL] 端口 %d 被占用, 调试控制端点未启动" % _port)
		set_process(false)
		return
	print("[DBGCTL] 调试控制端点已启动 127.0.0.1:%d" % _port)


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
	var tree := get_tree()
	var match_node = tree.current_scene
	if parsed.get("op", "") not in ["status", "start"] and (
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
	return JSON.stringify(_unified_receipt(result, {
		"resource": target.name,
	}))


func _op_build(match_node, parsed) -> String:
	var player = _resolve_player(match_node, parsed)
	var sync = match_node.get_node_or_null("NetSync")
	if sync == null:
		return JSON.stringify({
			"ok": false,
			"status": "NoNetSync",
			"reason": "对局网络层未初始化，无法提交建造。",
			"error": "no netsync",
		})
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
	# The debug endpoint runs inside the authority process for local listen-server
	# tests. Calling forward_command there sends an RPC to peer 1 but does not
	# reliably execute the command locally, so apply placement directly on server.
	if NetSession.is_server():
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


## op=commands 查询：带 command_id 精确复核单条，否则返回全部历史（新→旧）。
func _query_commands(parsed) -> Array:
	var wanted := str(parsed.get("command_id", ""))
	if wanted.is_empty():
		return _command_log.duplicate(true)
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
	return result
