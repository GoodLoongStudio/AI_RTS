extends Node

const MatchScene = preload("res://tests/manual/TestOneUnit.tscn")

var _failures := 0


func _ready():
	var match_instance = MatchScene.instantiate()
	add_child(match_instance)
	await get_tree().process_frame

	var hud = match_instance.get_node("HUD/AICommandHUD")
	var toggle = match_instance.get_node("HUD/AICommandHUDToggle")
	_check(not hud.is_interface_visible(), "AI 副官 HUD 应默认隐藏")
	_check(not hud.is_processing_unhandled_key_input(), "隐藏时不应处理 AI 快捷键")
	_check(toggle.text == "显示 AI 副官", "默认按钮文字错误")

	toggle.pressed.emit()
	_check(hud.is_interface_visible(), "点击按钮后应显示 AI 副官 HUD")
	_check(hud.is_processing_unhandled_key_input(), "显示时应恢复 AI 快捷键处理")
	_check(toggle.text == "隐藏 AI 副官", "显示后的按钮文字错误")

	hud.pending_command = "MOVE"
	toggle.pressed.emit()
	_check(not hud.is_interface_visible(), "再次点击后应隐藏 AI 副官 HUD")
	_check(not hud.is_processing_unhandled_key_input(), "再次隐藏后应停止处理 AI 快捷键")
	_check(hud.pending_command.is_empty(), "隐藏时应取消尚未确认的 AI 命令")

	print("Legacy HUD visibility smoke test completed: %d failure(s)" % _failures)
	match_instance.queue_free()
	await get_tree().process_frame
	get_tree().quit(0 if _failures == 0 else 1)


func _check(condition: bool, message: String):
	if condition:
		return
	_failures += 1
	push_error("Legacy HUD visibility assertion failed: %s" % message)
