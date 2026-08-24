extends Node

const MatchScene = preload("res://tests/manual/TestOneUnit.tscn")

var _failures := 0


func _ready():
	var match_instance = MatchScene.instantiate()
	add_child(match_instance)
	await get_tree().process_frame

	var hud = match_instance.get_node("HUD/AICommandHUD")
	var toggle = match_instance.get_node("HUD/AICommandHUDToggle")
	var input_runtime = match_instance.get_node("InputBindingRuntime")
	_check(not hud.is_interface_visible(), "AI 副官 HUD 应默认隐藏")
	_check(toggle.text == "显示 AI 副官", "默认按钮文字错误")
	_check(not input_runtime.IsContextActive("LegacyAgent"), "隐藏时不应启用 AI 快捷键上下文")

	input_runtime.emit_signal("ActionPressed", "global.toggle_ai_hud")
	_check(hud.is_interface_visible(), "Tab 应显示 AI 副官 HUD")
	_check(toggle.text == "隐藏 AI 副官", "显示后的按钮文字错误")
	_check(input_runtime.IsContextActive("LegacyAgent"), "显示时应恢复 AI 快捷键上下文")

	hud.pending_command = "MOVE"
	input_runtime.emit_signal("ActionPressed", "global.toggle_ai_hud")
	_check(not hud.is_interface_visible(), "再次按 Tab 应返回普通 RTS HUD")
	_check(hud.pending_command.is_empty(), "隐藏时应取消尚未确认的 AI 命令")
	_check(not input_runtime.IsContextActive("LegacyAgent"), "再次隐藏后应关闭 AI 快捷键上下文")

	toggle.pressed.emit()
	_check(hud.is_interface_visible(), "按钮仍可作为 Tab 的辅助入口")
	toggle.pressed.emit()
	_check(not hud.is_interface_visible(), "按钮再次点击应隐藏 AI 副官 HUD")

	print("Legacy HUD visibility smoke test completed: %d failure(s)" % _failures)
	match_instance.queue_free()
	await get_tree().process_frame
	SmokeTestExit.request(get_tree(), 0 if _failures == 0 else 1)
func _check(condition: bool, message: String):
	if condition:
		return
	_failures += 1
	push_error("Legacy HUD visibility assertion failed: %s" % message)
