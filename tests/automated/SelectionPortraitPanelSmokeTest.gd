extends Node

## 左侧选中单位头像栏冒烟测试（2026-09-08 堆叠版）：
## 同类型单位堆叠为一格 + ×N 角标，贴屏幕左侧，点击头像选中该类型全部单位。

const MatchScene = preload("res://tests/manual/TestAllUnits.tscn")
const WorkerScene = preload("res://source/match/units/Worker.tscn")

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

	# 额外 2 个工人 → 工人共 3 个 + 坦克 1 个 + 无人机 1 个 = 3 种堆叠格
	var extra_workers := []
	for index in range(2):
		var worker = WorkerScene.instantiate()
		MatchSignals.setup_and_spawn_unit.emit(
			worker, Transform3D(Basis.IDENTITY, Vector3(6.0 + index, 0.0, 12.0)), human, false
		)
		extra_workers.append(worker)
	await get_tree().process_frame

	var units = [
		human.get_node("Worker"),
		extra_workers[0],
		extra_workers[1],
		human.get_node("Tank"),
		human.get_node("Drone"),
	]
	MatchSignals.deselect_all_units.emit()
	await get_tree().process_frame
	for unit in units:
		unit.get_node("Selection").select()
	await get_tree().process_frame

	_check(panel.visible, "有选中单位时头像栏应可见")
	# 堆叠：5 个选中单位 → 3 种类型 → 3 格（工人×3、坦克×1、无人机×1）
	# 组顺序按场景树序（非选择顺序），因此按类型查找格子而不是按下标
	var cells = grid.get_children().filter(func(cell): return not cell.is_queued_for_deletion())
	_check(cells.size() == 3, "同类型应堆叠为一格（实际 %d 格）" % cells.size())
	var worker_cell = null
	var tank_cell = null
	for cell in cells:
		var cell_unit = cell.get_meta("unit")
		if cell_unit.scene_file_path == WorkerScene.resource_path:
			worker_cell = cell
		elif str(cell_unit.scene_file_path).ends_with("Tank.tscn"):
			tank_cell = cell
	_check(worker_cell != null, "工人类型应有独立堆叠格")
	var badges = worker_cell.get_children().filter(
		func(child): return child is Label and child.text.begins_with("×")
	)
	_check(
		badges.size() == 1 and badges[0].text == "×3",
		"工人格应显示 ×3 角标（实际 %s）" % (
			badges[0].text if not badges.is_empty() else "无"
		)
	)
	_check(tank_cell != null, "坦克类型应有独立堆叠格")
	var tank_badges = tank_cell.get_children().filter(
		func(child): return child is Label and child.text.begins_with("×")
	)
	_check(tank_badges.is_empty(), "单单位类型不应显示 ×N 角标")
	# 左侧栏位置：面板应贴屏幕左缘
	var panel_left: float = panel.global_position.x
	_check(panel_left < 40.0, "头像栏应贴屏幕左侧（left=%.0f）" % panel_left)

	# 点击工人堆叠格：应选中全部 3 个工人，其他类型取消
	worker_cell.pressed.emit()
	await get_tree().process_frame
	var selected_now = get_tree().get_nodes_in_group("selected_units")
	var all_workers = selected_now.filter(
		func(u): return u.scene_file_path == WorkerScene.resource_path
	)
	_check(
		selected_now.size() == 3 and all_workers.size() == 3,
		"点击工人堆叠格应选中全部工人（实际 %d 个，其中工人 %d 个）" % [
			selected_now.size(), all_workers.size()
		]
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
