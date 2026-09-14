extends Node

const MatchScene = preload("res://tests/manual/TestOneUnit.tscn")

var _failures := 0


func _ready():
	var match_instance = MatchScene.instantiate()
	add_child(match_instance)
	await get_tree().process_frame

	# HUD 由 Match._ready() 构建，大地图生成会 await 若干帧 ⇒ 不能只等一帧就读节点，
	# 否则读到的是空 HUD、断言全部落空（2026-09-14 修复）。
	var hud = null
	var deadline := Time.get_ticks_msec() + 20000
	while Time.get_ticks_msec() < deadline:
		hud = match_instance.find_child("AICommandHUD", true, false)
		if hud != null:
			break
		await get_tree().process_frame
	await get_tree().create_timer(0.3).timeout
	var toggle = match_instance.find_child("AICommandHUDToggle", true, false)
	# RA3 布局下命令面板被侧栏 absorb_command_panel() 收编，不再是 HUD 直接子节点。
	var command_hud = match_instance.find_child("TraditionalUnitCommandHUD", true, false)
	var input_runtime = match_instance.get_node("InputBindingRuntime")
	_check(hud != null, "AI 副官 HUD 应存在（等待 HUD 就绪后仍取不到）")
	_check(toggle != null, "应能找到 AI 副官开关按钮")
	_check(
		command_hud != null,
		"传统命令栏应存在（RA3 布局下被侧栏收编，用 find_child 而非 HUD 直接子节点）"
	)
	if hud == null or toggle == null or command_hud == null:
		print("Legacy HUD visibility smoke test aborted: HUD 未就绪 (%d failure(s))" % _failures)
		SmokeTestExit.request(get_tree(), 1)
		return
	_check(not hud.is_interface_visible(), "AI 副官 HUD 应默认隐藏")
	_check(command_hud.visible, "默认应显示传统命令栏")
	_check(toggle.text == "显示 AI 副官", "默认按钮文字错误")
	_check(not input_runtime.IsContextActive("LegacyAgent"), "隐藏时不应启用 AI 快捷键上下文")

	input_runtime.emit_signal("ActionPressed", "global.toggle_ai_hud")
	_check(hud.is_interface_visible(), "Tab 应显示 AI 副官 HUD")
	_check(not command_hud.visible, "打开 AI 副官后应隐藏传统命令栏")
	_check(toggle.text == "隐藏 AI 副官", "显示后的按钮文字错误")
	_check(input_runtime.IsContextActive("LegacyAgent"), "显示时应恢复 AI 快捷键上下文")
	_check(str(input_runtime.GetBinding("legacy.command_move")) == "U", "副官移动默认键应为 U")
	_check(str(input_runtime.GetBinding("legacy.command_attack")) == "I", "副官攻击默认键应为 I")
	_check(str(input_runtime.GetBinding("legacy.command_defend")) == "O", "副官防守默认键应为 O")
	_check(str(input_runtime.GetBinding("legacy.command_scout")) == "P", "副官侦察默认键应为 P")
	_check(str(input_runtime.GetBinding("legacy.command_retreat")) == "J", "副官撤退默认键应为 J")
	_check(str(input_runtime.GetBinding("legacy.command_stop")) == "K", "副官停止默认键应为 K")
	var tank = match_instance.get_node("Players/Human/Tank")
	tank.add_to_group("controlled_units")
	tank.add_to_group("legacy_ai_squad_1")
	input_runtime.emit_signal("ActionPressed", "legacy.command_move")
	_check(hud.pending_command == "MOVE", "U 对应动作应进入移动命令")
	var command_buttons = hud.get("_command_buttons")
	_check(command_buttons != null and command_buttons.size() > 0, "AI 副官应有命令按钮")
	if command_buttons != null and command_buttons.size() > 0:
		var move_button_text := str(command_buttons[0].button.text)
		_check(
			move_button_text.contains("U") and move_button_text.contains("移动"),
			"副官移动按钮应显示 U"
		)

	hud.pending_command = "MOVE"
	input_runtime.emit_signal("ActionPressed", "global.toggle_ai_hud")
	_check(not hud.is_interface_visible(), "再次按 Tab 应返回普通 RTS HUD")
	_check(command_hud.visible, "退出 AI 副官后应重新显示传统命令栏")
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
