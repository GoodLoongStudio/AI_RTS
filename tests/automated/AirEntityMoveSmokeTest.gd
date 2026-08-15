extends Node

const MatchScene = preload("res://tests/manual/TestHelicopterCommands.tscn")
const DroneScene = preload("res://source/match/units/Drone.tscn")
const Moving = preload("res://source/match/units/actions/Moving.gd")
const MovingToUnit = preload("res://source/match/units/actions/MovingToUnit.gd")
const Following = preload("res://source/match/units/actions/Following.gd")
const OrdinaryAttacking = preload("res://source/match/units/actions/OrdinaryAttacking.gd")

var _failures := 0
var _order_events: Array[Dictionary] = []
var _feedback_events: Array[Dictionary] = []


## 验证无实体交互的空中单位把普通右键地面实体解释为点击位置移动。
func _ready():
	var match_instance = MatchScene.instantiate()
	add_child(match_instance)
	await get_tree().process_frame
	await get_tree().process_frame

	var human = match_instance.get_node("Players/Human")
	var tank = human.get_node("Tank")
	var helicopter = human.get_node("Helicopter")
	var resource = match_instance.get_node("Map/Resources/ResourceB")
	var enemy_building = match_instance.get_node("Players/PolicyTestEnemy/TargetCommandCenter")
	var gateway = human.get_node("UnitCommandGateway")
	var controller = human.get_node("UnitActionsController")
	var drone = DroneScene.instantiate()
	match_instance.call(
		"_setup_and_spawn_unit",
		drone,
		Transform3D(Basis.IDENTITY, Vector3(7, 0, 7)),
		human,
		false
	)
	var follow_target = DroneScene.instantiate()
	match_instance.call(
		"_setup_and_spawn_unit",
		follow_target,
		Transform3D(Basis.IDENTITY, Vector3(10, 0, 7)),
		human,
		false
	)
	await get_tree().process_frame
	match_instance.get_node("CommandRuntime").connect("OrderStateChanged", _on_order_state_changed)
	controller.command_feedback.connect(_on_command_feedback)
	gateway.SetFirePolicy([tank, helicopter], "HoldFire", human)
	await get_tree().process_frame

	var resource_click: Vector3 = resource.global_position + Vector3(0.25, 0.5, -0.2)
	MatchSignals.deselect_all_units.emit()
	helicopter.find_child("Selection").select()
	MatchSignals.unit_targeted.emit(resource, resource_click)
	await get_tree().process_frame
	_check(_has_order_kind(helicopter, "Move"), "Helicopter 点击矿石应提交普通 Move 订单")
	_check(
		helicopter.action != null and helicopter.action.get_script() == Moving,
		"Helicopter 点击矿石应执行 Moving，不应使用 MovingToUnit footprint 距离"
	)
	_check(
		_planar_distance(helicopter.find_child("Movement").target_position, resource_click) < 0.1,
		"Helicopter 普通移动应使用矿石表面的实际点击位置"
	)
	_check(_last_feedback_status("Move") == "Accepted", "Helicopter 实体位置移动应反馈 Accepted")
	gateway.StopUnits([helicopter], human)

	MatchSignals.deselect_all_units.emit()
	tank.find_child("Selection").select()
	MatchSignals.unit_targeted.emit(resource, resource_click)
	await get_tree().process_frame
	_check(
		tank.action != null and tank.action.get_script() == MovingToUnit,
		"地面 Tank 点击矿石应保留按双方 footprint 相接停止的 MovingToUnit 行为"
	)
	_check(_has_order_kind(tank, "ApproachEntity"), "Tank 靠近矿石应提交公共 ApproachEntity")
	gateway.StopUnits([tank], human)
	_check(
		tank.action == null or tank.action.get_script() != MovingToUnit,
		"Stop 应停止尚未到达的 ApproachEntity"
	)
	_check(gateway.GetActiveOrderState(tank) == "Suspended", "Stop 后 Approach 应保持暂停订单")

	MatchSignals.deselect_all_units.emit()
	drone.find_child("Selection").select()
	MatchSignals.terrain_targeted.emit(Vector3(14, 0, 7))
	await get_tree().process_frame
	_check(_has_order_kind(drone, "Move"), "玩家控制 Drone 普通移动应进入公共 Move")
	_check(drone.action != null and drone.action.get_script() == Moving, "Drone 应执行普通 Moving")
	gateway.StopUnits([drone], human)

	MatchSignals.unit_targeted.emit(follow_target, follow_target.global_position)
	await get_tree().process_frame
	_check(_has_order_kind(drone, "FollowEntity"), "Drone 右键己方单位应提交公共 FollowEntity")
	_check(drone.action != null and drone.action.get_script() == Following, "Drone 应持续跟随实体")
	gateway.StopUnits([drone], human)
	_check(
		drone.action == null or drone.action.get_script() != Following,
		"Stop 应终止 Follow 的实际移动"
	)
	_check(gateway.GetActiveOrderState(drone) == "Suspended", "Stop 后 Follow 应暂停且不自动恢复")

	MatchSignals.unit_targeted.emit(follow_target, follow_target.global_position)
	await get_tree().process_frame
	follow_target.queue_free()
	await get_tree().process_frame
	_check(
		_has_order_state(drone, "FollowEntity", "TargetLost"),
		"跟随目标退出后权威订单应进入 TargetLost"
	)

	MatchSignals.deselect_all_units.emit()
	helicopter.find_child("Selection").select()
	gateway.SetFirePolicy([helicopter], "FireAtWill", human)
	MatchSignals.unit_targeted.emit(enemy_building, enemy_building.global_position)
	await get_tree().process_frame
	_check(_has_order_kind(helicopter, "Attack"), "Helicopter 普通右键敌方建筑仍应提交 Attack")
	_check(
		helicopter.action != null and helicopter.action.get_script() == OrdinaryAttacking,
		"敌方实体交互优先级不得被空中位置移动分支覆盖"
	)

	print("Air entity move smoke test completed: %d failure(s)" % _failures)
	match_instance.queue_free()
	await get_tree().process_frame
	get_tree().quit(0 if _failures == 0 else 1)


