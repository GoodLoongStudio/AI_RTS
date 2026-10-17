extends Node

## R40：验证体积雾调暗后的观感（同机位 ✓ 与 1_baseline 可比 ✓）
func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	var wd := Timer.new()
	wd.one_shot = true
	wd.wait_time = 400.0
	add_child(wd)
	wd.timeout.connect(func() -> void: get_tree().quit(9))
	wd.start()
	await _run()


func _run() -> void:
	var settings = load("res://source/data-model/MatchSettings.gd").new()
	var hps = load("res://source/data-model/PlayerSettings.gd").new()
	hps.controller = Constants.PlayerType.HUMAN
	hps.color = Constants.Player.COLORS[0]
	settings.players.append(hps)
	var aps = load("res://source/data-model/PlayerSettings.gd").new()
	aps.controller = Constants.PlayerType.AI_EASY
	aps.color = Constants.Player.COLORS[1]
	aps.spawn_index_offset = 1
	settings.players.append(aps)
	settings.visible_player = 0
	var m = load("res://source/match/Match.tscn").instantiate()
	m.settings = settings
	m.map = load("res://source/match/maps/PlainAndSimple.tscn").instantiate()
	get_tree().root.add_child.call_deferred(m)
	await get_tree().process_frame
	get_tree().current_scene = m
	get_window().size = Vector2i(1200, 700)
	await get_tree().create_timer(12.0).timeout
	var world := get_viewport().find_world_3d()
	var env: Environment = world.environment if world != null else null
	if env != null:
		print("[FOG2] 运行时 volumetric=" + str(env.volumetric_fog_enabled) + " albedo=" + str(env.volumetric_fog_albedo) + " ambient=" + str(env.volumetric_fog_ambient_inject))
	var cam = m.get_node_or_null("IsometricCamera3D")
	if cam != null:
		cam.edge_scroll_enabled = false
		cam.size = 200.0
		if cam.has_method("set_position_safely"):
			cam.set_position_safely(Vector3(100.0, 0, 100.0))
	var dir := ProjectSettings.globalize_path("res://agent/runs/fog-attrib/")
	DirAccess.make_dir_recursive_absolute(dir)
	await get_tree().create_timer(2.0).timeout
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(dir + "6_after_tuning.png")
	print("[FOG2] saved 6_after_tuning")
	get_tree().quit(0)
