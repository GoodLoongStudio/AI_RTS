extends Node

const MatchScene = preload("res://tests/manual/TestHelicopterCommands.tscn")
const Moving = preload("res://source/match/units/actions/Moving.gd")

var _failures := 0
var _order_events: Array[Dictionary] = []
var _feedback_events: Array[Dictionary] = []


## 验证强制移动只接受地面：点实体应拒绝，随后点地面才提交订单。
func _ready():
	var match_instance = MatchScene.instantiate()
	add_child(match_instance)
	await get_tree().process_frame
	await get_tree().process_frame

	var human = match_instance.get_node("Players/Human")
	var tank = human.get_node("Tank")
	var helicopter = human.get_node("Helicopter")
	var enemy_building = match_instance.get_node("Players/PolicyTestEnemy/TargetCommandCenter")
	var gateway = human.get_node("UnitCommandGateway")
	var controller = human.get_node("UnitActionsController")
	var enemy_hp_before: float = enemy_building.hp
	match_instance.get_node("CommandRuntime").connect("OrderStateChanged", _on_order_state_changed)
	controller.command_feedback.connect(_on_command_feedback)
	gateway.SetFirePolicy([tank, helicopter], "HoldFire", human)
	await get_tree().process_frame

	var helicopter_click: Vector3 = enemy_building.global_position + Vector3(0.6, 0.4, 0.2)
	MatchSignals.deselect_all_units.emit()
	helicopter.find_child("Selection").select()
	controller.begin_force_move_targeting()
	MatchSignals.unit_targeted.emit(enemy_building, helicopter_click)
	await get_tree().process_frame
	_check(
		controller.get_active_command_targeting() == "ForceMove",
		"点实体后强制移动应仍处于选目标"
	)
	_check(not _has_force_move_order(helicopter), "Helicopter 点实体不得提交 ForceMove")
	_check(
		helicopter.action == null or helicopter.action.get_script() != Moving,
		"Helicopter 点实体不得开始移动"
	)
	_check(_last_feedback_status("ForceMove") == "Rejected", "点实体的强制移动应拒绝")
	_check(enemy_building.hp == enemy_hp_before, "拒绝实体目标时不得伤害建筑")

	var ground_for_helicopter := enemy_building.global_position + Vector3(8.0, 0.0, 0.0)
	MatchSignals.terrain_targeted.emit(ground_for_helicopter)
	await get_tree().process_frame
	_check(controller.get_active_command_targeting() == "", "地面确认后应退出强制移动选目标")
	_check(_has_force_move_order(helicopter), "随后右键地面应为 Helicopter 提交 ForceMove")
	_check(
		helicopter.action != null and helicopter.action.get_script() == Moving,
		"地面确认后 Helicopter 应执行 Moving"
	)
	_check(_last_feedback_status("ForceMove") == "Accepted", "地面强制移动应返回 Accepted")
	gateway.StopUnits([helicopter], human)

	var tank_click: Vector3 = enemy_building.global_position + Vector3(-0.7, 0.3, -0.1)
	MatchSignals.deselect_all_units.emit()
	tank.find_child("Selection").select()
	controller.begin_force_move_targeting()
	MatchSignals.unit_targeted.emit(enemy_building, tank_click)
	await get_tree().process_frame
	_check(not _has_force_move_order(tank), "Tank 点实体不得提交 ForceMove")
	_check(
		tank.action == null or tank.action.get_script() != Moving,
		"Tank 点实体不得退化为移动或攻击"
	)
	_check(_last_feedback_status("ForceMove") == "Rejected", "Tank 点实体的强制移动应拒绝")

	var ground_for_tank := enemy_building.global_position + Vector3(-8.0, 0.0, 0.0)
	MatchSignals.terrain_targeted.emit(ground_for_tank)
	await get_tree().process_frame
	_check(_has_force_move_order(tank), "随后右键地面应为 Tank 提交 ForceMove")
	_check(
		tank.action != null and tank.action.get_script() == Moving,
		"地面确认后 Tank 应执行 Moving，不应退化为 Attack"
	)
	_check(_last_feedback_status("ForceMove") == "Accepted", "Tank 地面强制移动应返回 Accepted")
	_check(
		enemy_building.hp == enemy_hp_before,
		"HoldFire 下强制移动不得直接对目标建筑造成伤害"
	)

	print("Entity ForceMove smoke test completed: %d failure(s)" % _failures)
	match_instance.queue_free()
	await get_tree().process_frame
	SmokeTestExit.request(get_tree(), 0 if _failures == 0 else 1)


## 收集 Match 级命令运行时发布的订单状态，用于区分 ForceMove 与普通 Move/Attack。
func _on_order_state_changed(
	order_id: String,
	command_id: String,
	unit_id: String,
	kind: String,
	previous_state: String,
	current_state: String,
	replaced_by_command_id: String
):
	_order_events.append({
		"order_id": order_id,
		"command_id": command_id,
		"unit_id": unit_id,
		"kind": kind,
		"previous_state": previous_state,
		"current_state": current_state,
		"replaced_by_command_id": replaced_by_command_id,
	})


## 收集传统命令控制器反馈，验证点击实体仍保留统一的即时接收结果。
func _on_command_feedback(command_name, accepted_count, rejected_count, status):
	_feedback_events.append({
		"command_name": command_name,
		"accepted_count": accepted_count,
		"rejected_count": rejected_count,
		"status": status,
	})


## 判断指定单位是否已经由实体点击产生 ForceMove 订单。
func _has_force_move_order(unit: Node) -> bool:
	if not unit.has_meta("ai_rts_unit_id"):
		return false
	var unit_id := str(unit.get_meta("ai_rts_unit_id"))
	for event in _order_events:
		if event["unit_id"] == unit_id and event["kind"] == "ForceMove":
			return true
	return false


## 返回指定命令最近一次即时反馈的状态。
func _last_feedback_status(command_name: String) -> String:
	for index in range(_feedback_events.size() - 1, -1, -1):
		if _feedback_events[index]["command_name"] == command_name:
			return _feedback_events[index]["status"]
	return ""


## 累计断言失败并写入 Godot 错误日志。
func _check(condition: bool, message: String):
	if condition:
		return
	_failures += 1
	push_error("Entity ForceMove assertion failed: %s" % message)
