extends Node

const MatchScene = preload("res://tests/manual/TestPlayerVsAI.tscn")
const TankScene = preload("res://source/match/units/Tank.tscn")
const FIELD_POSITION := 1 << 0
const FIELD_TYPE := 1 << 1
const FIELD_ORDER := 1 << 6

var _failures := 0


## AI-plan Part A Phase 5：敌人进入基地防御半径 → 编组被召回（Move 至威胁区域）。
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

	var spawns: Dictionary = rule_ai.get("_world_query_runtime").GetSpawnPoints(
		rule_ai.get("_query_session_id")
	)
	var own_spawn := Vector3.ZERO
	for point in spawns.get("spawn_points", []):
		if point.get("relation", "") == "Own":
			own_spawn = point.get("position")

	var ai_tank = TankScene.instantiate()
	MatchSignals.setup_and_spawn_unit.emit(
		ai_tank,
		Transform3D(Basis.IDENTITY, own_spawn + Vector3(4.0, 0.0, 0.0)),
		rule_ai,
		false
	)
	await get_tree().create_timer(1.0).timeout

	var threat_position: Vector3 = own_spawn + Vector3(15.0, 0.0, 0.0)
	var human = match_instance.get_node("Players/Human")
	var human_tank = TankScene.instantiate()
	MatchSignals.setup_and_spawn_unit.emit(
		human_tank,
		Transform3D(Basis.IDENTITY, threat_position),
		human,
		false
	)

	var recalled := false
	var waited := 0.0
	while waited < 6.0:
		await get_tree().create_timer(0.5).timeout
		waited += 0.5
		var tank := _own_tank(rule_ai)
		if tank.is_empty():
			continue
		var order = tank.get("order", null)
		if order != null and order.get("kind", "") == "Move":
			var target = order.get("target", null)
			if target != null and target.get("position", Vector3.INF).distance_to(threat_position) < 20.0:
				recalled = true
				break
	_check(recalled, "Phase5: 敌人进入防御半径后编组应在 6s 内被召回至威胁区域")

	print("Rule AI defense smoke test completed: %d failure(s)" % _failures)
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
