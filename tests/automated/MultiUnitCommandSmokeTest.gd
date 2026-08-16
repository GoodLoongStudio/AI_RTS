extends Node

const MatchScene = preload("res://tests/manual/TestMultiUnitCommands.tscn")
const Moving = preload("res://source/match/units/actions/Moving.gd")

var _failures := 0


## 验证 Godot Gateway 在同一批多单位命令中保留逐单位结果和独立订单。
func _ready():
	var match_instance = MatchScene.instantiate()
	add_child(match_instance)
	await get_tree().process_frame
	await get_tree().process_frame

	var human = match_instance.get_node("Players/Human")
	var first_tank = human.get_node("Tank")
	var second_tank = human.get_node("SecondTank")
	var command_center = human.get_node("ImmobileCommandCenter")
	var enemy_tank = match_instance.get_node("Players/Enemy/EnemyTank")
	var gateway = human.get_node("UnitCommandGateway")
	var destination = Vector3(18.0, 0.0, 8.0)

	var result = gateway.ForceMoveUnits(
		[first_tank, second_tank, command_center, enemy_tank],
		destination,
		human
	)
	var unit_results: Array = result["unit_results"]
	var first_tank_result := _result_for_node(unit_results, first_tank)
	var second_tank_result := _result_for_node(unit_results, second_tank)
	var command_center_result := _result_for_node(unit_results, command_center)
	var enemy_tank_result := _result_for_node(unit_results, enemy_tank)

	_check(result["status"] == "PartiallyAccepted", "混合能力与所有权批次应部分接受")
	_check(unit_results.size() == 4, "四个不同单位应分别返回结果")
	_check(not first_tank_result.is_empty(), "第一辆 Tank 应能按稳定 ID 找到结果")
	_check(not second_tank_result.is_empty(), "第二辆 Tank 应能按稳定 ID 找到结果")
	_check(not command_center_result.is_empty(), "建筑应能按稳定 ID 找到结果")
	_check(not enemy_tank_result.is_empty(), "敌方 Tank 应能按稳定 ID 找到结果")
	_check(first_tank_result["accepted"], "第一辆己方 Tank 应接受移动")
	_check(second_tank_result["accepted"], "第二辆己方 Tank 应接受移动")
	_check(not command_center_result["accepted"], "不可移动建筑应拒绝移动")
	_check(command_center_result["error_code"] == "UnitCannotMove", "建筑应返回 UnitCannotMove")
	_check(not enemy_tank_result["accepted"], "敌方 Tank 应拒绝玩家命令")
	_check(enemy_tank_result["error_code"] == "UnitNotOwned", "敌方 Tank 应返回 UnitNotOwned")
	_check(not first_tank_result["order_id"].is_empty(), "第一辆 Tank 应获得订单 ID")
	_check(not second_tank_result["order_id"].is_empty(), "第二辆 Tank 应获得订单 ID")
	_check(
		first_tank_result["order_id"] != second_tank_result["order_id"],
		"接受同一批命令的单位应获得彼此独立的订单"
	)
	_check(first_tank.action != null and first_tank.action.get_script() == Moving, "第一辆 Tank 应执行移动")
	_check(second_tank.action != null and second_tank.action.get_script() == Moving, "第二辆 Tank 应执行移动")
	_check(enemy_tank.action == null or enemy_tank.action.get_script() != Moving, "敌方 Tank 不应执行玩家移动")

	var duplicate_result = gateway.ForceMoveUnits(
		[first_tank, first_tank, second_tank],
		destination + Vector3(0.0, 0.0, 1.0),
		human
	)
	_check(duplicate_result["status"] == "Accepted", "重复选择去重后应全部接受")
	_check(duplicate_result["unit_results"].size() == 2, "重复单位只能返回一次结果")

	var halt_result = gateway.HaltMovement([first_tank, second_tank, command_center], human)
	var halt_unit_results: Array = halt_result["unit_results"]
	var first_halt_result := _result_for_node(halt_unit_results, first_tank)
	var second_halt_result := _result_for_node(halt_unit_results, second_tank)
	var command_center_halt_result := _result_for_node(halt_unit_results, command_center)
	_check(halt_result["status"] == "PartiallyAccepted", "停止混合移动批次应部分接受")
	_check(first_halt_result["accepted"], "第一辆 Tank 应接受停止")
	_check(second_halt_result["accepted"], "第二辆 Tank 应接受停止")
	_check(
		command_center_halt_result["error_code"] == "UnitCannotMove",
		"建筑停止移动应稳定返回 UnitCannotMove"
	)
	_check(gateway.GetActiveOrderState(first_tank) == "Suspended", "第一辆 Tank 订单应暂停")
	_check(gateway.GetActiveOrderState(second_tank) == "Suspended", "第二辆 Tank 订单应暂停")

	print("Multi-unit command smoke test completed: %d failure(s)" % _failures)
	match_instance.queue_free()
	await get_tree().process_frame
	SmokeTestExit.request(get_tree(), 0 if _failures == 0 else 1)


## 按 Godot 节点保存的稳定 UnitId 查找逐单位命令结果，不依赖结果数组顺序。
func _result_for_node(results: Array, unit: Node) -> Dictionary:
	if not unit.has_meta("ai_rts_unit_id"):
		return {}
	var unit_id := str(unit.get_meta("ai_rts_unit_id"))
	for result in results:
		if str(result["unit_id"]) == unit_id:
			return result
	return {}


## 累计断言失败并写入 Godot 错误日志。
func _check(condition: bool, message: String):
	if condition:
		return
	_failures += 1
	push_error("Multi-unit command assertion failed: %s" % message)
