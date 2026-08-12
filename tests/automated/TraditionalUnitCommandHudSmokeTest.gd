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
	_check(not tank.is_in_group("unit_group_1"), "测试 Tank 不应依赖 AI 副官作战小队")
	var force_move_button = hud.get_node("MarginContainer/VBoxContainer/Buttons/ForceMoveButton")
	var halt_button = hud.get_node("MarginContainer/VBoxContainer/Buttons/HaltButton")
	var feedback_label = hud.get_node("MarginContainer/VBoxContainer/FeedbackLabel")
	_check(not force_move_button.disabled, "选中 Tank 后强制移动按钮应可用")
	_check(not halt_button.disabled, "选中 Tank 后停止按钮应可用")

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
