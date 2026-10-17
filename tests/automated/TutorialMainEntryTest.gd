extends Node

## 首页「教学」入口验证（2026-09-27 用户要求首页也放同一个教学入口）。
## 在**干净进程**里跑：先起 Main.tscn（主菜单真实场景），点「教学」→
## 换到教学页 → 总览图加载 → ESC/返回 回首页。
## 不在 TutorialEntryTest 里做：那个进程挂着 Match，主菜单的自动随机地图
## 生成任务会把进程拖住。
const TutorialScript = preload("res://source/match/TutorialPage.gd")

var _failures := 0


func _check(cond: bool, msg: String) -> void:
	if cond:
		print("[PASS] " + msg)
	else:
		_failures += 1
		print("[FAIL] " + msg)


func _ready():
	await get_tree().process_frame
	var main_scene = load("res://source/main-menu/Main.tscn").instantiate()
	get_tree().root.add_child(main_scene)
	get_tree().current_scene = main_scene
	for _i in range(4):
		await get_tree().process_frame

	var button: Button = main_scene.get_node_or_null(
		"CenterContainer/PanelContainer/MarginContainer/VBoxContainer/TutorialButton") as Button
	_check(button != null, "首页应有「教学」按钮")
	_check(button != null and button.text == "教学", "首页按钮文案应为「教学」")
	if button == null:
		_finish()
		return
	# 「教学」在「地图生成」与「设置」之间（用户截图里红线指的是地图生成下方）
	_check(button.get_index() > main_scene.get_node(
		"CenterContainer/PanelContainer/MarginContainer/VBoxContainer/MapGenButton").get_index(),
		"「教学」应排在地图生成之后")
	_check(button.get_index() < main_scene.get_node(
		"CenterContainer/PanelContainer/MarginContainer/VBoxContainer/OptionsButton").get_index(),
		"「教学」应排在设置之前")

	button.pressed.emit()
	for _i in range(6):
		await get_tree().process_frame
	var tutorial: Node = get_tree().current_scene
	_check(tutorial != null and tutorial.get_script() == TutorialScript,
		"点首页教学应切换到教学页场景")
	if tutorial == null or tutorial.get_script() != TutorialScript:
		_finish()
		return
	var sheet: TextureRect = tutorial.find_child("Sheet", true, false) as TextureRect
	_check(sheet != null and sheet.texture != null, "首页教学页应加载快捷键总览图")
	_check(not bool(tutorial.get("embedded_mode")),
		"首页教学页应为非嵌入模式（ESC 回首页，不回暂停菜单）")
	_check(tutorial.find_child("BackButton", true, false) != null,
		"首页教学页应有返回按钮")

	# ESC → 回首页（非嵌入分支 = change_scene 回 Main.tscn）
	tutorial.call("_on_escape")
	for _i in range(6):
		await get_tree().process_frame
	_check(get_tree().current_scene != null
		and str(get_tree().current_scene.scene_file_path).find("main-menu/Main") >= 0,
		"ESC 后应回到首页")

	_finish()


func _finish() -> void:
	if _failures == 0:
		print("Tutorial main entry: 0 failure(s)")
		get_tree().quit(0)
	else:
		print("Tutorial main entry: %d failure(s)" % _failures)
		get_tree().quit(1)
