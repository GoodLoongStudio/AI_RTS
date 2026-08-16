extends Node

const MatchScene = preload("res://tests/manual/TestMultiUnitCommands.tscn")

var _failures := 0


## 验证 Match 级 C# 控制组保存稳定 ID、替换 Selection 并隔离 Legacy AI Squad。
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
	var runtime = match_instance.get_node("Handlers/UnitGroupSelectionHandler")
	var input_runtime = match_instance.get_node("InputBindingRuntime")

	_select_only([first_tank, second_tank])
	input_runtime.emit_signal("ActionPressed", "group.set_1")
	var first_group: Dictionary = runtime.InspectControlGroup(1)
	_check(first_group.get("status", "") == "Accepted", "控制组 1 应成功保存")
	_check(first_group.get("unit_ids", []).size() == 2, "控制组 1 应保存两辆 Tank")
	_check(not first_tank.is_in_group("unit_group_1"), "C# 控制组不得创建 unit_group_1")
	_check(not second_tank.is_in_group("unit_group_1"), "第二辆 Tank 也不得依赖旧节点组")

	_select_only([command_center])
	input_runtime.emit_signal("ActionPressed", "group.access_1")
	_check(_is_selected(first_tank) and _is_selected(second_tank),
		"访问控制组 1 应替换选择并召回两辆 Tank")
	_check(not _is_selected(command_center), "访问非空组应取消先前建筑选择")

	_select_only([first_tank, command_center])
	var building_save: Dictionary = runtime.SaveControlGroup(2)
	_check(building_save.get("status", "") == "Accepted",
		"移动单位和建筑应能共同保存到控制组")
	_check(building_save.get("unit_ids", []).size() == 2,
		"控制组 2 应保留 Tank 与 CommandCenter")

	_select_only([])
	var empty_save: Dictionary = runtime.SaveControlGroup(3)
	_check(empty_save.get("status", "") == "Accepted", "空选择应成功清空控制组")
	_select_only([command_center])
	var empty_recall: Dictionary = runtime.RecallControlGroup(3)
	_check(empty_recall.get("is_empty", false), "空控制组 Recall 应显式返回 is_empty")
	_check(get_tree().get_nodes_in_group("selected_units").is_empty(),
		"访问空控制组应取消当前 Selection")

	_select_only([enemy_tank])
	var filtered: Dictionary = runtime.SaveControlGroup(4)
	_check(filtered.get("status", "") == "AcceptedWithFilteredMembers",
		"敌方选择输入应被过滤但空替换仍然应用")
	_check(filtered.get("unit_ids", []).is_empty(), "敌方单位不得进入玩家控制组")

	_select_only([first_tank, second_tank])
	runtime.SaveControlGroup(5)
	first_tank.queue_free()
	await get_tree().process_frame
	var after_exit: Dictionary = runtime.InspectControlGroup(5)
	_check(after_exit.get("unit_ids", []).size() == 1,
		"单位退出后应主动从全部控制组剔除")

	_check(not command_center.is_in_group("legacy_ai_squad_1"),
		"普通控制组成员不得自动进入 Legacy AI Squad")

	print("Control group runtime smoke test completed: %d failure(s)" % _failures)
	match_instance.queue_free()
	await get_tree().process_frame
	SmokeTestExit.request(get_tree(), 0 if _failures == 0 else 1)


## 用指定节点集合替换当前 Godot Selection。
func _select_only(units: Array):
	MatchSignals.deselect_all_units.emit()
	for unit in units:
		unit.find_child("Selection").select()


## 返回节点当前是否属于 Selection 表现组。
func _is_selected(unit: Node) -> bool:
	return unit.is_in_group("selected_units")


## 累计断言失败并输出可定位原因。
func _check(condition: bool, message: String):
	if condition:
		return
	_failures += 1
	push_error(message)
