extends Node

const MatchScene = preload("res://tests/manual/TestPlayerVsAI.tscn")
const TankScene = preload("res://source/match/units/Tank.tscn")
const FIELD_POSITION := 1 << 0
const FIELD_TYPE := 1 << 1
const FIELD_RELATION := 1 << 2
const FIELD_ORDER := 1 << 6

var _failures := 0


## 验证规则 AI 编组只使用稳定 ID、当前可见敌军和固定身份 Move/Attack 命令。
func _ready():
	var match_instance = MatchScene.instantiate()
	var rule_ai = match_instance.get_node("Players/SimpleClairvoyantAI")
	rule_ai.expected_number_of_workers = 2
	rule_ai.expected_number_of_ag_turrets = 0
	rule_ai.expected_number_of_aa_turrets = 0
	rule_ai.expected_number_of_battlegroups = 1
	rule_ai.expected_number_of_units_in_battlegroup = 1
	add_child(match_instance)
	await get_tree().process_frame
	await get_tree().physics_frame
	await get_tree().process_frame

	var human = match_instance.get_node("Players/Human")
	var human_tank = human.get_node("Tank")
	var ai_tank = TankScene.instantiate()
	MatchSignals.setup_and_spawn_unit.emit(
		ai_tank,
		Transform3D(Basis.IDENTITY, human_tank.global_position + Vector3(6.0, 0.0, 0.0)),
		rule_ai,
		false
	)
	await get_tree().create_timer(1.1).timeout

	var own_tank := _find_own_tank(rule_ai)
	_check(not own_tank.is_empty(), "规则 AI 公共己方查询应返回新部署 Tank")
	var order = own_tank.get("order", null)
	_check(order != null and order.get("kind", "") == "Attack",
		"满编 Battlegroup 应通过稳定命令提交普通 Attack")
	var target_id := ""
	if order != null and order.get("target", null) != null:
		target_id = order["target"].get("entity_id", "")
	var visible_targets := _scan_visible_enemies(rule_ai, own_tank.get("position", Vector3.ZERO))
	_check(visible_targets.any(func(entity): return entity.get("id", "") == target_id),
		"Battlegroup 的 Attack 目标必须来自当前 VisibleNow 敌军观察")

	var hidden_structure = human.get_node("AircraftFactory")
	hidden_structure.global_position = Vector3(500.0, 0.0, 500.0)
	await get_tree().physics_frame
	var hidden_reference: Dictionary = (
		rule_ai
		. get("_world_query_runtime")
		. GetOwnEntityReferenceForTests(hidden_structure, human)
	)
	var gateway = rule_ai.get_node("RuleAiCommandGateway")
	var rejected: Dictionary = gateway.Attack(
		[own_tank.get("id", "")],
		hidden_reference.get("kind", ""),
		hidden_reference.get("id", "")
	)
	_check(rejected.get("status", "") == "Rejected",
		"固定身份网关必须拒绝视野外敌方目标")
	_check(rejected.get("unit_results", []).all(
		func(item): return item.get("error_code", "") == "TargetUnavailable"
	), "隐藏、失效或猜测目标应统一返回 TargetUnavailable")

	var moved: Dictionary = gateway.Move(
		[own_tank.get("id", "")],
		own_tank.get("position", Vector3.ZERO) + Vector3(1.0, 0.0, 0.0)
	)
	_check(moved.get("status", "") == "Accepted",
		"规则 AI 应能按稳定单位 ID 提交普通 Move")
	await get_tree().create_timer(1.1).timeout
	var refreshed_tank := _find_own_tank(rule_ai)
	var refreshed_order = refreshed_tank.get("order", null)
	_check(refreshed_order != null and refreshed_order.get("kind", "") == "Attack",
		"外部移动替换后，编组应从己方订单观察恢复可见目标攻击")

	print("Rule AI battlegroup smoke test completed: %d failure(s)" % _failures)
	match_instance.queue_free()
	await get_tree().process_frame
	SmokeTestExit.request(get_tree(), 0 if _failures == 0 else 1)


## 返回规则 AI 当前己方 Tank 的公开观察。
func _find_own_tank(rule_ai) -> Dictionary:
	var result: Dictionary = rule_ai.get("_world_query_runtime").GetOwnForces(
		rule_ai.get("_query_session_id"),
		FIELD_POSITION | FIELD_TYPE | FIELD_ORDER
	)
	if result.get("status", "") != "Accepted":
		return {}
	for entity in result.get("entities", []):
		if entity.get("type_id", "") == "tank":
			return entity
	return {}


## 返回指定范围内由标准会话当前看见的敌军。
func _scan_visible_enemies(rule_ai, center: Vector3) -> Array:
	var result: Dictionary = rule_ai.get("_world_query_runtime").ScanCircle(
		rule_ai.get("_query_session_id"),
		center,
		100000.0,
		FIELD_POSITION | FIELD_TYPE | FIELD_RELATION
	)
	if result.get("status", "") != "Accepted":
		return []
	return result.get("entities", []).filter(
		func(entity):
			return (
				entity.get("state", "") == "VisibleNow"
				and entity.get("relation", "") == "Enemy"
			)
	)


## 累计断言失败并输出可定位原因。
func _check(condition: bool, message: String):
	if condition:
		return
	_failures += 1
	print("FAIL: %s" % message)
	push_error(message)
