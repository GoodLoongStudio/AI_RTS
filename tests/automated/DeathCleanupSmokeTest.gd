extends Node

const MatchScene = preload("res://tests/manual/TestMultiUnitCommands.tscn")

var _failures := 0
var _deselected_units: Array = []


func _ready():
	var match_instance = MatchScene.instantiate()
	add_child(match_instance)
	await get_tree().process_frame
	await get_tree().process_frame

	MatchSignals.unit_deselected.connect(func(unit): _deselected_units.append(unit))
	var human = match_instance.get_node("Players/Human")
	var first_tank = human.get_node("Tank")
	var second_tank = human.get_node("SecondTank")
	var enemy_tank = match_instance.get_node("Players/Enemy/EnemyTank")
	var gateway = human.get_node("UnitCommandGateway")
	var groups = match_instance.get_node("Handlers/UnitGroupSelectionHandler")

	MatchSignals.deselect_all_units.emit()
	first_tank.find_child("Selection").select()
	groups.SaveControlGroup(1)
	var move_result = gateway.MoveUnits(
		[first_tank], first_tank.global_position + Vector3(4, 0, 0), human
	)
	var move_order_id: String = move_result["unit_results"][0]["order_id"]
	var first_unit_id: String = str(first_tank.get_meta("ai_rts_unit_id"))
	var camera = match_instance.get_node("IsometricCamera3D")
	var query = match_instance.get_node("WorldQueryRuntime")
	var command_runtime = match_instance.get_node("CommandRuntime")
	first_tank.add_to_group("legacy_ai_squad_1")
	camera.set_follow_target(first_tank)
	_check(first_tank.is_in_group("selected_units"), "死亡前 Tank 应仍被选中")
	_check(command_runtime.HasLiveRuntimeUnit(first_unit_id), "死亡前命令注册表应能解析该单位")
	var session: String = query.GetStandardSessionForTests(human)
	var forces_before: Dictionary = query.GetOwnForces(session, 1)
	_check(_own_forces_has(forces_before, first_unit_id), "死亡前 Query 应包含该己方单位")

	gateway.SetFirePolicy([second_tank], "FireAtWill", human)
	gateway.SetFirePolicy([enemy_tank], "HoldFire", match_instance.get_node("Players/Enemy"))
	var attack_result = gateway.AttackUnits([second_tank], enemy_tank, human)
	_check(attack_result.get("status", "") in ["Accepted", "PartiallyAccepted"],
		"第二辆 Tank 应能对敌军下达攻击")
	var attack_order_id: String = attack_result["unit_results"][0].get("order_id", "")

	first_tank.hp = 0
	await get_tree().process_frame
	await get_tree().process_frame

	_check(not is_instance_valid(first_tank) or first_tank.is_queued_for_deletion(),
		"达到死亡条件后单位应失效")
	_check(
		get_tree().get_nodes_in_group("selected_units").filter(
			func(unit): return is_instance_valid(unit)
		).is_empty(),
		"死亡单位不得留在 selected_units"
	)
	_check(not _deselected_units.is_empty(), "死亡应发出取消选择，供 HUD 和菜单清理")
	_check(gateway.GetOrderState(move_order_id) == "UnitLost", "死者活动订单应为 UnitLost")
	var group_after: Dictionary = groups.InspectControlGroup(1)
	_check(group_after.get("unit_ids", []).is_empty(), "死亡单位应从控制组剔除")
	_check(camera.get_follow_target() == null, "镜头跟随目标死亡后应解除跟随")
	_check(not command_runtime.HasLiveRuntimeUnit(first_unit_id), "死亡后命令注册表不得再解析该单位")
	_check(
		get_tree().get_nodes_in_group("legacy_ai_squad_1").filter(
			func(unit): return is_instance_valid(unit)
		).is_empty(),
		"死亡后 AI 小队引用应失效"
	)
	var forces_after: Dictionary = query.GetOwnForces(session, 1)
	_check(not _own_forces_has(forces_after, first_unit_id), "死亡后 Query 不得再返回该己方单位")

	enemy_tank.hp = 0
	await get_tree().process_frame
	await get_tree().process_frame
	_check(gateway.GetOrderState(attack_order_id) == "TargetLost", "攻击目标死亡后订单应为 TargetLost")

	print("Death cleanup smoke test completed: %d failure(s)" % _failures)
	match_instance.queue_free()
	await get_tree().process_frame
	SmokeTestExit.request(get_tree(), 0 if _failures == 0 else 1)


func _own_forces_has(result: Dictionary, unit_id: String) -> bool:
	for entity in result.get("entities", []):
		if str(entity.get("id", "")) == unit_id:
			return true
	return false


func _check(condition: bool, message: String):
	if condition:
		return
	_failures += 1
	push_error("Death cleanup assertion failed: %s" % message)
