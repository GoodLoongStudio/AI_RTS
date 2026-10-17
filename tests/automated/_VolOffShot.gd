extends Node

## R45：用**默认机位**验证关掉体积雾后的画面（不再用跑偏的探针机位 ✗）
func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	var wd := Timer.new()
	wd.one_shot = true
	wd.wait_time = 300.0
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
	get_window().size = Vector2i(1400, 800)
	await get_tree().create_timer(16.0).timeout
	var world := get_viewport().find_world_3d()
	var env: Environment = world.environment if world != null else null
	if env != null:
		print("[V45] volumetric=" + str(env.volumetric_fog_enabled) + " glow=" + str(env.glow_enabled) + " fog=" + str(env.fog_enabled) + " ambient=" + str(env.ambient_light_energy))
	var cam = m.get_node_or_null("IsometricCamera3D")
	print("[V45] 相机 size=" + str(cam.size if cam != null else -1.0) + " 位置=" + str(cam.global_position if cam != null else Vector3.ZERO))
	var dir := ProjectSettings.globalize_path("res://agent/runs/fog-fix/")
	DirAccess.make_dir_recursive_absolute(dir)
	await get_tree().create_timer(1.5).timeout
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(dir + "7_volumetric_off_default_cam.png")
	print("[V45] saved 7_volumetric_off_default_cam")
	get_tree().quit(0)
