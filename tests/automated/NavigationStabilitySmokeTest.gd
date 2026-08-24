extends Node

const MatchScene = preload("res://tests/manual/TestHelicopterCommands.tscn")
const Moving = preload("res://source/match/units/actions/Moving.gd")

var _failures := 0


func _ready():
	var match_instance = MatchScene.instantiate()
	add_child(match_instance)
	await get_tree().process_frame
	await get_tree().process_frame

	var human = match_instance.get_node("Players/Human")
	var tank = human.get_node("Tank")
	var enemy_building = match_instance.get_node("Players/PolicyTestEnemy/TargetCommandCenter")
	var gateway = human.get_node("UnitCommandGateway")
	gateway.SetFirePolicy([tank], "HoldFire", human)
	await get_tree().physics_frame
	await get_tree().physics_frame

	var open_destination: Vector3 = tank.global_position + Vector3(2.0, 0.0, 0.0)
	var open_result = gateway.MoveUnits([tank], open_destination, human)
	var open_order_id: String = open_result["unit_results"][0]["order_id"]
	var open_state := await _wait_for_terminal_state(gateway, open_order_id, 240)
	_check(open_state == "Arrived", "空地短距离移动应稳定到达")
	_check(tank.action == null or tank.action.get_script() != Moving, "到达后不应继续移动 Action")

	var blocked_result = gateway.ForceMoveUnits([tank], enemy_building.global_position, human)
	var blocked_order_id: String = blocked_result["unit_results"][0]["order_id"]
	var samples: Array[Vector3] = []
	var blocked_state := await _wait_for_terminal_state(
		gateway, blocked_order_id, 600, tank, samples
	)
	_check(
		blocked_state in ["Unreachable", "Arrived"],
		"冲向建筑占地后订单必须结束，不得长期 InProgress"
	)
	_check(_max_planar_span(samples) < 2.5, "贴边后不应继续大幅度左右踱步")

	print("Navigation stability smoke test completed: %d failure(s)" % _failures)
	match_instance.queue_free()
	await get_tree().process_frame
	SmokeTestExit.request(get_tree(), 0 if _failures == 0 else 1)


func _wait_for_terminal_state(
	gateway: Node,
	order_id: String,
	max_frames: int,
	unit: Node3D = null,
	samples: Array[Vector3] = []
) -> String:
	var state := ""
	for _frame in range(max_frames):
		await get_tree().physics_frame
		if unit != null:
			samples.append(unit.global_position)
			if samples.size() > 30:
				samples.pop_front()
		state = gateway.GetOrderState(order_id)
		if state in ["Arrived", "Unreachable", "Cancelled", "UnitLost"]:
			return state
	return state


func _max_planar_span(samples: Array[Vector3]) -> float:
	if samples.size() < 2:
		return 0.0
	var min_point := Vector2(samples[0].x, samples[0].z)
	var max_point := min_point
	for sample in samples:
		min_point.x = minf(min_point.x, sample.x)
		min_point.y = minf(min_point.y, sample.z)
		max_point.x = maxf(max_point.x, sample.x)
		max_point.y = maxf(max_point.y, sample.z)
	return min_point.distance_to(max_point)


func _check(condition: bool, message: String):
	if condition:
		return
	_failures += 1
	push_error("Navigation stability assertion failed: %s" % message)
