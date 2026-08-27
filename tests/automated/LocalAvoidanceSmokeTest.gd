extends Node

const MatchScene = preload("res://tests/manual/TestMultiUnitCommands.tscn")

var _failures := 0


func _ready():
	var match_instance = MatchScene.instantiate()
	add_child(match_instance)
	await get_tree().process_frame
	await get_tree().process_frame
	await get_tree().physics_frame
	await get_tree().physics_frame

	var human = match_instance.get_node("Players/Human")
	var tank_a: Node3D = human.get_node("Tank")
	var tank_b: Node3D = human.get_node("SecondTank")
	var gateway = human.get_node("UnitCommandGateway")
	gateway.SetFirePolicy([tank_a, tank_b], "HoldFire", human)

	var movement_a = tank_a.find_child("Movement")
	var movement_b = tank_b.find_child("Movement")
	_check(movement_a.avoidance_enabled, "移动中应启用基础避让")
	_check(movement_a.max_neighbors >= 8, "拥挤避让必须考虑多个邻居")
	_check(movement_b.max_neighbors >= 8, "第二辆 Tank 也应使用拥挤避让参数")

	var start_a: Vector3 = tank_a.global_position
	var start_b: Vector3 = tank_b.global_position
	gateway.MoveUnits([tank_a], start_b, human)
	gateway.MoveUnits([tank_b], start_a, human)

	var overlap_streak := 0
	var max_overlap_streak := 0
	var finished_a := false
	var finished_b := false
	for _frame in range(480):
		await get_tree().physics_frame
		var separation := _planar_distance(tank_a.global_position, tank_b.global_position)
		if separation < 0.6:
			overlap_streak += 1
			max_overlap_streak = maxi(max_overlap_streak, overlap_streak)
		else:
			overlap_streak = 0
		finished_a = _is_order_finished(gateway, tank_a)
		finished_b = _is_order_finished(gateway, tank_b)
		if finished_a and finished_b:
			break

	_check(finished_a and finished_b, "对向交错应能结束，不得互相永久卡住")
	_check(max_overlap_streak < 90, "窄路交错时不得长时间完全重叠")
	_check(
		_planar_distance(tank_a.global_position, tank_b.global_position) >= 1.2,
		"交错结束后两辆 Tank 应保持可通行间距"
	)

	var gather_point: Vector3 = (tank_a.global_position + tank_b.global_position) * 0.5 + Vector3(0, 0, 6)
	gateway.MoveUnits([tank_a, tank_b], gather_point, human)
	for _frame in range(360):
		await get_tree().physics_frame
		if _is_order_finished(gateway, tank_a) and _is_order_finished(gateway, tank_b):
			break
	_check(
		_planar_distance(tank_a.global_position, tank_b.global_position) >= 1.2,
		"多单位前往同一区域后不得叠在同一点"
	)

	print("Local avoidance smoke test completed: %d failure(s)" % _failures)
	match_instance.queue_free()
	await get_tree().process_frame
	SmokeTestExit.request(get_tree(), 0 if _failures == 0 else 1)


func _is_order_finished(gateway: Node, unit: Node) -> bool:
	var state: String = gateway.GetActiveOrderState(unit)
	return state == "" or state in ["Arrived", "Unreachable", "Cancelled", "Suspended"]


func _planar_distance(first: Vector3, second: Vector3) -> float:
	return Vector2(first.x, first.z).distance_to(Vector2(second.x, second.z))


func _check(condition: bool, message: String):
	if condition:
		return
	_failures += 1
	push_error("Local avoidance assertion failed: %s" % message)
