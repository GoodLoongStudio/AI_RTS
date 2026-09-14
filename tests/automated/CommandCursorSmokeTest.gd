extends Node

## 命令光标冒烟测试（2026-09-14，红警式维修/出售交互）：
## 验证「命令指定模式 → 换自定义光标 → 退出模式 → 恢复默认」这条表现层链路，
## 以及维修/出售图标资源真实存在且能作为 Texture2D 加载。
##
## 说明：headless 下系统光标本身不可见，这里断言的是状态的正确性与资源可加载性；
## 真实光标外观由实机验收。注意本测试不依赖对局 HUD（headless 不挂 HUD）。

const CommandCursorScript = preload("res://source/match/hud/CommandCursor.gd")
const ICON_DIR := "res://assets/ui/cursors/"

var _failures := 0
var _finished := false


func _ready():
	get_tree().create_timer(30.0).timeout.connect(_on_failsafe)
	await _run()


func _run():
	# 1) 图标资源必须存在且是 Texture2D
	for filename in ["cursor_repair.png", "cursor_sell.png"]:
		var path := ICON_DIR + str(filename)
		_check(ResourceLoader.exists(path), "光标图标应存在: %s" % path)
		if ResourceLoader.exists(path):
			var texture := load(path) as Texture2D
			_check(texture != null, "光标图标应能加载为 Texture2D: %s" % path)
			if texture != null:
				_check(
					texture.get_width() > 0 and texture.get_height() > 0,
					"光标图标尺寸应有效: %s" % path
				)

	# 2) 指定模式 → 换光标
	var cursor = CommandCursorScript.new()
	cursor.name = "CommandCursorTest"
	add_child(cursor)
	await get_tree().process_frame
	_check(cursor.get_active_command() == "", "初始不应处于任何指定模式")

	MatchSignals.command_targeting_changed.emit("Repair")
	await get_tree().process_frame
	_check(cursor.get_active_command() == "Repair", "维修模式应切到维修光标")
	_check(cursor.has_custom_cursor(), "维修光标纹理应可加载")

	# 3) 模式之间直接切换
	MatchSignals.command_targeting_changed.emit("Sell")
	await get_tree().process_frame
	_check(cursor.get_active_command() == "Sell", "出售模式应切到出售光标")

	# 4) 未配置光标的命令不应误改（例如强制移动）
	MatchSignals.command_targeting_changed.emit("ForceMove")
	await get_tree().process_frame
	_check(cursor.get_active_command() == "ForceMove", "未配置图标的命令仍应记录模式名")
	_check(not cursor.has_custom_cursor(), "未配置图标的命令不应设置自定义光标")

	# 5) 退出指定模式 → 恢复默认光标
	MatchSignals.command_targeting_changed.emit("")
	await get_tree().process_frame
	_check(cursor.get_active_command() == "", "退出模式后应恢复默认光标")
	_check(not cursor.has_custom_cursor(), "退出模式后不应再持有自定义光标")

	# 6) 对局结束也要恢复（避免把光标带回主菜单）
	MatchSignals.command_targeting_changed.emit("Sell")
	await get_tree().process_frame
	MatchSignals.match_aborted.emit()
	await get_tree().process_frame
	_check(cursor.get_active_command() == "", "对局中断后应恢复默认光标")

	cursor.queue_free()
	_finish()


func _on_failsafe():
	if _finished:
		return
	_finished = true
	print("FAIL: 看门狗超时——测试协程中断未收尾")
	print("Command cursor smoke test completed: %d failure(s)" % _failures)
	SmokeTestExit.request(get_tree(), 1)


func _finish():
	if _finished:
		return
	_finished = true
	print("Command cursor smoke test completed: %d failure(s)" % _failures)
	SmokeTestExit.request(get_tree(), 0 if _failures == 0 else 1)


func _check(condition: bool, message: String):
	if condition:
		return
	_failures += 1
	print("FAIL: %s" % message)
	push_error("Command cursor smoke test assertion failed: %s" % message)
