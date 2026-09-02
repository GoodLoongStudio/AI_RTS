extends Node

const MatchScene = preload("res://tests/manual/TestOneUnit.tscn")
const CommandCenterScene = preload("res://source/match/units/CommandCenter.tscn")
const Moving = preload("res://source/match/units/actions/Moving.gd")

var _failures := 0


func _ready():
	var match_instance = MatchScene.instantiate()
	add_child(match_instance)
	await get_tree().process_frame
	await get_tree().process_frame

	var human = match_instance.get_node("Players/Human")
	var tank = human.get_node("Tank")
	# ReturnToBase requires a completed friendly CommandCenter; add one only to this
	# HUD fixture so the command can be verified without changing the shared manual scene.
	var command_center = CommandCenterScene.instantiate()
	var command_center_transform := Transform3D(
		Basis.IDENTITY, tank.global_position + Vector3(-4.0, 0.0, 0.0)
	)
	match_instance._setup_and_spawn_unit(command_center, command_center_transform, human, false)
	await get_tree().process_frame
	var hud = match_instance.get_node_or_null("HUD/TraditionalUnitCommandHUD")
	_check(hud != null, "传统单位命令栏应随 Human 创建")

	var selection = tank.find_child("Selection")
	selection.select()
	await get_tree().process_frame
	_check(not tank.is_in_group("legacy_ai_squad_1"), "测试 Tank 不应依赖 AI 副官作战小队")
	var force_move_button = hud.get_node("MarginContainer/VBoxContainer/Buttons/ForceMoveButton")
	var halt_button = hud.get_node("MarginContainer/VBoxContainer/Buttons/HaltButton")
	var force_attack_button = hud.get_node(
		"MarginContainer/VBoxContainer/Buttons/ForceAttackButton"
	)
	var tactical_withdraw_button = hud.get_node(
		"MarginContainer/VBoxContainer/Buttons/TacticalWithdrawButton"
	)
	var ground_attack_move_button = hud.get_node(
		"MarginContainer/VBoxContainer/Buttons/GroundAttackMoveButton"
	)
	var aggressive_button = hud.get_node(
		"MarginContainer/VBoxContainer/CombatPolicies/AggressiveButton"
	)
	var guard_button = hud.get_node("MarginContainer/VBoxContainer/CombatPolicies/GuardButton")
	var hold_ground_button = hud.get_node(
		"MarginContainer/VBoxContainer/CombatPolicies/HoldGroundButton"
	)
	var return_to_base_button = hud.get_node(
		"MarginContainer/VBoxContainer/CombatPolicies/ReturnToBaseButton"
	)
	var hold_fire_button = hud.get_node(
		"MarginContainer/VBoxContainer/CombatPolicies/HoldFireButton"
	)
	var feedback_label = hud.get_node("MarginContainer/VBoxContainer/FeedbackLabel")
	var input_runtime = match_instance.get_node("InputBindingRuntime")
	_check(not force_move_button.disabled, "选中 Tank 后强制移动按钮应可用")
	_check(not halt_button.disabled, "选中 Tank 后停止按钮应可用")
	_check(not force_attack_button.disabled, "选中 Tank 后强制攻击按钮应可用")
	_check(not tactical_withdraw_button.disabled, "选中 Tank 后战术后退按钮应可用")
	_check(not ground_attack_move_button.disabled, "选中 Tank 后移动并攻击按钮应可用")
	_check(not return_to_base_button.disabled, "选中 Tank 后撤回基地姿态按钮应可用")
	input_runtime.emit_signal("ActionPressed", "unit.attack_move")
	_check(
		"地面或敌方单位" in feedback_label.text,
		"R 快捷键应进入地面或敌方单位目标确认状态"
	)
	ground_attack_move_button.pressed.emit()
	_check(ground_attack_move_button.text.begins_with("移动并攻击"), "再次点击应取消移动并攻击目标确认")
	_check("[R]" in ground_attack_move_button.text, "移动并攻击应显示 R 键")
	_check("[C]" in force_move_button.text, "强制移动应显示 C 键")
	_check("[X]" in force_attack_button.text, "强制攻击应显示 X 键")
	_check("战术后退" in tactical_withdraw_button.text, "Z 应显示为战术后退")
	_check("[Z]" in tactical_withdraw_button.text, "战术后退应显示 Z 键")
	_check("[G]" in hold_ground_button.text, "固守应显示 G 键")
	_check("[T]" in aggressive_button.text, "侵略应显示 T 键")
	_check("[Y]" in guard_button.text, "警戒应显示 Y 键")
	_check("撤回基地" in return_to_base_button.text, "撤回基地姿态应显示中文名称")
	_check("[V]" in return_to_base_button.text, "撤回基地姿态应显示 V 键")
	_check("[H]" in hold_fire_button.text, "停火应显示 H 键")
	_check("[B]" in hud.get_node("MarginContainer/VBoxContainer/CombatPolicies/ClearRallyPointButton").text,
		"清除集结应显示 B 键")
	_check(not "[" in halt_button.text, "停止移动没有独立快捷键，不得误标 F")
	tactical_withdraw_button.pressed.emit()
	_check("战术后退目的地" in feedback_label.text, "Z 应进入一次性战术后退目标确认状态")
	tactical_withdraw_button.pressed.emit()
	_check(tactical_withdraw_button.text.begins_with("战术后退"), "再次点击战术后退应取消目标确认")
	force_attack_button.pressed.emit()
	_check("单位或地面" in feedback_label.text, "强制攻击应进入一次性目标确认状态")
	force_attack_button.pressed.emit()
	_check(force_attack_button.text.begins_with("强制攻击"), "再次点击强制攻击应取消目标确认")
	_check(aggressive_button.button_pressed, "Tank 默认应显示侵略姿态")
	_check(not hold_fire_button.button_pressed, "Tank 默认应显示自由开火")
	return_to_base_button.pressed.emit()
	await get_tree().process_frame
	_check(return_to_base_button.button_pressed, "点击撤回基地姿态应选中该姿态")
	_check(
		human.get_node("UnitCommandGateway").GetEngagementStance(tank) == "ReturnToBase",
		"HUD 应设置撤回基地姿态"
	)
	input_runtime.emit_signal("ActionPressed", "unit.stance_return_to_base")
	await get_tree().process_frame
	_check(return_to_base_button.button_pressed, "V 快捷键应保持撤回基地姿态")

	guard_button.pressed.emit()
	await get_tree().process_frame
	_check(guard_button.button_pressed, "警戒按钮应反映权威姿态")
	_check(human.get_node("UnitCommandGateway").GetEngagementStance(tank) == "Guard", "HUD 应设置警戒姿态")
	input_runtime.emit_signal("ActionPressed", "unit.stance_aggressive")
	await get_tree().process_frame
	_check(aggressive_button.button_pressed, "T 快捷键应把姿态设为侵略")
	input_runtime.emit_signal("ActionPressed", "unit.stance_guard")
	await get_tree().process_frame
	_check(guard_button.button_pressed, "Y 快捷键应把姿态设为警戒")
	input_runtime.emit_signal("ActionPressed", "unit.stance_hold_ground")
	await get_tree().process_frame
	_check(hold_ground_button.button_pressed, "G 快捷键应把姿态设为固守")
	input_runtime.emit_signal("ActionPressed", "unit.toggle_hold_fire")
	await get_tree().process_frame
	_check(hold_fire_button.button_pressed, "H 快捷键应切换为停火")
	_check(human.get_node("UnitCommandGateway").GetFirePolicy(tank) == "HoldFire", "HUD 应设置停火")
	hold_fire_button.pressed.emit()
	await get_tree().process_frame
	_check(not hold_fire_button.button_pressed, "再次点击停火应恢复自由开火")

	input_runtime.emit_signal("ActionPressed", "unit.force_move")
	_check("右键地面" in feedback_label.text, "C 快捷键应进入一次性目标确认状态")
	MatchSignals.terrain_targeted.emit(tank.global_position + Vector3(3.0, 0.0, 0.0))
	await get_tree().process_frame
	_check(tank.action != null and tank.action.get_script() == Moving, "HUD 强制移动应驱动 Tank")
	_check("接受 1" in feedback_label.text, "HUD 应显示强制移动即时接受数量")

	halt_button.pressed.emit()
	await get_tree().process_frame
	_check(tank.action == null or tank.action.get_script() != Moving, "停止移动按钮应终止 Tank 位移")
	_check("停止移动" in feedback_label.text, "停止移动按钮应调用 HaltMovement 而不是完整 Stop")
	_check("接受 1" in feedback_label.text, "停止移动应显示即时接受数量")
	_check(
		human.get_node("UnitCommandGateway").GetActiveOrderState(tank) == "Suspended",
		"停止移动后强制移动订单应暂停而不是取消"
	)

	# HaltMovement 是幂等命令：再次停止待机 Tank 仍应被接受，且不得清除其他 Action。
	var action_before_repeated_halt = tank.action
	halt_button.pressed.emit()
	await get_tree().process_frame
	_check("停止移动" in feedback_label.text, "重复停止移动仍应反馈 HaltMovement")
	_check("接受 1" in feedback_label.text, "重复停止移动应作为已接受的无操作反馈")
	_check(tank.action == action_before_repeated_halt, "重复停止移动不得清除待机或攻击 Action")

	input_runtime.emit_signal("ActionPressed", "unit.force_move")
	MatchSignals.terrain_targeted.emit(tank.global_position + Vector3(-3.0, 0.0, 0.0))
	await get_tree().process_frame
	input_runtime.emit_signal("ActionPressed", "unit.stop")
	await get_tree().process_frame
	_check(tank.action == null or tank.action.get_script() != Moving, "F 快捷键仍应执行完整停止")
	_check("停止：" in feedback_label.text, "F 应反馈完整 Stop 而不是停止移动")

	var controller = human.get_node("UnitActionsController")
	input_runtime.emit_signal("ActionPressed", "unit.tactical_withdraw")
	_check(controller.get_active_command_targeting() == "TacticalWithdraw", "Z 应进入战术后退选目标")
	var action_before_invalid_withdraw = tank.action
	MatchSignals.unit_targeted.emit(tank, tank.global_position)
	await get_tree().process_frame
	_check(
		controller.get_active_command_targeting() == "TacticalWithdraw",
		"战术后退点单位应拒绝并保持选目标"
	)
	_check(tank.action == action_before_invalid_withdraw, "战术后退点单位不得偷偷改成跟随或移动")
	_check("拒绝" in feedback_label.text, "非法战术后退目标应明确拒绝")
	MatchSignals.terrain_targeted.emit(tank.global_position + Vector3(0.0, 0.0, 4.0))
	await get_tree().process_frame
	_check(controller.get_active_command_targeting() == "", "右键地面后应退出战术后退选目标")
	_check("接受 1" in feedback_label.text, "地面战术后退应被接受")

	print("Traditional unit command HUD smoke test completed: %d failure(s)" % _failures)
	match_instance.queue_free()
	await get_tree().process_frame
	SmokeTestExit.request(get_tree(), 0 if _failures == 0 else 1)


func _check(condition: bool, message: String):
	if condition:
		return
	_failures += 1
	push_error("Traditional unit command HUD assertion failed: %s" % message)
