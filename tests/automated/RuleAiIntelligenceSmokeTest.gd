extends Node

const MatchScene = preload("res://tests/manual/TestPlayerVsAI.tscn")
const DroneScene = preload("res://source/match/units/Drone.tscn")
const FIELD_POSITION := 1 << 0
const FIELD_TYPE := 1 << 1
const FIELD_ORDER := 1 << 6

var _failures := 0


## 验证规则 AI 仅凭公开地图边界、己方 Drone 快照和稳定 Move 执行网格巡逻。
func _ready():
	var match_instance = MatchScene.instantiate()
	var rule_ai = match_instance.get_node("Players/SimpleClairvoyantAI")
	rule_ai.expected_number_of_workers = 2
	rule_ai.expected_number_of_ag_turrets = 0
	rule_ai.expected_number_of_aa_turrets = 0
	rule_ai.expected_number_of_battlegroups = 0
	add_child(match_instance)
	await get_tree().create_timer(0.7).timeout

	var runtime = rule_ai.get("_world_query_runtime")
	var session_id: String = rule_ai.get("_query_session_id")
	var bounds_result: Dictionary = runtime.GetBattlefieldBounds(session_id)
	_check(bounds_result.get("status", "") == "Accepted",
		"规则 AI 标准会话应取得公开战场边界")
	var bounds: Dictionary = bounds_result.get("bounds", {})
	_check(bounds.get("maximum_x", 0.0) > bounds.get("minimum_x", 0.0),
		"公开战场 X 范围必须为正")
	_check(bounds.get("maximum_z", 0.0) > bounds.get("minimum_z", 0.0),
		"公开战场 Z 范围必须为正")

	var drones := _get_drones(rule_ai)
	_check(drones.size() == 1, "测试场景应返回规则 AI 的初始 Drone")
	var first_drone: Dictionary = drones[0] if not drones.is_empty() else {}
	_check(_has_patrol_move_inside_bounds(first_drone, bounds),
		"初始 Drone 应通过稳定 Move 前往地图范围内的巡逻点")

	var halt_result: Dictionary = rule_ai.get_node("RuleAiCommandGateway").Halt(
		[first_drone.get("id", "")]
	)
	_check(halt_result.get("status", "") == "Accepted",
		"规则 AI 网关应按稳定 ID 接受 Drone 暂停命令")
	await get_tree().create_timer(0.7).timeout
	var suspended_drone := _find_drone(rule_ai, first_drone.get("id", ""))
	var suspended_order = suspended_drone.get("order", null)
	_check(suspended_order != null and suspended_order.get("state", "") == "Suspended",
		"暂停的 Drone Move 应跨 Intelligence 刷新保持 Suspended")

	var second_drone = DroneScene.instantiate()
	MatchSignals.setup_and_spawn_unit.emit(
		second_drone,
		Transform3D(
			Basis.IDENTITY,
			first_drone.get("position", Vector3.ZERO) + Vector3(1.0, 0.0, 1.0)
		),
		rule_ai,
		false
	)
	await get_tree().create_timer(0.7).timeout
	var refreshed_drones := _get_drones(rule_ai)
	_check(refreshed_drones.size() == 2,
		"新生产的 Drone 应由己方快照自动加入巡逻")
	var active_drones: Array = refreshed_drones.filter(
		func(entity): return entity.get("id", "") != first_drone.get("id", "")
	)
	_check(not active_drones.is_empty() and _has_patrol_move_inside_bounds(active_drones[0], bounds),
		"新增 Drone 应获得与现有暂停 Drone 独立的巡逻 Move")

	print("Rule AI intelligence smoke test completed: %d failure(s)" % _failures)
	match_instance.queue_free()
	await get_tree().process_frame
	SmokeTestExit.request(get_tree(), 0 if _failures == 0 else 1)


## 返回规则 AI 当前全部 Drone 的准确己方观察。
func _get_drones(rule_ai) -> Array:
	var result: Dictionary = rule_ai.get("_world_query_runtime").GetOwnForces(
		rule_ai.get("_query_session_id"),
		FIELD_POSITION | FIELD_TYPE | FIELD_ORDER
	)
	if result.get("status", "") != "Accepted":
		return []
	return result.get("entities", []).filter(
		func(entity): return entity.get("type_id", "") == "drone"
	)


## 按稳定 ID 返回一个 Drone 观察；不存在时返回显式空字典。
func _find_drone(rule_ai, drone_id: String) -> Dictionary:
	for drone in _get_drones(rule_ai):
		if drone.get("id", "") == drone_id:
			return drone
	return {}


## 验证 Drone 当前持有地图范围内的普通移动目标。
func _has_patrol_move_inside_bounds(drone: Dictionary, bounds: Dictionary) -> bool:
	var order = drone.get("order", null)
	if order == null or order.get("kind", "") != "Move":
		return false
	var target = order.get("target", null)
	if target == null or target.get("position", null) == null:
		return false
	var position: Vector3 = target["position"]
	return (
		position.x >= bounds.get("minimum_x", 0.0)
		and position.x <= bounds.get("maximum_x", 0.0)
		and position.z >= bounds.get("minimum_z", 0.0)
		and position.z <= bounds.get("maximum_z", 0.0)
	)


## 累计断言失败并输出可定位原因。
func _check(condition: bool, message: String):
	if condition:
		return
	_failures += 1
	print("FAIL: %s" % message)
	push_error(message)
