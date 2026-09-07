extends Node

## 键盘快捷键改版冒烟测试（2026-09-07）：
## 方向键=移动视角；Q=全选己方单位；W=选相同类型单位；A+左键=攻击移动；S=停止。

const MatchScene = preload("res://tests/manual/TestAllUnits.tscn")
const WorkerScene = preload("res://source/match/units/Worker.tscn")
const Structure = preload("res://source/match/units/Structure.gd")

var _failures := 0
var _finished := false
var _feedback: Array[Dictionary] = []


func _ready():
	get_tree().create_timer(60.0).timeout.connect(_on_failsafe)
	var match_instance = MatchScene.instantiate()
	add_child(match_instance)
	await get_tree().process_frame
	await get_tree().create_timer(0.5).timeout

	var human = match_instance.get_node("Players/Human")
	var actions_controller = human.get_node("UnitActionsController")
	var input_runtime = match_instance.get_node("InputBindingRuntime")
	var camera = get_viewport().get_camera_3d()
	actions_controller.command_feedback.connect(
		func(command_name, accepted, _rejected, _status):
			_feedback.append({"command": command_name, "accepted": accepted})
	)

	# --- 1) 方向键移动视角 ---
	var camera_position_before: Vector3 = camera.global_position
	_press_key(input_runtime, KEY_UP, true)
	await get_tree().create_timer(0.4).timeout
	_press_key(input_runtime, KEY_UP, false)
	var moved: Vector3 = camera.global_position - camera_position_before
	_check(moved.length() > 0.01, "按住方向键上应移动视角（位移 %.3f）" % moved.length())

	# --- 2) Q 全选作战单位（不含建筑） ---
	var extra_workers := []
	for index in range(2):
		var worker = WorkerScene.instantiate()
		MatchSignals.setup_and_spawn_unit.emit(
			worker,
			Transform3D(Basis.IDENTITY, Vector3(6.0 + index, 0.0, 12.0)),
			human,
			false
		)
		extra_workers.append(worker)
	await get_tree().process_frame
	MatchSignals.deselect_all_units.emit()
	await get_tree().process_frame
	input_runtime.emit_signal("ActionPressed", "selection.select_all")
	await get_tree().process_frame
	var selected_all = get_tree().get_nodes_in_group("selected_units")
	var structures_selected = selected_all.filter(
		func(unit): return unit is Structure
	)
	_check(
		selected_all.size() >= 6 and structures_selected.is_empty(),
		"Q 应全选作战单位且不含建筑（实际 %d 个，其中建筑 %d 个）" % [
			selected_all.size(), structures_selected.size()
		]
	)

	# --- 3) W 选相同类型单位 ---
	MatchSignals.deselect_all_units.emit()
	await get_tree().process_frame
	extra_workers[0].get_node("Selection").select()
	await get_tree().process_frame
	input_runtime.emit_signal("ActionPressed", "selection.select_same_type")
	await get_tree().process_frame
	var selected_same = get_tree().get_nodes_in_group("selected_units").filter(
		func(unit): return unit.scene_file_path == WorkerScene.resource_path
	)
	var non_worker_selected = get_tree().get_nodes_in_group("selected_units").filter(
		func(unit): return unit.scene_file_path != WorkerScene.resource_path
	)
	_check(
		selected_same.size() == 3 and non_worker_selected.is_empty(),
		"W 应只选中全部工人（工人 %d 个，其他 %d 个）" % [
			selected_same.size(), non_worker_selected.size()
		]
	)

	# --- 4) S 停止 ---
	_feedback.clear()
	input_runtime.emit_signal("ActionPressed", "unit.stop")
	await get_tree().process_frame
	var stop_feedback = _feedback.filter(func(entry): return entry["command"] == "Stop")
	_check(
		not stop_feedback.is_empty() and stop_feedback[0]["accepted"] > 0,
		"S 应触发完整停止并至少接受一个单位"
	)

	# --- 5) A 按住 + 右键点地面 = 攻击移动（兼容按住 A 的操作习惯） ---
	_feedback.clear()
	_press_key(input_runtime, KEY_A, true)  # 按住 A（不释放）
	MatchSignals.deselect_all_units.emit()
	await get_tree().process_frame
	human.get_node("Tank").get_node("Selection").select()
	await get_tree().process_frame
	_feedback.clear()
	MatchSignals.terrain_targeted.emit(Vector3(14.0, 0.0, 14.0))
	await get_tree().process_frame
	var held_feedback = _feedback.filter(
		func(entry): return entry["command"] == "GroundAttackMove"
	)
	_check(
		not held_feedback.is_empty() and held_feedback[0]["accepted"] > 0,
		"按住 A + 右键点地面应下达攻击移动命令"
	)
	_press_key(input_runtime, KEY_A, false)

	# --- 6) A+左键 = 攻击移动 ---
	MatchSignals.deselect_all_units.emit()
	await get_tree().process_frame
	human.get_node("Tank").get_node("Selection").select()
	await get_tree().process_frame
	input_runtime.emit_signal("ActionPressed", "unit.attack_move")
	_check(
		actions_controller.is_ground_attack_move_targeting(),
		"A 键应进入攻击移动目标确认状态"
	)
	_check(
		not get_tree().get_nodes_in_group("attack_move_targeting").is_empty(),
		"瞄准状态下应存在 attack_move_targeting 组标记（抑制左键误选）"
	)
	_feedback.clear()
	var click_event = InputEventMouseButton.new()
	click_event.button_index = MOUSE_BUTTON_LEFT
	click_event.pressed = true
	click_event.position = get_viewport().get_visible_rect().size * 0.5
	actions_controller._unhandled_input(click_event)
	await get_tree().process_frame
	var attack_move_feedback = _feedback.filter(
		func(entry): return entry["command"] == "GroundAttackMove"
	)
	_check(
		not actions_controller.is_ground_attack_move_targeting() and not attack_move_feedback.is_empty()
			and attack_move_feedback[0]["accepted"] > 0,
		"A+左键应向点击处下达攻击移动命令"
	)

	_finish()


## 伪造一次方向键按压/释放，走 InputBindingRuntime 的真实解析链路。
func _press_key(input_runtime, keycode: Key, pressed: bool) -> void:
	var event = InputEventKey.new()
	event.keycode = keycode
	event.physical_keycode = keycode
	event.pressed = pressed
	input_runtime._Input(event)


func _on_failsafe():
	if _finished:
		return
	print("FAIL: 看门狗超时——测试协程中断未收尾")
	_finish()


func _finish():
	if _finished:
		return
	_finished = true
	print("Keyboard shortcuts smoke test completed: %d failure(s)" % _failures)
	SmokeTestExit.request(get_tree(), 0 if _failures == 0 else 1)


func _check(condition: bool, message: String):
	if condition:
		return
	_failures += 1
	print("FAIL: %s" % message)
	push_error("Keyboard shortcuts assertion failed: %s" % message)