## 收集 Match 级订单状态，用于确认普通实体点击产生 Move 而非攻击订单。
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


## 收集输入控制器的即时反馈。
func _on_command_feedback(command_name, accepted_count, rejected_count, status):
	_feedback_events.append({
		"command_name": command_name,
		"accepted_count": accepted_count,
		"rejected_count": rejected_count,
		"status": status,
	})


## 判断指定单位是否发布过目标种类的订单。
func _has_order_kind(unit: Node, kind: String) -> bool:
	if not unit.has_meta("ai_rts_unit_id"):
		return false
	var unit_id := str(unit.get_meta("ai_rts_unit_id"))
	for event in _order_events:
		if event["unit_id"] == unit_id and event["kind"] == kind:
			return true
	return false


## 判断指定单位的目标订单是否发布过某一权威状态。
func _has_order_state(unit: Node, kind: String, state: String) -> bool:
	if not unit.has_meta("ai_rts_unit_id"):
		return false
	var unit_id := str(unit.get_meta("ai_rts_unit_id"))
	for event in _order_events:
		if (
			event["unit_id"] == unit_id
			and event["kind"] == kind
			and event["current_state"] == state
		):
			return true
	return false


## 返回指定命令最近一次即时反馈状态。
func _last_feedback_status(command_name: String) -> String:
	for index in range(_feedback_events.size() - 1, -1, -1):
		if _feedback_events[index]["command_name"] == command_name:
			return _feedback_events[index]["status"]
	return ""


## 计算两个世界坐标的水平面距离。
func _planar_distance(first: Vector3, second: Vector3) -> float:
	return Vector2(first.x, first.z).distance_to(Vector2(second.x, second.z))


## 累计断言失败并写入 Godot 错误日志。
func _check(condition: bool, message: String):
	if condition:
		return
	_failures += 1
	push_error("Air entity move assertion failed: %s" % message)
