extends Node

const MatchScene = preload("res://tests/manual/TestOneUnit.tscn")
const Moving = preload("res://source/match/units/actions/Moving.gd")

var _failures := 0


func _ready():
	var match_instance = MatchScene.instantiate()
	add_child(match_instance)
	await get_tree().process_frame
	await get_tree().process_frame

	var human = match_instance.get_node("Players/Human")
	var tank = human.get_node("Tank")
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
	var hold_fire_button = hud.get_node(
		"MarginContainer/VBoxContainer/CombatPolicies/HoldFireButton"
	)
	var feedback_label = hud.get_node("MarginContainer/VBoxContainer/FeedbackLabel")
	_check(not force_move_button.disabled, "选中 Tank 后强制移动按钮应可用")
	_check(not halt_button.disabled, "选中 Tank 后停止按钮应可用")
	_check(not force_attack_button.disabled, "选中 Tank 后强制攻击按钮应可用")
	_check(not tactical_withdraw_button.disabled, "选中 Tank 后撤退按钮应可用")
	_check(not ground_attack_move_button.disabled, "选中 Tank 后移动并攻击按钮应可用")
	ground_attack_move_button.pressed.emit()
	_check(
		"地面或敌方单位" in feedback_label.text,
		"移动并攻击应进入地面或敌方单位目标确认状态"
	)
	ground_attack_move_button.pressed.emit()
	_check(ground_attack_move_button.text == "移动并攻击", "再次点击应取消移动并攻击目标确认")
	tactical_withdraw_button.pressed.emit()
	_check("撤退目的地" in feedback_label.text, "撤退应进入一次性地面目标确认状态")
	tactical_withdraw_button.pressed.emit()
	_check(tactical_withdraw_button.text == "撤退", "再次点击撤退应取消目标确认")
	force_attack_button.pressed.emit()
	_check("单位或地面" in feedback_label.text, "强制攻击应进入一次性目标确认状态")
	force_attack_button.pressed.emit()
	_check(force_attack_button.text == "强制攻击", "再次点击强制攻击应取消目标确认")
	_check(aggressive_button.button_pressed, "Tank 默认应显示侵略姿态")
	_check(not hold_fire_button.button_pressed, "Tank 默认应显示自由开火")

	guard_button.pressed.emit()
	await get_tree().process_frame
	_check(guard_button.button_pressed, "警戒按钮应反映权威姿态")
	_check(human.get_node("UnitCommandGateway").GetEngagementStance(tank) == "Guard", "HUD 应设置警戒姿态")
	hold_ground_button.pressed.emit()
	await get_tree().process_frame
	_check(hold_ground_button.button_pressed, "固守按钮应反映权威姿态")
	hold_fire_button.pressed.emit()
	await get_tree().process_frame
	_check(hold_fire_button.button_pressed, "停火按钮应反映权威开火策略")
	_check(human.get_node("UnitCommandGateway").GetFirePolicy(tank) == "HoldFire", "HUD 应设置停火")
	hold_fire_button.pressed.emit()
	await get_tree().process_frame
	_check(not hold_fire_button.button_pressed, "再次点击停火应恢复自由开火")

	force_move_button.pressed.emit()
	_check("右键地面" in feedback_label.text, "强制移动应进入一次性目标确认状态")
	MatchSignals.terrain_targeted.emit(tank.global_position + Vector3(3.0, 0.0, 0.0))
	await get_tree().process_frame
	_check(tank.action != null and tank.action.get_script() == Moving, "HUD 强制移动应驱动 Tank")
	_check("接受 1" in feedback_label.text, "HUD 应显示强制移动即时接受数量")

	halt_button.pressed.emit()
	await get_tree().process_frame
	_check(tank.action == null or tank.action.get_script() != Moving, "HUD 停止应终止未编队 Tank 的移动")
	_check("接受 1" in feedback_label.text, "HUD 应显示停止移动即时接受数量")

	# HaltMovement 是幂等命令：再次停止待机 Tank 仍应被接受，且不得清除其他 Action。
	var action_before_repeated_halt = tank.action
	halt_button.pressed.emit()
	await get_tree().process_frame
	_check("接受 1" in feedback_label.text, "重复停止应作为已接受的无操作反馈")
	_check(tank.action == action_before_repeated_halt, "重复停止不得清除待机或攻击 Action")

	print("Traditional unit command HUD smoke test completed: %d failure(s)" % _failures)
	match_instance.queue_free()
	await get_tree().process_frame
	get_tree().quit(0 if _failures == 0 else 1)


func _check(condition: bool, message: String):
	if condition:
		return
	_failures += 1
	push_error("Traditional unit command HUD assertion failed: %s" % message)
