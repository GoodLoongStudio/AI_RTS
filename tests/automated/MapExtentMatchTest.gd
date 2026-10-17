extends Node

const MatchScene = preload("res://source/match/Match.tscn")
const HumanScene = preload("res://source/match/players/human/Human.tscn")
const Settings = preload("res://source/data-model/MatchSettings.gd")
const Warmup = preload("res://tests/automated/SmokeTestWarmup.gd")
const RandomRuntime = preload("res://source/main-menu/RandomMapRuntime.gd")

var failures: Array = []
var rows: Array = []
var baseline := OS.get_environment("AIRTS_MAP_BASELINE") == "1"

func _ready() -> void:
	FeatureFlags.handle_match_end = false
	await get_tree().process_frame
	if not baseline:
		var current_boot = JSON.parse_string('{"version":"1.1","fixed":{"world_size_m":[512,512],"export_contract_version":"world-meters-v2"}}')
		_check(RandomRuntime.compatible_bootstrap(current_boot), "JSON512 service accepted")
		_check(not RandomRuntime.has_required_world_size([512, 256]), "mixed dimensions rejected")
		_check(not RandomRuntime.has_required_world_size(["512", "512"]), "non-numeric dimensions rejected")
		_check(not RandomRuntime.compatible_bootstrap({"version": "old", "fixed": {"map_size_m": [256, 256]}}), "old service rejected")
		var legacy = load("res://source/match/maps/PlainAndSimple.tscn").instantiate()
		legacy.get_node("Geometry/Terrain").semantic_span = 256.0
		var packed := PackedScene.new()
		_check(packed.pack(legacy) == OK, "negative contract fixture packs")
		_check(not RandomRuntime.scene_matches_world_contract(packed), "label512 terrain256 rejected")
		legacy.free()
	var paths: Array = Constants.Match.MAPS.keys()
	if not OS.get_environment("AIRTS_MAP_ONLY").is_empty():
		paths = [OS.get_environment("AIRTS_MAP_ONLY")]
	var extra := OS.get_environment("AIRTS_MAP_EXTRA")
	if not extra.is_empty():
		paths.append(extra)
	for path in paths:
		await _measure(str(path))
	var output := OS.get_environment("AIRTS_MAP_OUTPUT")
	var file := FileAccess.open(output, FileAccess.WRITE)
	file.store_string(JSON.stringify({"pid": OS.get_process_id(), "baseline": baseline,
		"rows": rows, "failures": failures, "cleanup_ok": get_tree().get_nodes_in_group("units").is_empty()}, "\t"))
	file.close()
	print("Map extent match test completed: %d failure(s)" % failures.size())
	get_tree().quit(0 if failures.is_empty() else 1)

