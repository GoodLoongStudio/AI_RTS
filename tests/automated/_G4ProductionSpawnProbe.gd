extends Node

const MAP_SCENE := "res://source/match/maps/PlainAndSimple.tscn"
const FACTORY_SCENE := "res://source/match/units/AircraftFactory.tscn"
const HELI_SCENE := "res://source/match/units/Helicopter.tscn"


func _ready() -> void:
	var settings = load("res://source/data-model/MatchSettings.gd").new()
	var human = load("res://source/data-model/PlayerSettings.gd").new()
	human.controller = Constants.PlayerType.HUMAN
	human.color = Constants.Player.COLORS[0]
	settings.players.append(human)
	settings.visible_player = 0
	settings.visibility = settings.Visibility.PER_PLAYER
	var match_node: Node = load("res://source/match/Match.tscn").instantiate()
	match_node.settings = settings
	match_node.map = load(MAP_SCENE).instantiate()
	add_child(match_node)
	var deadline := Time.get_ticks_msec() + 45000
	var occupancy = null
	while Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
		var map_node: Node = match_node.get_node_or_null("Map")
		if map_node != null and map_node.has_meta("water_occupancy"):
			occupancy = map_node.get_meta("water_occupancy")
		var players: Node = match_node.get_node_or_null("Players")
		if occupancy != null and players != null and players.get_child_count() > 0:
			break
	if occupancy == null:
		print("PROBE FAIL no occupancy")
		get_tree().quit(1)
		return
	var player: Node = match_node.get_node("Players").get_child(0)
	var factory: Node3D = load(FACTORY_SCENE).instantiate()
	var where := Vector3(220.0, 0.0, 220.0)
	match_node.call("_setup_and_spawn_unit", factory, Transform3D(Basis(), where), player, false)
	for _i in 8:
		await get_tree().physics_frame
	var origin: Vector3 = factory.global_position
	var blocked_to := 0.0
	var step := 0.0
	while step <= 20.0:
		if occupancy.is_ground_blocked(origin + Vector3(0.0, 0.0, step)):
			blocked_to = step
		step += 0.5
	print("PROBE factory=", origin, " +Z blocked_through=", blocked_to)
	var queue: Node = factory.get_node("ProductionQueue")
	var produced = queue.call("try_deploy_authoritative", load(HELI_SCENE))
	for _i in 8:
		await get_tree().physics_frame
	if produced == null or not is_instance_valid(produced):
		print("PROBE FAIL deploy null")
		get_tree().quit(1)
		return
	var heli := produced as Node3D
	var delta: Vector3 = heli.global_position - origin
	var dist := Vector2(delta.x, delta.z).length()
	print(
		"PROBE heli_dist=", snappedf(dist, 0.01),
		" xz=(", snappedf(delta.x, 0.01), ",", snappedf(delta.z, 0.01), ")",
		" y=", snappedf(heli.global_position.y, 0.01)
	)
	var ok := dist >= 4.2 and dist <= 8.5 and delta.z > absf(delta.x)
	print("PROBE ", "PASS" if ok else "FAIL")
	get_tree().quit(0 if ok else 1)
