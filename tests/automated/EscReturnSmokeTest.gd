extends Node

## ESC 返回冒烟测试（2026-09-08 用户要求：游戏内暂停/设置页按 ESC 能逐级返回）：
## 1) 打开暂停菜单 → 打开设置面板；
## 2) 注入真实 ESC 按键事件 → 应关闭设置面板回到暂停菜单；
## 3) 再注入 ESC → 应回到对局（菜单关闭、解除暂停）。
## 说明：打开动作用直接调用（测的是"关闭"链路）；关闭必须走真实输入事件，
## 经 InputBindingRuntime(C#) 解析 global.cancel → Menu._cancel_or_return 全链路。

const MatchScene = preload("res://tests/manual/TestAllUnits.tscn")

var _failures := 0
var _finished := false


func _ready():
	get_tree().create_timer(60.0).timeout.connect(_on_failsafe)
	var match_instance = MatchScene.instantiate()
	add_child(match_instance)
	await get_tree().process_frame
	await get_tree().create_timer(0.5).timeout

	var menu = match_instance.get_node_or_null("Menu")
	_check(menu != null, "对局应包含 Menu 节点")
	var runtime = match_instance.get_node_or_null("InputBindingRuntime")
	_check(runtime != null, "对局应包含 InputBindingRuntime 节点")
	if menu == null or runtime == null:
		_finish()
		return

	menu._open()
	_check(menu.visible and get_tree().paused, "菜单打开后应处于暂停状态")
	menu._on_settings_button_pressed()
	_check(menu._options_panel != null, "设置面板应已打开")

	_press_escape()
	await _settle()
	_check(
		menu._options_panel == null and menu.visible,
		"第一次 ESC 应关闭设置面板并回到暂停菜单（实际 panel=%s visible=%s）"
			% [menu._options_panel, menu.visible]
	)

	_press_escape()
	await _settle()
	_check(
		not menu.visible and not get_tree().paused,
		"第二次 ESC 应回到对局（实际 visible=%s paused=%s）" % [menu.visible, get_tree().paused]
	)

	_finish()


func _press_escape():
	var ev := InputEventKey.new()
	ev.physical_keycode = KEY_ESCAPE
	ev.keycode = KEY_ESCAPE
	ev.pressed = true
	Input.parse_input_event(ev)
	var release := InputEventKey.new()
	release.physical_keycode = KEY_ESCAPE
	release.keycode = KEY_ESCAPE
	release.pressed = false
	Input.parse_input_event(release)


func _settle():
	await get_tree().process_frame
	await get_tree().process_frame
	await get_tree().create_timer(0.2).timeout


func _on_failsafe():
	if _finished:
		return
	print("FAIL: 看门狗超时——测试协程中断未收尾")
	_finish()


func _finish():
	if _finished:
		return
	_finished = true
	if get_tree().paused:
		get_tree().paused = false
	print("ESC return smoke test completed: %d failure(s)" % _failures)
	SmokeTestExit.request(get_tree(), 0 if _failures == 0 else 1)


func _check(condition: bool, message: String):
	if condition:
		print("  [PASS] %s" % message)
		return
	_failures += 1
	print("FAIL: %s" % message)
