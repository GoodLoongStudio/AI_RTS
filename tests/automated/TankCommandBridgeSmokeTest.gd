extends Node

const MatchScene = preload("res://tests/manual/TestOneUnit.tscn")
const Moving = preload("res://source/match/units/actions/Moving.gd")

var _failures := 0


func _ready():
	var match_instance = MatchScene.instantiate()
	add_child(match_instance)
	await get_tree().process_frame
	await get_tree().process_frame

	var human = match_instance.get_node("Players/Human")
	var tank = human.get_node("Tank")
	var gateway = human.get_node("UnitCommandGateway")
	var second_gateway = gateway.duplicate()
	second_gateway.name = "SecondaryUnitCommandGateway"
	human.add_child(second_gateway)
	await get_tree().process_frame
	var destination = tank.global_position + Vector3(2.0, 0.0, 0.0)

	var stance_result = gateway.SetEngagementStance([tank], "Guard", human)
	var fire_policy_result = second_gateway.SetFirePolicy([tank], "HoldFire", human)
	_check(stance_result["status"] == "Accepted", "Tank Guard stance should be accepted")
	_check(fire_policy_result["status"] == "Accepted", "Tank HoldFire policy should be accepted")
	_check(second_gateway.GetEngagementStance(tank) == "Guard", "gateways should share stance state")
	_check(gateway.GetFirePolicy(tank) == "HoldFire", "gateways should share fire policy state")
	_check(
		gateway.GetGuardAnchor(tank).is_equal_approx(tank.global_position),
		"idle Tank should capture current position as Guard anchor"
	)

	var move_result = gateway.ForceMoveUnits([tank], destination, human)
	_check(move_result["status"] == "Accepted", "Tank move should be accepted")
	_check(tank.action != null and tank.action.get_script() == Moving, "Tank should use Moving bridge")
	var order_id = move_result["unit_results"][0]["order_id"]
	_check(not order_id.is_empty(), "accepted Tank move should return an order id")
	_check(gateway.GetActiveOrderState(tank) == "InProgress", "move order should be in progress")
	_check(
		second_gateway.GetOrderState(order_id) == "InProgress",
		"all gateways should read the same Match-level order store"
	)
	tank.find_child("Movement").movement_finished.emit()
	await get_tree().process_frame
	_check(gateway.GetOrderState(order_id) == "Arrived", "movement completion should complete its order")
	_check(
		gateway.GetGuardAnchor(tank).is_equal_approx(tank.global_position),
		"Guard anchor should update to actual position after player movement completes"
	)

	move_result = gateway.ForceMoveUnits([tank], destination, human)
	order_id = move_result["unit_results"][0]["order_id"]
	_check(gateway.GetActiveOrderState(tank) == "InProgress", "replacement move should be in progress")

	var halt_result = second_gateway.HaltMovement([tank], human)
	_check(halt_result["status"] == "Accepted", "Tank halt should be accepted")
	_check(tank.action == null or tank.action.get_script() != Moving, "Tank Moving action should stop")
	_check(gateway.GetActiveOrderState(tank) == "Suspended", "halt should suspend the active order")
	_check(
		gateway.GetGuardAnchor(tank).is_equal_approx(tank.global_position),
		"Guard anchor should update to interruption position after halt"
	)
	_check(
		second_gateway.GetActiveOrderState(tank) == "Suspended",
		"halt through another gateway should update the shared order"
	)
	tank.find_child("Movement").movement_finished.emit()
	_check(gateway.GetOrderState(order_id) == "Suspended", "late completion must not overwrite suspension")

	print("Tank command bridge smoke test completed: %d failure(s)" % _failures)
	match_instance.queue_free()
	await get_tree().process_frame
	get_tree().quit(0 if _failures == 0 else 1)


func _check(condition: bool, message: String):
	if condition:
		return
	_failures += 1
	push_error("Tank command bridge assertion failed: %s" % message)
