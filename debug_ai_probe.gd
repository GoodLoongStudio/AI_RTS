extends Node

const MatchScene = preload("res://tests/manual/TestPlayerVsAI.tscn")
const TankScene = preload("res://source/match/units/Tank.tscn")
const FIELD_POSITION := 1 << 0
const FIELD_TYPE := 1 << 1
const FIELD_RELATION := 1 << 2
const FIELD_ORDER := 1 << 6

func _ready():
	var match_instance = MatchScene.instantiate()
	var rule_ai = match_instance.get_node("Players/SimpleClairvoyantAI")
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
	var poll := 0.0
	while poll < 2.5:
		await get_tree().create_timer(0.25).timeout
		poll += 0.25
		var result: Dictionary = rule_ai.get("_world_query_runtime").GetOwnForces(
			rule_ai.get("_query_session_id"), FIELD_POSITION | FIELD_TYPE | FIELD_ORDER)
		var tank_order := "NO_TANK"
		var tank_pos := Vector3.INF
		for entity in result.get("entities", []):
			if entity.get("type_id", "") == "tank":
				var order = entity.get("order", null)
				tank_order = "NULL" if order == null else str(order.get("kind", "NIL"))
				tank_pos = entity.get("position", Vector3.INF)
		var scan: Dictionary = rule_ai.get("_world_query_runtime").ScanCircle(
			rule_ai.get("_query_session_id"),
			tank_pos if tank_pos != Vector3.INF else Vector3.ZERO,
			100000.0,
			FIELD_POSITION | FIELD_TYPE | FIELD_RELATION
		)
		var vis := 0
		var lastknown := 0
		for entity in scan.get("entities", []):
			if entity.get("relation", "") != "Enemy":
				continue
			if entity.get("state", "") == "VisibleNow":
				vis += 1
			elif entity.get("state", "") == "LastKnown":
				lastknown += 1
		print("[%.2f] order=%s vis=%d lastknown=%d" % [poll, tank_order, vis, lastknown])
	match_instance.queue_free()
	await get_tree().process_frame
	get_tree().quit(0)
