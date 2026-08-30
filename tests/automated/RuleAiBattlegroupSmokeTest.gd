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
	# 断言窗口内保持人类坦克存活，避免「目标速死 → 兜底推进」吞掉 Attack 断言窗口。
	if "current_health" in human_tank:
		human_tank.current_health = 99999.0
	if "maximum_health" in human_tank:
		human_tank.maximum_health = 99999.0
	var ai_tank = TankScene.instantiate()
	MatchSignals.setup_and_spawn_unit.emit(
		ai_tank,
		Transform3D(Basis.IDENTITY, human_tank.global_position + Vector3(6.0, 0.0, 0.0)),
		rule_ai,
		false
	)

	# 新行为（AI-plan Phase 2/4）：AI 会立即攻击可见敌军，目标死亡后转入兜底推进。
	# 因此用 0.25s 轮询捕捉「发起过 Attack 且目标 ∈ VisibleNow」，而非在固定时刻断言。
	var saw_attack := false
	var attack_target_from_visible := false
	var attack_target_id := ""
	var poll := 0.0
	while poll < 1.5 and not saw_attack:
		await get_tree().create_timer(0.25).timeout
		poll += 0.25
		var own_tank := _find_own_tank(rule_ai)
		if own_tank.is_empty():
			continue
		var order = own_tank.get("order", null)
		var order_kind := "null"
		if order != null:
			order_kind = str(order.get("kind", "NIL"))
		print("[bt-poll] ", poll, " order=", order_kind)
		if order == null or order.get("kind", "") != "Attack":
			continue
		saw_attack = true
		attack_target_id = order["target"].get("entity_id", "") if order.get("target", null) != null else ""
		var visible_targets := _scan_visible_enemies(rule_ai, own_tank.get("position", Vector3.ZERO))
		attack_target_from_visible = visible_targets.any(
			func(entity): return entity.get("id", "") == attack_target_id
		)
	_check(saw_attack, "满编 Battlegroup 应通过稳定命令提交普通 Attack")
	_check(attack_target_from_visible,
		"Battlegroup 的 Attack 目标必须来自当前 VisibleNow 敌军观察")
	var own_tank_id := ""
	var latest_tank := _find_own_tank(rule_ai)
	own_tank_id = latest_tank.get("id", "")

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
		[own_tank_id],
		hidden_reference.get("kind", ""),
		hidden_reference.get("id", "")
	)
	_check(rejected.get("status", "") == "Rejected",
		"固定身份网关必须拒绝视野外敌方目标")
	_check(rejected.get("unit_results", []).all(
		func(item): return item.get("error_code", "") == "TargetUnavailable"
	), "隐藏、失效或猜测目标应统一返回 TargetUnavailable")

	var moved: Dictionary = gateway.Move(
		[own_tank_id],
		human_tank.global_position + Vector3(2.0, 0.0, 0.0)
	)
	_check(moved.get("status", "") == "Accepted",
		"规则 AI 应能按稳定单位 ID 提交普通 Move")
	# 把人类坦克挪回 AI 坦克可视野内，轮询等待编组恢复对可见目标的攻击。
	var ai_tank_node: Node3D = ai_tank
	human_tank.global_position = ai_tank_node.global_position + Vector3(4.0, 0.0, 0.0)
	var recovered_attack := false
	poll = 0.0
	while poll < 5.0 and not recovered_attack:
		await get_tree().create_timer(0.25).timeout
		poll += 0.25
		var refreshed_tank := _find_own_tank(rule_ai)
		if refreshed_tank.is_empty():
			continue
		var refreshed_order = refreshed_tank.get("order", null)
		recovered_attack = (
			refreshed_order != null and refreshed_order.get("kind", "") == "Attack"
		)
	_check(recovered_attack,
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
