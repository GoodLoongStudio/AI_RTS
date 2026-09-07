extends Node

## 左侧选中单位头像栏冒烟测试：框选多个单位后逐格显示头像，点击头像单独选中该单位。

const MatchScene = preload("res://tests/manual/TestAllUnits.tscn")

var _failures := 0
var _finished := false


func _ready():
	# 看门狗：任何协程中断都不得让进程永久挂起占 GPU
	get_tree().create_timer(45.0).timeout.connect(_on_failsafe)
	var match_instance = MatchScene.instantiate()
	add_child(match_instance)
	await get_tree().process_frame
	await get_tree().create_timer(0.5).timeout

	var panel = match_instance.get_node_or_null("HUD/SelectionPortraitPanel")
	_check(panel != null, "对局应挂载左侧选中单位头像栏")
	if panel == null:
		_finish()
		return
	var grid = panel._grid
	var human = match_instance.get_node("Players/Human")

	var units = [
		human.get_node("Worker"),
		human.get_node("Tank"),
		human.get_node("Drone"),
	]
	MatchSignals.deselect_all_units.emit()
	await get_tree().process_frame
	for unit in units:
		unit.get_node("Selection").select()
	await get_tree().process_frame

	_check(panel.visible, "有选中单位时头像栏应可见")
	# 固定框：网格恒为 20 槽（3 个头像 + 17 个透明占位），框宽恒定
	var cells = grid.get_children().filter(func(cell): return cell.has_meta("unit"))
	_check(cells.size() == units.size(), "头像格数应等于选中单位数（实际 %d）" % cells.size())
	_check(
		grid.get_children().size() == 20,
		"槽位总数应恒为 20（实际 %d）" % grid.get_children().size()
	)
	var bar_width: float = panel._scroll.custom_minimum_size.x
	_check(
		is_equal_approx(bar_width, panel.FRAME_WIDTH),
		"框宽应恒定为 %.0fpx（实际 %.0fpx）" % [panel.FRAME_WIDTH, bar_width]
	)

	# 点击第一个头像：应只保留该单元格绑定的单位选中
	var clicked_unit = cells[0].get_meta("unit")
	cells[0].pressed.emit()
	await get_tree().process_frame
	var selected_now = get_tree().get_nodes_in_group("selected_units")
	var selected_names := selected_now.map(func(u): return str(u.name))
	_check(
		selected_now.size() == 1 and selected_now[0] == clicked_unit,
		"点击 %s 头像后应只选中该单位（实际 %s）" % [str(clicked_unit.name), str(selected_names)]
	)

	# 取消全选后头像栏应隐藏
	MatchSignals.deselect_all_units.emit()
	await get_tree().process_frame
	_check(not panel.visible, "无选中单位时头像栏应隐藏")

	_finish()


func _on_failsafe():
	if _finished:
		return
	print("FAIL: 看门狗超时——测试协程中断未收尾")
	_finish()


func _finish():
	if _finished:
		return
	_finished = true
	print("Selection portrait panel smoke test completed: %d failure(s)" % _failures)
	SmokeTestExit.request(get_tree(), 0 if _failures == 0 else 1)


func _check(condition: bool, message: String):
	if condition:
		return
	_failures += 1
	print("FAIL: %s" % message)
	push_error("Selection portrait panel assertion failed: %s" % message)
