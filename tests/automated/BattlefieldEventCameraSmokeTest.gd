extends Node

const MatchScene = preload("res://tests/manual/TestOneUnit.tscn")

var _failures := 0


func _ready():
	var match_instance = MatchScene.instantiate()
	add_child(match_instance)
	await get_tree().process_frame
	await get_tree().process_frame

	var camera = match_instance.get_node("IsometricCamera3D")
	var events = match_instance.get_node("BattlefieldEventRuntime")
	var input_runtime = match_instance.get_node("InputBindingRuntime")
	var start_position: Vector3 = camera.global_position
	_check(events.GetEventCount() == 0, "开局不应存在可跳转战场事件")
	_check(not camera.focus_latest_battlefield_event(), "没有事件时 Space 不得移动镜头")
	_check(camera.global_position.is_equal_approx(start_position), "空日志跳转后镜头应保持原位")

	var event_position := Vector3(12.0, 0.0, -8.0)
	events.RecordImportant("OwnUnitUnderAttack", event_position)
	_check(events.GetEventCount() == 1, "受击事件应写入日志")
	input_runtime.emit_signal("ActionPressed", "camera.focus_latest_event")
	var camera_after_first: Vector3 = camera.global_position
	_check(not camera_after_first.is_equal_approx(start_position), "Space 应将镜头跳离原位置")

	var later_position := Vector3(-6.0, 0.0, 10.0)
	events.RecordImportant("VisibleHostileLost", later_position)
	input_runtime.emit_signal("ActionPressed", "camera.focus_latest_event")
	_check(not camera.global_position.is_equal_approx(camera_after_first), "Space 应跳到更新的事件位置")

	var tank: Node3D = match_instance.get_node("Players/Human/Tank")
	var death_position: Vector3 = tank.global_position
	_check(death_position.length() > 1.0, "测试坦克应远离世界原点")
	tank.hp = 0
	await get_tree().process_frame
	var death_focus: Dictionary = events.TryGetLatestImportantFocus()
	_check(not death_focus.is_empty(), "己方单位阵亡应写入可跳转事件")
	_check(str(death_focus.get("kind", "")) == "OwnUnitLost", "阵亡应覆盖为最新跳转事件")
	var recorded: Vector3 = death_focus["position"]
	_check(recorded.distance_to(death_position) < 1.0, "阵亡事件必须使用离树前的世界坐标")
	_check(not recorded.is_equal_approx(Vector3.ZERO), "阵亡坐标不得退化成原点")
	input_runtime.emit_signal("ActionPressed", "camera.focus_latest_event")
	_check(not camera.global_position.is_equal_approx(Vector3.ZERO), "Space 不得因阵亡跳回原点")

	print("Battlefield event camera smoke test completed: %d failure(s)" % _failures)
	match_instance.queue_free()
	await get_tree().process_frame
	SmokeTestExit.request(get_tree(), 0 if _failures == 0 else 1)


func _check(condition: bool, message: String):
	if condition:
		return
	_failures += 1
	push_error("Battlefield event camera assertion failed: %s" % message)
