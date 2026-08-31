extends Node

## 调试控制端点：游戏内嵌 TCP 服务器，接受 JSON 指令操控对局。
## 两类指令：
##   1) 输入模拟：click/drag/key —— 合成真实 InputEvent 走引擎输入管线，
##      与玩家鼠标完全同路径(HUD/框选/相机拾取全部真实反应)。
##   2) 结构化命令：move/gather/build/produce/attack/status/screenshot。
## 挂 root 跨场景存活，仅在 autojoin 调试模式下由 Online.gd 挂载。

const PORT := 24568

var _server := TCPServer.new()
var _clients: Array = []
var _buffers := {}


func _ready() -> void:
	if _server.listen(PORT, "127.0.0.1") != OK:
		print("[DBGCTL] 端口 %d 被占用, 调试控制端点未启动" % PORT)
		set_process(false)
		return
	print("[DBGCTL] 调试控制端点已启动 127.0.0.1:%d" % PORT)


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
	if parsed.get("op", "") != "status" and (
		match_node == null or not match_node.has_method("get_local_player")
	):
		return JSON.stringify({"error": "no match scene"})
	match str(parsed.get("op", "")):
		"status":
			return JSON.stringify(_collect_status(match_node))
		"click":
			return _op_click(parsed)
		"drag":
			return _op_drag(parsed)
		"key":
			return _op_key(parsed)
		"screenshot":
			return _op_screenshot(parsed)
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


# ---------- 结构化命令 ----------

func _resolve_own_units(match_node, wanted: Array) -> Array:
	var player = match_node.get_local_player()
	var nodes: Array = []
	for unit in get_tree().get_nodes_in_group("units"):
		if unit == null or not is_instance_valid(unit):
			continue
		if unit.get_parent() == player and unit.name in wanted:
			nodes.append(unit)
	return nodes


func _op_move(match_node, parsed) -> String:
	var player = match_node.get_local_player()
	var gateway = NetSession.command_gateway_for(player)
	if gateway == null:
		return JSON.stringify({"error": "no gateway"})
	var nodes := _resolve_own_units(match_node, parsed.get("units", []))
	var dest_raw: Array = parsed.get("dest", [0.0, 0.0])
	var destination := Vector3(float(dest_raw[0]), 0.0, float(dest_raw[1]))
	var result: Dictionary = gateway.MoveUnits(nodes, destination, player)
	return JSON.stringify({"result": result, "moved": nodes.map(
		func(n): return n.name
	)})


func _op_gather(match_node, parsed) -> String:
	var player = match_node.get_local_player()
	var gateway = NetSession.command_gateway_for(player)
	if gateway == null:
		return JSON.stringify({"error": "no gateway"})
	var nodes := _resolve_own_units(match_node, parsed.get("units", []))
	if nodes.is_empty():
		return JSON.stringify({"error": "no units"})
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
		return JSON.stringify({"error": "no resource of kind " + kind})
	var result: Dictionary = gateway.GatherResources(nodes, target, player)
	return JSON.stringify({"result": result, "resource": target.name})


func _op_build(match_node, parsed) -> String:
	var player = match_node.get_local_player()
	var sync = match_node.get_node_or_null("NetSync")
	if sync == null:
		return JSON.stringify({"error": "no netsync"})
	var builders := _resolve_own_units(match_node, parsed.get("units", []))
	if builders.is_empty():
		return JSON.stringify({"error": "no builders"})
	var pos_raw: Array = parsed.get("pos", [0.0, 0.0])
	var position := Vector3(float(pos_raw[0]), 0.0, float(pos_raw[1]))
	var scene_path := str(parsed.get("scene", "res://source/match/units/VehicleFactory.tscn"))
	sync.forward_command(
		"place_structure", builders, position, null, player, scene_path + "|0"
	)
	return JSON.stringify({"ok": true, "builders": builders.map(
		func(n): return n.name
	)})


func _op_produce(match_node, parsed) -> String:
	var player = match_node.get_local_player()
	var nodes := _resolve_own_units(match_node, [str(parsed.get("unit", ""))])
	if nodes.is_empty():
		return JSON.stringify({"error": "building not found"})
	var queue = nodes[0].find_child("ProductionQueue", false, false)
	if queue == null:
		return JSON.stringify({"error": "no production queue"})
	queue.produce(load(str(parsed.get("scene", ""))))
	return JSON.stringify({"ok": true})


func _op_attack(match_node, parsed) -> String:
	var player = match_node.get_local_player()
	var gateway = NetSession.command_gateway_for(player)
	if gateway == null:
		return JSON.stringify({"error": "no gateway"})
	var attackers := _resolve_own_units(match_node, parsed.get("units", []))
	var target_name := str(parsed.get("target", ""))
	var target = null
	for unit in get_tree().get_nodes_in_group("units"):
		if unit == null or not is_instance_valid(unit):
			continue
		if unit.name == target_name and unit.get_parent() != player:
			target = unit
			break
	if target == null:
		return JSON.stringify({"error": "target not found"})
	var result: Dictionary = gateway.AttackUnits(attackers, target, player)
	return JSON.stringify({"result": result})


func _collect_status(match_node) -> Dictionary:
	var tree := get_tree()
	var out := {"match": false, "units": [], "resources": [], "balance": null}
	if match_node == null or not match_node.has_method("get_local_player"):
		return out
	var player = match_node.get_local_player()
	if player == null:
		return out
	out["match"] = true
	out["balance"] = {"a": int(player.resource_a), "b": int(player.resource_b)}
	var camera := tree.current_scene.get_viewport().get_camera_3d()
	for unit in tree.get_nodes_in_group("units"):
		if unit == null or not is_instance_valid(unit):
			continue
		if unit == null or not is_instance_valid(unit):
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
			"mine": unit.get_parent() == player,
			"movement": unit.find_child("Movement", false, false) != null,
			"queue": unit.find_child("ProductionQueue", false, false) != null,
			"attack": "attack_range" in unit,
			"carried": carried,
		}
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
	return out
