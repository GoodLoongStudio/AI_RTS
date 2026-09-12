extends Node

const SmokeTestWarmup = preload("res://tests/automated/SmokeTestWarmup.gd")

const MatchScene = preload("res://tests/manual/TestMultiUnitCommands.tscn")

var _failures := 0


func _ready():
	var match_instance = MatchScene.instantiate()
	add_child(match_instance)
	await SmokeTestWarmup.wait_for_units(get_tree(), 4)

	var human = match_instance.get_node("Players/Human")
	var enemy = match_instance.get_node("Players/Enemy")
	var tank_a: Node3D = human.get_node("Tank")
	var tank_b: Node3D = human.get_node("SecondTank")
	var enemy_tank: Node3D = enemy.get_node("EnemyTank")
	var gateway = human.get_node("UnitCommandGateway")
	# 本测试只关心局部避让与交错，交战会打死后直接干扰位置断言，双方统一停火。
	gateway.SetFirePolicy([tank_a, tank_b], "HoldFire", human)
	gateway.SetFirePolicy([enemy_tank], "HoldFire", enemy)

	var movement_a = tank_a.find_child("Movement")
	var movement_b = tank_b.find_child("Movement")
	_check(movement_a.avoidance_enabled, "移动中应启用基础避让")
	_check(movement_a.max_neighbors >= 8, "拥挤避让必须考虑多个邻居")
	_check(movement_b.max_neighbors >= 8, "第二辆 Tank 也应使用拥挤避让参数")

	var start_a: Vector3 = tank_a.global_position
	var start_b: Vector3 = tank_b.global_position
	var order_a := _order_id_of(gateway.MoveUnits([tank_a], start_b, human))
	var order_b := _order_id_of(gateway.MoveUnits([tank_b], start_a, human))

	var overlap_streak := 0
	var max_overlap_streak := 0
	var state_a := ""
	var state_b := ""
	for _frame in range(480):
		await get_tree().physics_frame
		if not (_alive(tank_a) and _alive(tank_b)):
			break
		var separation := _planar_distance(tank_a.global_position, tank_b.global_position)
		if separation < 0.6:
			overlap_streak += 1
			max_overlap_streak = maxi(max_overlap_streak, overlap_streak)
		else:
			overlap_streak = 0
		state_a = gateway.GetOrderState(order_a)
		state_b = gateway.GetOrderState(order_b)
		if _is_terminal(state_a) and _is_terminal(state_b):
			break

	_check(_alive(tank_a) and _alive(tank_b), "两辆 Tank 在测试期间不得被摧毁")
	_check(
		_is_terminal(state_a) and _is_terminal(state_b),
		"对向交错应能结束，不得互相永久卡住（states=%s/%s）" % [state_a, state_b]
	)
	_check(state_a == "Arrived" and state_b == "Arrived", "对向交错应真正到达，而非失败/取消")
	_check(max_overlap_streak < 90, "窄路交错时不得长时间完全重叠")
	_check(
		_planar_distance(tank_a.global_position, tank_b.global_position) >= 1.2,
		"交错结束后两辆 Tank 应保持可通行间距"
	)

	var gather_point: Vector3 = (
		(tank_a.global_position + tank_b.global_position) * 0.5 + Vector3(0, 0, 6)
	)
	var gather_orders: Dictionary = gateway.MoveUnits([tank_a, tank_b], gather_point, human)
	order_a = _order_id_of(gather_orders, 0)
	order_b = _order_id_of(gather_orders, 1)
	for _frame in range(360):
		await get_tree().physics_frame
		if not (_alive(tank_a) and _alive(tank_b)):
			break
		state_a = gateway.GetOrderState(order_a)
		state_b = gateway.GetOrderState(order_b)
		if _is_terminal(state_a) and _is_terminal(state_b):
			break
	_check(
		state_a == "Arrived" and state_b == "Arrived",
		"多单位集结应真正到达（states=%s/%s）" % [state_a, state_b]
	)
	_check(
		_planar_distance(tank_a.global_position, tank_b.global_position) >= 1.2,
		"多单位前往同一区域后不得叠在同一点"
	)

	print("Local avoidance smoke test completed: %d failure(s)" % _failures)
	match_instance.queue_free()
	await get_tree().process_frame
	SmokeTestExit.request(get_tree(), 0 if _failures == 0 else 1)


## 只认权威终态；空字符串（没有订单/订单已被丢弃）不算结束，避免"假通过"。
func _is_terminal(state: String) -> bool:
	return state in ["Arrived", "Unreachable", "Cancelled", "UnitLost"]


func _alive(unit) -> bool:
	return unit != null and is_instance_valid(unit) and not unit.is_queued_for_deletion()


func _order_id_of(result: Dictionary, index := 0) -> String:
	var unit_results: Array = result.get("unit_results", [])
	if index >= unit_results.size():
		return ""
	return String(unit_results[index].get("order_id", ""))


func _planar_distance(first: Vector3, second: Vector3) -> float:
	return Vector2(first.x, first.z).distance_to(Vector2(second.x, second.z))


func _check(condition: bool, message: String):
	if condition:
		return
	_failures += 1
	push_error("Local avoidance assertion failed: %s" % message)
