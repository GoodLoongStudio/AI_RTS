extends Node

const MatchScene = preload("res://tests/manual/TestMultiUnitCommands.tscn")
const SmokeTestWarmup = preload("res://tests/automated/SmokeTestWarmup.gd")

var _failures := 0


## 验证 Match 级 C# 控制组保存稳定 ID、替换 Selection 并隔离 Legacy AI Squad。
func _ready():
	var match_instance = MatchScene.instantiate()
	add_child(match_instance)
	# ⚠️ `Match._ready()` 是**异步**的（要等地图加载 → 单位注册 → 往 `players` 组加人、
	# 给己方单位加 `controlled_units`）。原来只 `await process_frame` 两帧，这时上下文还没建好：
	#   · `Match.get_local_player()` 解析不到 Human ⇒ C# 侧所有控制组调用返回
	#     `Rejected / RuntimeUnavailable`（**连"空选择"那条也 Rejected**）；
	#   · `Selection.select()` 因单位不在 `controlled_units` 而全部拒绝
	#     （`source/match/units/traits/Selection.gd:32`）⇒ 选择恒为空。
	# 两者叠加曾导致本测试 9 处失败（2026-09-14 定位）。必须等就绪再断言。
	await SmokeTestWarmup.wait_for_units(get_tree(), 1)
	await get_tree().create_timer(0.5).timeout

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

	_seed_selection([enemy_tank])
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
## `deselect_all_units` 只对 `Selection._selected == true` 的节点生效；被直接注入过表现组的
## 单位不会因此移除，所以这里必须显式清空，保证「选择集合恰好等于 units」的语义。
func _select_only(units: Array):
	_reset_selection_group()
	_neutralize_double_click()
	for unit in units:
		unit.find_child("Selection").select()


## 直接把单位塞进 Selection 表现组，绕过输入层归属闸门。
##
## `Selection.select()` 的 `controlled_units` 闸门是 `1c5bbca` 引入的，**晚于**本测试的
## `97dcaa9`。从此敌方单位无法再经由输入路径进入 `selected_units`，原来用 `_select_only`
## 驱动的那条断言变为不可达（表现为 status 从 `AcceptedWithFilteredMembers` 退化成 `Accepted`）。
## 但 C# 控制组服务是稳定 ID 权威层，必须对**任何来源**的成员做归属校验（深度防御），
## 所以这里直接注入表现组，专门校验 C# 层确实把敌方单位过滤掉。
func _seed_selection(units: Array):
	_reset_selection_group()
	for unit in units:
		if not unit.is_in_group("selected_units"):
			unit.add_to_group("selected_units")


## 清空 Selection 表现组（含被直接注入、`Selection._selected` 仍为 false 的残留成员）。
func _reset_selection_group():
	MatchSignals.deselect_all_units.emit()
	for unit in get_tree().get_nodes_in_group("selected_units"):
		unit.remove_from_group("selected_units")


## 复位「双击选中同型单位」的状态机，避免测试自己制造出假双击。
##
## `DoubleClickUnitSelectionHandler._on_unit_selected()` 监听 `MatchSignals.unit_selected`：
## 同一个单位在 50~600ms 内被选中两次即判为双击，并调用 `_handle_double_click()` 把**同型**
## 所有单位一并选上。本测试在**同一帧内**反复 `select()` 同一个 `first_tank`，
## `Time.get_ticks_msec()` 几乎不动 ⇒ 第 45 行的选中会被读成「双击」⇒ `SecondTank`
## 被额外塞进选择 ⇒ 「控制组 2 应保留 Tank 与 CommandCenter」偶发变成 3 个成员。
##
## 是否触发取决于第 31 行两次 `select()` 之间的毫秒是否跨过 50ms 门槛 —— 这正是那 ~1/3
## 偶发率的来源（测试自身的驱动节奏，不是控制组代码的问题）。真实操作里保存控制组不会
## 调用 `select()`，所以这里显式复位该状态机，让断言只受被测逻辑影响。
func _neutralize_double_click():
	var handler := get_tree().root.find_child("DoubleClickUnitSelectionHandler", true, false)
	if handler == null:
		return
	handler.set("_last_unit_selected", null)
	handler.set("_last_unit_selected_timestamp", 0)


## 返回节点当前是否属于 Selection 表现组。
func _is_selected(unit: Node) -> bool:
	return unit.is_in_group("selected_units")


## 累计断言失败并输出可定位原因。
func _check(condition: bool, message: String):
	if condition:
		return
	_failures += 1
	push_error(message)
