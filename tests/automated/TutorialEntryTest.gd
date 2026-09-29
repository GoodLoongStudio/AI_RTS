extends Node

## 教学入口冒烟测试（2026-09-27 用户要求）：
## 暂停菜单含「教学」按钮 → 点击打开教学页（快捷键总览图已加载）→
## ESC（global.cancel）关闭教学页回到暂停菜单 → 再 ESC 回到游戏。

const MatchSettings = preload("res://source/data-model/MatchSettings.gd")

var _failures := 0


func _check(cond: bool, msg: String) -> void:
	if cond:
		print("[PASS] " + msg)
	else:
		_failures += 1
		print("[FAIL] " + msg)


func _ready():
	await get_tree().process_frame
	await get_tree().process_frame

	var settings = MatchSettings.new()
	var human = load("res://source/data-model/PlayerSettings.gd").new()
	human.controller = Constants.PlayerType.HUMAN
	human.color = Color.BLUE
	settings.players.append(human)
	var ai = load("res://source/data-model/PlayerSettings.gd").new()
	ai.controller = Constants.PlayerType.SIMPLE_CLAIRVOYANT_AI
	ai.color = Color.RED
	settings.players.append(ai)
	settings.visible_player = 0
	settings.visibility = MatchSettings.Visibility.PER_PLAYER

	var a_match = load("res://source/match/Match.tscn").instantiate()
	a_match.settings = settings
	a_match.map = load("res://source/match/maps/PlainAndSimple.tscn").instantiate()
	get_tree().root.add_child(a_match)

	var deadline := Time.get_ticks_msec() + 90000
	var ready := false
	while Time.get_ticks_msec() < deadline:
		await get_tree().physics_frame
		var players: Node = a_match.get_node_or_null("Players")
		if players != null and players.get_child_count() >= 2:
			var ok := true
			for p in players.get_children():
				if p.get_child_count() == 0:
					ok = false
			if ok:
				ready = true
				break
	_check(ready, "对局应就绪")
	if not ready:
		_finish()
		return

	var menu: CanvasLayer = a_match.get_node_or_null("Menu")
	_check(menu != null, "对局应有暂停菜单")
	if menu == null:
		_finish()
		return
	menu._open()
	await get_tree().process_frame
	_check(menu.visible, "暂停菜单应打开")

	var button: Button = menu.get_node_or_null(
		"CenterContainer/PanelContainer/MarginContainer/VBoxContainer/TutorialButton") as Button
	_check(button != null, "暂停菜单应有「教学」按钮")
	_check(button != null and button.text == "教学", "按钮文案应为「教学」")
	if button == null:
		_finish()
		return

	# 点击「教学」→ 打开教学页
	button.pressed.emit()
	await get_tree().process_frame
	var tutorial: Control = menu.get("_tutorial_panel")
	_check(tutorial != null, "点击后应打开教学页")
	_check(not menu.get_node("CenterContainer").visible,
		"教学页打开时暂停菜单主体应隐藏")
	if tutorial != null:
		var sheet: TextureRect = tutorial.find_child("Sheet", true, false) as TextureRect
		_check(sheet != null and sheet.texture != null,
			"教学页应加载快捷键总览图")
		_check(tutorial.find_child("BackButton", true, false) != null,
			"教学页应有返回按钮")

	# ESC（global.cancel）→ 关教学页、回到暂停菜单
	menu._on_input_action_pressed("global.cancel")
	await get_tree().process_frame
	_check(menu.get("_tutorial_panel") == null, "ESC 后教学页应关闭")
	_check(menu.get_node("CenterContainer").visible, "关闭教学页后暂停菜单主体应还原")
	_check(menu.visible, "暂停菜单应仍打开（回到暂停菜单而非退出）")

	# 再点开再 ESC 一轮，确认可反复进出
	var button2: Button = menu.get_node(
		"CenterContainer/PanelContainer/MarginContainer/VBoxContainer/TutorialButton") as Button
	button2.pressed.emit()
	await get_tree().process_frame
	_check(menu.get("_tutorial_panel") != null, "可再次打开教学页")
	menu._on_input_action_pressed("global.cancel")
	await get_tree().process_frame
	_check(menu.get("_tutorial_panel") == null, "再次 ESC 后教学页应关闭")

	# 收尾：关闭菜单，恢复暂停状态
	menu._close()
	await get_tree().process_frame
	_check(not menu.visible, "收尾：暂停菜单应关闭")

	_finish()


func _finish() -> void:
	if _failures == 0:
		print("Tutorial entry: 0 failure(s)")
		get_tree().quit(0)
	else:
		print("Tutorial entry: %d failure(s)" % _failures)
		get_tree().quit(1)
