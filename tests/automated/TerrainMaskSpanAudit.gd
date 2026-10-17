extends Node

const MAP_PATH := "res://source/match/maps/generated/36-1846106761-767a002977/map_36-1846106761-767a002977.tscn"
const MatchScene = preload("res://source/match/Match.tscn")
const HumanScene = preload("res://source/match/players/human/Human.tscn")
const Settings = preload("res://source/data-model/MatchSettings.gd")

var report := {}
var output := OS.get_environment("AIRTS_TERRAIN_AUDIT_OUT")

func _ready() -> void:
	FeatureFlags.handle_match_end = false
	# This terrain-only fixture must not install a UI that discovers user sessions.
	var adjutant := get_node_or_null("/root/AdjutantButton")
	if adjutant != null:
		var install_callback := Callable(adjutant, "_on_node_added")
		if get_tree().node_added.is_connected(install_callback):
			get_tree().node_added.disconnect(install_callback)
	await get_tree().process_frame
	var match_root = MatchScene.instantiate()
	match_root.name = "Match"
	match_root.settings = Settings.new()
	match_root.settings.local_player_index = 0
	var map = load(MAP_PATH).instantiate()
	map.name = "Map"
	match_root.add_child(map)
	map.owner = match_root
	for slot in 4:
		var player = HumanScene.instantiate()
		player.name = "Player%d" % slot
		player.color = Color.BLUE if slot == 0 else Color.RED
		match_root.get_node("Players").add_child(player)
	get_tree().root.add_child(match_root)
	get_tree().current_scene = match_root
	for _frame in 1200:
		if get_tree().get_nodes_in_group("units").size() >= 8:
			break
		await get_tree().process_frame
	for _tick in 4:
		await get_tree().physics_frame
	var terrain = map.get_node("Geometry/Terrain")
	var material: ShaderMaterial = terrain.material_override
	var camera: Camera3D = match_root.get_node("IsometricCamera3D")
	camera.set_process(false)
	camera.set_process_input(false)
	camera.set_process_unhandled_input(false)
	camera.edge_scroll_enabled = false
	camera.set_position_safely(map.get_node("SpawnPoints").get_child(0).global_position)
	camera.make_current()
	var governor := get_node_or_null("/root/PerformanceGovernor")
	if governor != null:
		governor.set_process(false)
	# Hide only this fixture's fog to inspect terrain, not player visibility acceptance.
	match_root.get_node("FogOfWar").hide()
	var sun: DirectionalLight3D = match_root.get_node("DirectionalLight3D")
	var environment: Environment = match_root.get_node("WorldEnvironment").environment
	report = {
		"pid": OS.get_process_id(), "map": MAP_PATH, "map_size": str(map.size),
		"mesh_aabb": str(terrain.mesh.get_aabb()), "semantic_span": terrain.semantic_span,
		"world_span": terrain.get("_world_span"), "water_span": terrain.get("_water_span"),
		"mask_world_size": material.get_shader_parameter("mask_world_size"),
		"mask_from_tex": material.get_shader_parameter("mask_from_tex"),
		"entities": get_tree().get_nodes_in_group("units").size(),
		"camera": str(camera.global_position), "camera_size": camera.size,
		"ssao": environment.ssao_enabled, "shadows": sun.shadow_enabled,
		"adjutant_installed": adjutant.get("_installed") if adjutant != null else false,
		"native_hwnd": DisplayServer.window_get_native_handle(DisplayServer.WINDOW_HANDLE),
		"gpu": RenderingServer.get_video_adapter_name(), "shots": [],
		"simulation_msec": match_root.get_simulation_msec(),
	}
	if OS.get_environment("AIRTS_TERRAIN_RENDER") == "1":
		await _shot("01-baseline")
		material.set_shader_parameter("mask_world_size", map.size.x)
		await _shot("02-span512")
		var shadow_on := sun.shadow_enabled
		sun.shadow_enabled = false
		await _shot("03-span512-no-shadows")
		sun.shadow_enabled = shadow_on
		var original_shader := material.shader
		var sample_shader := Shader.new()
		sample_shader.code = original_shader.code.replace("textureLod(t, uv0, 1.6)", "texture(t, uv0)").replace("textureLod(t, uv1, 1.6)", "texture(t, uv1)")
		material.shader = sample_shader
		await _shot("04-span512-implicit-mip")
		material.shader = original_shader
		var original_normal = material.get_shader_parameter("normal_strength")
		material.set_shader_parameter("normal_strength", 0.0)
		await _shot("05-span512-no-normal-map")
		material.set_shader_parameter("normal_strength", original_normal)
		camera.position = Vector3(256, 240, 256)
		camera.rotation_degrees = Vector3(-90, 0, 0)
		camera.size = 550
		camera.far = 500
		material.set_shader_parameter("mask_world_size", report.mask_world_size)
		await _shot("06-overview-baseline")
		material.set_shader_parameter("mask_world_size", map.size.x)
		await _shot("07-overview-span512")
	report["frames_drawn"] = Engine.get_frames_drawn()
	for entity in get_tree().get_nodes_in_group("units"):
		entity.queue_free()
	await get_tree().process_frame
	match_root.queue_free()
	get_tree().current_scene = null
	await get_tree().process_frame
	await get_tree().process_frame
	report["cleanup_ok"] = get_tree().get_nodes_in_group("units").is_empty()
	var file := FileAccess.open(output.path_join("measurements.json"), FileAccess.WRITE)
	file.store_string(JSON.stringify(report, "\t"))
	file.close()
	print("Terrain mask span audit completed")
	get_tree().quit(0)

func _shot(label: String) -> void:
	for _frame in 6:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var path := output.path_join(label + ".png")
	var rc := get_viewport().get_texture().get_image().save_png(path)
	report.shots.append({"path": path, "rc": rc, "time_usec": Time.get_ticks_usec()})
