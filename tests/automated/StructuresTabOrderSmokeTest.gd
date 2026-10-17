extends Node

## 建筑页格子顺序回归测试（2026-10-10）
##
## 用户口径（原话）：「这个UI的顺序也要调整一下，主基地肯定在最上面最左边」
## ⇒ 侧边栏**建筑页第 1 格必须是基地（CommandCenter）**，矿场顺延第 2 格。
## 本条**覆盖** 2026-09-28 的旧口径（当时要求"矿场放第一个"）。
##
## 权威来源：`source/match/hud/ra3/Ra3Sidebar.gd` 的 `const TABS` → `tabs[0].items` 字面顺序。
## 依据：建筑页是 `place == true` 页签，`_sorted_items_for()` 对它**不排序**，
## 所以字面顺序就是显示顺序；`ProductionCatalog` 也按该数组顺序构建条目。
##
## 断言：
##  1) 建筑页第 1 格 = 基地（command_center），第 2 格 = 矿场（ore_refinery）；
##  2) 建筑页**不排序**：`_sorted_items_for()` 返回顺序与 `items` 完全一致
##     （防止将来有人给建筑页加"按造价排序"把口径改坏）；
##  3) 数据层跟随：`ProductionCatalog.entries("structures")[0].unit_id == "command_center"`；
##  4) 其它页签的字面顺序未被本次改动波及（步兵=步兵、载具=矿车、飞机=无人机）。

const SidebarScript = preload("res://source/match/hud/ra3/Ra3Sidebar.gd")
const Catalog = preload("res://source/match/hud/production/ProductionCatalog.gd")

var _failures := 0


func _ready():
	var tabs: Array = SidebarScript.TABS
	_check(not tabs.is_empty(), "TABS 不应为空")
	if tabs.is_empty():
		_finish()
		return

	var structures: Dictionary = tabs[0]
	_check(str(structures.get("id", "")) == "structures", "第 1 个页签应是建筑页（实际 %s）" % str(structures.get("id", "")))
	var items: Array = structures.get("items", [])
	_check(items.size() >= 2, "建筑页应至少有 2 个条目（实际 %d）" % items.size())
	if items.size() < 2:
		_finish()
		return

	# 1) 第 1 格 = 基地，第 2 格 = 矿场
	var first: Dictionary = items[0]
	var second: Dictionary = items[1]
	print("  [info] 建筑页前两格: %s / %s" % [
		str(first.get("caption", "")), str(second.get("caption", ""))])
	_check(str(first.get("caption", "")) == "基地",
		"建筑页第 1 格应是基地（实际 %s）" % str(first.get("caption", "")))
	_check(str(first.get("icon", "")) == "command_center",
		"基地的 icon 应是 command_center（实际 %s）" % str(first.get("icon", "")))
	_check(str(first.get("scene", "")).contains("CommandCenter"),
		"第 1 格的 scene 应是 CommandCenter（实际 %s）" % str(first.get("scene", "")))
	_check(str(second.get("caption", "")) == "矿场",
		"建筑页第 2 格应是矿场（实际 %s）" % str(second.get("caption", "")))

	# 2) 建筑页不排序：显示顺序 == 字面顺序
	var sidebar = SidebarScript.new()
	var displayed: Array = sidebar._sorted_items_for(structures)
	var literal_icons: Array = []
	for item in items:
		literal_icons.append(str(item.get("icon", "")))
	var displayed_icons: Array = []
	for item in displayed:
		displayed_icons.append(str(item.get("icon", "")))
	print("  [info] 显示顺序: %s" % str(displayed_icons))
	_check(displayed_icons == literal_icons,
		"建筑页不得被排序（字面 %s / 显示 %s，两者必须一致）" % [str(literal_icons), str(displayed_icons)])
	sidebar.free()

	# 3) 数据层（生产目录）跟随同一顺序
	var rows: Array = Catalog.entries("structures")
	_check(not rows.is_empty(), "生产目录应有建筑页条目")
	if not rows.is_empty():
		var row: Dictionary = rows[0]
		print("  [info] 目录第 1 条: unit_id=%s display_name=%s" % [
			str(row.get("unit_id", "")), str(row.get("display_name", ""))])
		_check(str(row.get("unit_id", "")) == "command_center",
			"生产目录建筑页第 1 条应是 command_center（实际 %s）" % str(row.get("unit_id", "")))

	# 4) 其它页签未被波及（各取第 1 格图标）
	var expected_first_icons := {"infantry": "soldier", "vehicles": "worker", "aircraft": "drone"}
	for tab in tabs:
		var tab_id := str(tab.get("id", ""))
		if not expected_first_icons.has(tab_id):
			continue
		var tab_items: Array = tab.get("items", [])
		if tab_items.is_empty():
			_fail("%s 页不应为空" % tab_id)
			continue
		var icon := str((tab_items[0] as Dictionary).get("icon", ""))
		_check(icon == str(expected_first_icons[tab_id]),
			"%s 页第 1 格应是 %s（实际 %s）" % [tab_id, str(expected_first_icons[tab_id]), icon])

	# 5) 【对齐 NetInfantrySmokeTest 对 TABS 的判据】那条联机测试在本工作区无法单独跑
	#    （清单标了 `prelaunch_server: true`；且全量运行器因既存的 130 个"未登记场景"
	#      审计不匹配而拒绝启动，与本改动无关），
	#    所以把它与 TABS 有关的两条判据一并守在这里：
	#    ① 侧栏必须含步兵页签；② 建筑页里必须有兵营（步兵的唯一生产者）。
	var tab_ids: Array = []
	for tab in tabs:
		tab_ids.append(str(tab.get("id", "")))
	_check("infantry" in tab_ids, "侧栏应包含步兵页签（实际 %s）" % str(tab_ids))
	var has_barracks := false
	for item in items:
		if str(item.get("scene", "")).contains("Barracks"):
			has_barracks = true
	_check(has_barracks, "建筑页应包含兵营（步兵页的生产者）")

	_finish()


func _check(condition: bool, message: String):
	if condition:
		print("  ok: %s" % message)
		return
	_fail(message)


func _fail(message: String):
	_failures += 1
	print("FAIL: %s" % message)
	push_error("Structures tab order assertion failed: %s" % message)


func _finish():
	print("Structures tab order smoke test completed: %d failure(s)" % _failures)
	SmokeTestExit.request(get_tree(), 0 if _failures == 0 else 1)
