extends Node

const MatchScene = preload("res://tests/manual/TestPlayerVsAI.tscn")
const TankScene = preload("res://source/match/units/Tank.tscn")
const FIELD_POSITION := 1 << 0
const FIELD_TYPE := 1 << 1
const FIELD_RELATION := 1 << 2
const FIELD_ORDER := 1 << 6

var _failures := 0


## AI-plan Part A Phase 2：无可见敌军、无已知敌建筑时，编组必须向敌方出生点
## 兜底推进（永不站桩）；出生点来自 GetSpawnPoints 公共知识查询。
func _ready():
	var match_instance = MatchScene.instantiate()
	var rule_ai = match_instance.get_node("Players/SimpleClairvoyantAI")
	rule_ai.expected_number_of_workers = 2
	rule_ai.expected_number_of_ag_turrets = 0
	rule_ai.expected_number_of_aa_turrets = 0
	rule_ai.expected_number_of_battlegroups = 1
	rule_ai.expected_number_of_units_in_battlegroup = 1
	rule_ai.first_wave_delay_s = 0.0
	add_child(match_instance)
	await get_tree().process_frame
	await get_tree().physics_frame
	await get_tree().process_frame

	var spawns: Dictionary = rule_ai.get("_world_query_runtime").GetSpawnPoints(
		rule_ai.get("_query_session_id")
	)
	_check(spawns.get("status", "") == "Accepted", "GetSpawnPoints 应返回 Accepted")
	var enemy_spawn := Vector3.INF
	var own_spawn := Vector3.INF
	for point in spawns.get("spawn_points", []):
		if point.get("relation", "") == "Enemy" and enemy_spawn == Vector3.INF:
			enemy_spawn = point.get("position")
		if point.get("relation", "") == "Own":
			own_spawn = point.get("position")
	_check(enemy_spawn != Vector3.INF, "应能从公共知识查询取得敌方出生点")

	var human = match_instance.get_node("Players/Human")
	var ai_tank = TankScene.instantiate()
	MatchSignals.setup_and_spawn_unit.emit(
		ai_tank,
		Transform3D(Basis.IDENTITY, own_spawn + Vector3(4.0, 0.0, 0.0)),
		rule_ai,
		false
	)
	human.get_node("Tank").global_position = enemy_spawn + Vector3(30.0, 0.0, 30.0)

	var moving_to_spawn := false
	var waited := 0.0
	while waited < 8.0:
		await get_tree().create_timer(0.5).timeout
		waited += 0.5
		var tank := _own_tank(rule_ai)
		if tank.is_empty():
			continue
		var order = tank.get("order", null)
		if order != null and order.get("kind", "") == "Move":
			var target = order.get("target", null)
			if target != null and target.get("position", Vector3.INF).distance_to(enemy_spawn) < 3.0:
				moving_to_spawn = true
				break
	_check(moving_to_spawn, "Phase2: 无可见敌/无已知敌建筑时编组应向敌方出生点推进（不站桩）")

	print("Rule AI aggression smoke test completed: %d failure(s)" % _failures)
	match_instance.queue_free()
	await get_tree().process_frame
	SmokeTestExit.request(get_tree(), 0 if _failures == 0 else 1)


func _own_tank(rule_ai) -> Dictionary:
	var result: Dictionary = rule_ai.get("_world_query_runtime").GetOwnForces(
		rule_ai.get("_query_session_id"), FIELD_POSITION | FIELD_TYPE | FIELD_ORDER
	)
	for entity in result.get("entities", []):
		if entity.get("type_id", "") == "tank":
			return entity
	return {}


func _check(condition: bool, message: String):
	if condition:
		return
	_failures += 1
	print("FAIL: %s" % message)
	push_error(message)
