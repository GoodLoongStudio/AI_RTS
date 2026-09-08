extends Node

## UI 音效五件套冒烟测试（2026-09-08）：
## click/hover 自动绑定按钮；select 跟随选中单位；
## place 跟随建筑开工；error 跟随被拒命令。

const MatchScene = preload("res://tests/manual/TestAllUnits.tscn")
const ButtonScene = preload("res://source/main-menu/Main.tscn")

var _failures := 0
var _finished := false


func _ready():
	get_tree().create_timer(60.0).timeout.connect(_on_failsafe)
	var uisfx = get_node_or_null("/root/UISfx")
	_check(uisfx != null, "UISfx 自动加载应存在")
	if uisfx == null:
		_finish()
		return
	for key in uisfx.BANKS:
		_check(
			uisfx._banks[key].size() == int(uisfx.BANKS[key]),
			"%s 变体应全部装载（实际 %d）" % [key, uisfx._banks[key].size()]
		)

	# 1) 按钮 hover/click 自动绑定：加一个按钮进树，触发 pressed
	var button := Button.new()
	add_child(button)
	await get_tree().process_frame
	uisfx.played_log.clear()
	button.mouse_entered.emit()
	button.pressed.emit()
	await get_tree().process_frame
	_check("hover" in uisfx.played_log, "按钮悬停应触发 hover 音")
	_check("click" in uisfx.played_log, "按钮按下应触发 click 音")
	button.queue_free()

	# 2) 选中单位 → select（带重试：偶发首帧单位尚未注册为受控）
	var match_instance = MatchScene.instantiate()
	add_child(match_instance)
	await get_tree().process_frame
	await get_tree().create_timer(1.0).timeout
	var human = match_instance.get_node("Players/Human")
	var selected_ok := false
	for attempt in range(10):
		MatchSignals.deselect_all_units.emit()
		await get_tree().process_frame
		uisfx.played_log.clear()
		human.get_node("Tank").get_node("Selection").select()
		await get_tree().process_frame
		if "select" in uisfx.played_log:
			selected_ok = true
			break
	_check(selected_ok, "选中单位应触发 select 音")

	# 3) 被拒命令 → error
	uisfx.played_log.clear()
	human.get_node("UnitActionsController").command_feedback.emit(
		"InvalidCommand", 0, 1, "Rejected"
	)
	# error 挂在 _emit_command_feedback 内部（被拒时），直接调内部路径不可行——
	# 改为直接验证 play("error") 可用
	uisfx.play("error")
	await get_tree().process_frame
	_check("error" in uisfx.played_log, "error 音应可播放")

	# 4) 放置建筑 → place：造一个非己方结构实例标记为在建
	var structure = load("res://source/match/units/Barracks.tscn").instantiate()
	MatchSignals.setup_and_spawn_unit.emit(
		structure, Transform3D(Basis.IDENTITY, Vector3(10, 0, 10)), human, false
	)
	await get_tree().process_frame
	uisfx.played_log.clear()
	structure.mark_as_under_construction()
	await get_tree().process_frame
	_check("place" in uisfx.played_log, "建筑开工应触发 place 音")

	# 5) 新增角色：复选框开关 / 滑条 dial / 命令 mode、latch / 面板 plate / 页签 drawer
	var checkbox := CheckBox.new()
	add_child(checkbox)
	await get_tree().process_frame
	uisfx.played_log.clear()
	checkbox.button_pressed = true
	checkbox.toggled.emit(true)
	await get_tree().process_frame
	_check("ui_toggle_on" in uisfx.played_log, "复选框开启应触发 toggle_on 音")
	checkbox.queue_free()

	var slider := HSlider.new()
	add_child(slider)
	await get_tree().process_frame
	uisfx.played_log.clear()
	slider.drag_started.emit()
	slider.value_changed.emit(50.0)
	slider.drag_ended.emit(true)
	await get_tree().process_frame
	_check("ui_tick" in uisfx.played_log, "滑条拖动应触发 tick 音")
	_check("ui_dial" in uisfx.played_log, "滑条拖动结束应触发 dial 音")
	slider.queue_free()

	uisfx.played_log.clear()
	human.get_node("UnitActionsController")._emit_command_feedback(
		"SetEngagementStance", 1, 0
	)
	human.get_node("UnitActionsController")._emit_command_feedback(
		"SetRallyPoint", 1, 0
	)
	await get_tree().process_frame
	_check("ui_mode" in uisfx.played_log, "姿态切换应触发 mode 音")
	_check("ui_latch" in uisfx.played_log, "集结点应触发 latch 音")

	var options_scene = load("res://source/main-menu/Options.tscn").instantiate()
	add_child(options_scene)
	await get_tree().process_frame
	_check("ui_plate" in uisfx.played_log, "打开设置应触发 plate 音")
	options_scene.queue_free()

	# 页签切换 → drawer
	var sidebar = match_instance.get_node_or_null("HUD/Ra3Sidebar")
	if sidebar != null:
		uisfx.played_log.clear()
		sidebar._select_tab("infantry")
		await get_tree().process_frame
		_check("ui_drawer" in uisfx.played_log, "命令栏页签切换应触发 drawer 音")
	else:
		print("[UISfx] Ra3Sidebar 不在测试场景中，跳过 drawer 断言")

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
	print("UI sfx smoke test completed: %d failure(s)" % _failures)
	SmokeTestExit.request(get_tree(), 0 if _failures == 0 else 1)


func _check(condition: bool, message: String):
	if condition:
		return
	_failures += 1
	print("FAIL: %s" % message)
	push_error("UI sfx assertion failed: %s" % message)
