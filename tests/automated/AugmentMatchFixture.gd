extends RefCounted

const MatchScene = preload("res://source/match/Match.tscn")
const MapScene = preload("res://source/match/maps/PlainAndSimple.tscn")
const HumanScene = preload("res://source/match/players/human/Human.tscn")
const Settings = preload("res://source/data-model/MatchSettings.gd")
const Warmup = preload("res://tests/automated/SmokeTestWarmup.gd")


static func create(tree: SceneTree, local_slot := 0) -> Node:
	FeatureFlags.match_augments = true
	FeatureFlags.handle_match_end = false
	var match_root = MatchScene.instantiate()
	match_root.name = "Match"
	match_root.settings = Settings.new()
	match_root.settings.local_player_index = local_slot
	var map = MapScene.instantiate()
	map.name = "Map"
	match_root.add_child(map)
	map.owner = match_root
	for slot in 2:
		var player = HumanScene.instantiate()
		player.name = "Player%d" % slot
		player.color = Color.BLUE if slot == 0 else Color.RED
		match_root.get_node("Players").add_child(player)
		player.owner = match_root
		var base = load("res://source/match/units/CommandCenter.tscn").instantiate()
		base.name = "Base"
		base.position = Vector3(8 + slot * 32, 0, 8)
		player.add_child(base)
		base.owner = match_root
	tree.root.add_child(match_root)
	tree.current_scene = match_root
	await Warmup.wait_for_units(tree, 2)
	return match_root


static func spawn(match_root: Node, player: Node, scene: String, point: Vector3) -> Node:
	var unit = load(scene).instantiate()
	match_root._setup_and_spawn_unit(unit, Transform3D(Basis.IDENTITY, point), player, false)
	player.get_node("UnitCommandGateway").SetFirePolicy([unit], "HoldFire", player)
	return unit
