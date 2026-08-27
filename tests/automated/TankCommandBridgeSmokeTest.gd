extends Node

const MatchScene = preload("res://tests/manual/TestOneUnit.tscn")
const Moving = preload("res://source/match/units/actions/Moving.gd")

var _failures := 0
var _order_events: Array[Dictionary] = []


func _ready():
	var match_instance = MatchScene.instantiate()
	add_child(match_instance)
	await get_tree().process_frame
	await get_tree().process_frame

	var human = match_instance.get_node("Players/Human")
	var tank = human.get_node("Tank")
	var gateway = human.get_node("UnitCommandGateway")
	var runtime = match_instance.get_node("CommandRuntime")
	runtime.connect("OrderStateChanged", _on_order_state_changed)
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

	var move_result = gateway.MoveUnits([tank], destination, human)
	_check(move_result["status"] == "Accepted", "Tank move should be accepted")
	_check(tank.action != null and tank.action.get_script() == Moving, "Tank should use Moving bridge")
	var order_id = move_result["unit_results"][0]["order_id"]
	_check(not order_id.is_empty(), "accepted Tank move should return an order id")
	_check(gateway.GetActiveOrderState(tank) == "InProgress", "move order should be in progress")
	var initial_snapshot: Dictionary = gateway.GetOrderSnapshot(order_id)
	_check(initial_snapshot["order_id"] == order_id, "snapshot should retain stable order id")
	_check(initial_snapshot["kind"] == "Move", "snapshot should expose order kind")
	_check(initial_snapshot["state"] == "InProgress", "snapshot should expose current state")
	_check(
		_states_for_order(order_id) == ["Accepted", "InProgress"],
		"new move should emit creation and execution events"
	)
	_check(
		second_gateway.GetOrderState(order_id) == "InProgress",
		"all gateways should read the same Match-level order store"
	)
	tank.find_child("Movement").movement_finished.emit()
	await get_tree().process_frame
	_check(gateway.GetOrderState(order_id) == "Arrived", "movement completion should complete its order")
	_check(
		_states_for_order(order_id) == ["Accepted", "InProgress", "Arrived"],
		"movement completion should emit Arrived exactly once"
	)
	_check(
		gateway.GetGuardAnchor(tank).is_equal_approx(tank.global_position),
		"Guard anchor should update to actual position after player movement completes"
	)

	move_result = gateway.MoveUnits([tank], destination + Vector3(0.0, 0.0, 2.0), human)
	order_id = move_result["unit_results"][0]["order_id"]
	_check(gateway.GetActiveOrderState(tank) == "InProgress", "second move should be in progress")
	tank.find_child("Movement").emit_signal("movement_ended", "Unreachable")
	await get_tree().process_frame
	_check(gateway.GetOrderState(order_id) == "Unreachable", "unreachable navigation must complete as Unreachable")
	_check(
		_states_for_order(order_id) == ["Accepted", "InProgress", "Unreachable"],
		"unreachable navigation should emit Unreachable exactly once"
	)
	var last_terminal: Dictionary = gateway.GetLastTerminalOrder(tank)
	_check(last_terminal.get("state", "") == "Unreachable", "AI/玩家应能查询到最近一次不可达终态")
	var hud = match_instance.get_node_or_null("HUD/TraditionalUnitCommandHUD")
	_check(hud != null, "传统命令栏应存在以显示不可达")
	if hud != null:
		var feedback_label = hud.get_node("MarginContainer/VBoxContainer/FeedbackLabel")
		_check("无法到达目标" in feedback_label.text, "玩家 HUD 必须明确提示无法到达")
	tank.find_child("Movement").movement_finished.emit()
	_check(
		gateway.GetOrderState(order_id) == "Unreachable",
		"late Arrived fallback must not overwrite Unreachable"
	)

	move_result = gateway.ForceMoveUnits([tank], destination, human)
	order_id = move_result["unit_results"][0]["order_id"]
	_check(gateway.GetActiveOrderState(tank) == "InProgress", "replacement move should be in progress")

	var halt_result = second_gateway.StopUnits([tank], human)
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
	_check(
		_states_for_order(order_id) == ["Accepted", "InProgress", "Suspended"],
		"halt should emit Suspended and late completion should not add a false Arrived event"
	)
	var suspended_order_id = order_id
	var replacement_result = gateway.MoveUnits([tank], destination + Vector3(1.0, 0.0, 0.0), human)
	var replacement_order_id = replacement_result["unit_results"][0]["order_id"]
	var replacement_command_id = replacement_result["command_id"]
	var suspended_snapshot: Dictionary = gateway.GetOrderSnapshot(suspended_order_id)
	_check(suspended_snapshot["state"] == "Cancelled", "new command should cancel suspended order")
	_check(
		suspended_snapshot["replaced_by_command_id"] == replacement_command_id,
		"cancelled order should identify its replacing command"
	)
	_check(
		_states_for_order(suspended_order_id) == ["Accepted", "InProgress", "Suspended", "Cancelled"],
		"replacement should emit Cancelled for the previous suspended order"
	)
	tank.queue_free()
	await get_tree().process_frame
	_check(gateway.GetOrderState(replacement_order_id) == "UnitLost", "unit exit should end active order as UnitLost")
	_check(
		_states_for_order(replacement_order_id) == ["Accepted", "InProgress", "UnitLost"],
		"unit exit should emit UnitLost exactly once"
	)

	print("Tank command bridge smoke test completed: %d failure(s)" % _failures)
	match_instance.queue_free()
	await get_tree().process_frame
	SmokeTestExit.request(get_tree(), 0 if _failures == 0 else 1)


func _check(condition: bool, message: String):
	if condition:
		return
	_failures += 1
	push_error("Tank command bridge assertion failed: %s" % message)


## 收集 Match 唯一 CommandRuntime 发布的权威订单状态事件。
func _on_order_state_changed(
	order_id: String,
	command_id: String,
	unit_id: String,
	kind: String,
	previous_state: String,
	current_state: String,
	replaced_by_command_id: String
):
	_order_events.append({
		"order_id": order_id,
		"command_id": command_id,
		"unit_id": unit_id,
		"kind": kind,
		"previous_state": previous_state,
		"current_state": current_state,
		"replaced_by_command_id": replaced_by_command_id,
	})


## 按稳定订单 ID 提取状态序列，不依赖其他单位或替换订单的事件顺序。
func _states_for_order(order_id: String) -> Array[String]:
	var states: Array[String] = []
	for event in _order_events:
		if event["order_id"] == order_id:
			states.append(event["current_state"])
	return states
