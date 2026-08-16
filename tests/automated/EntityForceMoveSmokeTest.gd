extends Node

const MatchScene = preload("res://tests/manual/TestHelicopterCommands.tscn")
const Moving = preload("res://source/match/units/actions/Moving.gd")

var _failures := 0
var _order_events: Array[Dictionary] = []
var _feedback_events: Array[Dictionary] = []


## 验证点击实体时，ForceMove 使用碰撞面的世界坐标，而不会退化为普通攻击或跟随。
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
	_check(_has_force_move_order(helicopter), "Helicopter 点击敌方建筑应提交 ForceMove 订单")
	_check(
		helicopter.action != null and helicopter.action.get_script() == Moving,
		"Helicopter 点击敌方建筑后应执行 Moving，而不是普通实体交互"
	)
	_check(
		_planar_distance(helicopter.find_child("Movement").target_position, helicopter_click) < 0.1,
		"Helicopter ForceMove 应使用实体表面的实际点击坐标"
	)
	_check(_last_feedback_status("ForceMove") == "Accepted", "Helicopter ForceMove 应返回 Accepted")
	gateway.StopUnits([helicopter], human)

	var tank_click: Vector3 = enemy_building.global_position + Vector3(-0.7, 0.3, -0.1)
	MatchSignals.deselect_all_units.emit()
	tank.find_child("Selection").select()
	controller.begin_force_move_targeting()
	MatchSignals.unit_targeted.emit(enemy_building, tank_click)
	await get_tree().process_frame
	_check(_has_force_move_order(tank), "Tank 点击敌方建筑应提交 ForceMove 订单")
	_check(
		tank.action != null and tank.action.get_script() == Moving,
		"Tank 点击敌方建筑后应执行 Moving，不应退化为 Attack"
	)
	_check(_last_feedback_status("ForceMove") == "Accepted", "Tank ForceMove 应返回 Accepted")
	_check(
		enemy_building.hp == enemy_hp_before,
		"HoldFire 下实体 ForceMove 不应直接对目标建筑造成伤害"
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


## 计算移动目标在水平面的距离，忽略实体表面高度与导航层高度差。
func _planar_distance(first: Vector3, second: Vector3) -> float:
	return Vector2(first.x, first.z).distance_to(Vector2(second.x, second.z))


## 累计断言失败并写入 Godot 错误日志。
func _check(condition: bool, message: String):
	if condition:
		return
	_failures += 1
	push_error("Entity ForceMove assertion failed: %s" % message)