func _measure(path: String) -> void:
	var match_root = MatchScene.instantiate()
	match_root.name = "Match"
	match_root.settings = Settings.new()
	match_root.settings.local_player_index = 0
	var map = load(path).instantiate()
	map.name = "Map"
	match_root.add_child(map)
	map.owner = match_root
	var marks = map.get_node("SpawnPoints").get_children()
	for slot in 4:
		var player = HumanScene.instantiate()
		player.name = "Player%d" % slot
		player.color = Color.BLUE if slot == 0 else Color.RED
		match_root.get_node("Players").add_child(player)
	get_tree().root.add_child(match_root)
	get_tree().current_scene = match_root
	var terrain = map.get_node("Geometry/Terrain")
	if terrain.has_method("find_ground_path"):
		# Logic terrain does not bake an active Recast map; wait for real entities.
		for _frame in 1200:
			if get_tree().get_nodes_in_group("units").size() >= 8:
				break
			await get_tree().process_frame
		_check(get_tree().get_nodes_in_group("units").size() >= 8, path + " normal opening units ready")
		for _tick in 2:
			await get_tree().physics_frame
	else:
		_check(await Warmup.wait_for_units(get_tree(), 8), path + " navigation warmup")
	var camera: Camera3D = match_root.get_node("IsometricCamera3D")
	# A private-desktop probe must not react to the user's real pointer or keys.
	camera.set_process(false)
	camera.set_process_input(false)
	camera.set_process_unhandled_input(false)
	camera.edge_scroll_enabled = false
	var player = match_root.get_node("Players/Player0")
	var ores = map.get_node("Resources").get_children()
	var bounds: AABB = terrain.mesh.get_aabb()
	var minimap = match_root.find_child("Minimap", true, false)
	var fog = match_root.get_node("FogOfWar")
	var row := {"path": path, "map_size": [map.size.x, map.size.y],
		"root_scale": str(map.scale), "terrain_size": str(bounds.size),
		"camera_y": camera.position.y, "camera_size": camera.size,
		"camera_bound": camera.bounding_planes[1].d, "ores": ores.size(),
		"spawn_points": [], "out_of_bounds_ores": [], "blocked_ores": []}
	row["fog_grid"] = str(fog._explored_grid_size)
	row["minimap_world_size"] = str(minimap._map_size) if minimap != null else "missing"
	row["initial_units"] = []
	var local_base: Node3D
	for entity in get_tree().get_nodes_in_group("units"):
		if entity.player != null:
			row.initial_units.append({"type": entity.unit_type_id, "position": str(entity.global_position), "scale": str(entity.scale)})
			_check(entity.scale.is_equal_approx(Vector3.ONE), path + " normal initial unit not map scaled")
			if entity.player == player and entity.unit_type_id == "command_center":
				local_base = entity
	_check(local_base != null, path + " normal opening spawns local base")
	for mark in marks:
		row.spawn_points.append(str(mark.global_position))
	for ore in ores:
		var p: Vector3 = ore.global_position
		if p.x < 0 or p.z < 0 or p.x > map.size.x or p.z > map.size.y:
			row.out_of_bounds_ores.append(str(p))
		if terrain.has_method("is_ground_blocked") and terrain.is_ground_blocked(p):
			row.blocked_ores.append(str(p))
	if not baseline:
		_check(map.size == Vector2(512, 512), path + " map512")
		_check(map.scale.is_equal_approx(Vector3.ONE), path + " unscaled map")
		_check(absf(bounds.size.x - 512.0) < 0.1 and absf(bounds.size.z - 512.0) < 0.1, path + " actual terrain512")
		_check(is_equal_approx(camera.position.y, 80.0), path + " camera80")
		_check(is_equal_approx(camera.size, 46.75), path + " fixed opening zoom")
		_check(is_equal_approx(absf(camera.bounding_planes[1].d), 512.0), path + " camera bounds512")
		_check(row.out_of_bounds_ores.is_empty(), path + " all ores in bounds")
		_check(row.blocked_ores.is_empty(), path + " all ores on land")
		_check(terrain.has_method("find_ground_path"), path + " logic terrain")
		_check(fog._explored_grid_size == Vector2i(256, 256), path + " fog covers512")
		_check(minimap != null and minimap._map_size == Vector2(512, 512), path + " minimap covers512")
		if path.contains("/generated/"):
			var map_id := path.get_base_dir().get_file()
			row["random_accepts"] = RandomRuntime.installed_map_path({"map_id": map_id}) == path
			if not row.random_accepts:
				var state: SceneState = load(path).get_state()
				var diagnostic := {}
				for node in state.get_node_count():
					var node_path := str(state.get_node_path(node))
					if node == 0 or node_path.contains("Terrain"):
						var props := {}
						for prop in state.get_node_property_count(node):
							props[str(state.get_node_property_name(node, prop))] = str(state.get_node_property_value(node, prop))
						diagnostic[node_path] = props
				var index = JSON.parse_string(FileAccess.get_file_as_string(path.get_base_dir().path_join("map_index.json")))
				diagnostic["index_size_equal"] = index.get("size", []) == [512, 512]
				diagnostic["index_version"] = index.get("export_contract_version", "")
				row["contract_diagnostic"] = diagnostic
				print("MAP512 contract diagnostic ", JSON.stringify(diagnostic))
			_check(row.random_accepts, path + " random client verifies real terrain512")
	# A real player command at the far-side spawn exercises world-space movement.
	var far_player = match_root.get_node("Players/Player2")
	var origin: Vector3 = marks[2].global_position + Vector3(12, 0, 12)
	if terrain.has_method("unstick_ground"):
		origin = terrain.unstick_ground(origin)
	var unit = load("res://source/match/units/Tank.tscn").instantiate()
	match_root._setup_and_spawn_unit(unit, Transform3D(Basis.IDENTITY, origin), far_player, false)
	var gateway = far_player.get_node("UnitCommandGateway")
	gateway.SetFirePolicy([unit], "HoldFire", far_player)
	var goal := origin + Vector3(8, 0, 0)
	if terrain.has_method("clamp_ground_destination"):
		goal = terrain.clamp_ground_destination(goal)
	var accepted: Dictionary = gateway.MoveUnits([unit], goal, far_player)
	var start: Vector3 = unit.global_position
	var shots := OS.get_environment("AIRTS_MAP_SHOTS")
	for _tick in (60 if not shots.is_empty() else 180):
		await get_tree().physics_frame
	row["command"] = accepted
	row["movement_m"] = unit.global_position.distance_to(start)
	row["arrival_error_m"] = unit.global_position.distance_to(goal)
	row["unit_scale"] = str(unit.scale)
	row["simulation_msec"] = match_root.get_simulation_msec()
	if not baseline:
		_check(row.movement_m > 2.0, path + " far-side command moves tank")
		_check(unit.scale.is_equal_approx(Vector3.ONE), path + " spawned unit not map scaled")
	if not shots.is_empty():
		camera.set_position_safely(local_base.global_position)
		camera.make_current()
		fog.refresh_now()
		for _frame in 4:
			await get_tree().process_frame
		await RenderingServer.frame_post_draw
		var base_screen := camera.unproject_position(local_base.global_position)
		row["shot_camera_position"] = str(camera.global_position)
		row["shot_camera_rotation"] = str(camera.rotation_degrees)
		row["shot_camera_far"] = camera.far
		row["shot_base_position"] = str(local_base.global_position)
		row["shot_base_visible"] = local_base.is_visible_in_tree()
		row["shot_base_screen"] = str(base_screen)
		row["shot_viewport"] = str(get_viewport().get_visible_rect())
		_check(get_viewport().get_visible_rect().has_point(base_screen), path + " base projects inside screenshot")
		get_viewport().get_texture().get_image().save_png(shots.path_join(path.get_file().get_basename() + ".png"))
		# Separate diagnostic evidence; this is not normal fog-of-war acceptance.
		fog.hide()
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png(shots.path_join(path.get_file().get_basename() + "_geometry-only.png"))
	rows.append(row)
	# Dispose entities while their terrain still lives, then dispose the Match.
	for entity in get_tree().get_nodes_in_group("units"):
		entity.queue_free()
	await get_tree().process_frame
	match_root.queue_free()
	get_tree().current_scene = null
	await get_tree().process_frame
	await get_tree().process_frame
	_check(get_tree().get_nodes_in_group("units").is_empty(), path + " match cleanup")

func _check(ok: bool, message: String) -> void:
	if not ok:
		failures.append(message)
		push_error("MAP512 " + message)
