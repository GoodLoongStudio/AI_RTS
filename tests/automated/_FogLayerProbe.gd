extends Node

## R37：逐个关掉"发白"候选层并截图（决定谁是真凶 ✓）
func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	get_tree().create_timer(260.0).timeout.connect(func() -> void: get_tree().quit(3))
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
	var cam = m.get_node_or_null("IsometricCamera3D")
	if cam != null:
		cam.edge_scroll_enabled = false
		cam.size = 200.0
		if cam.has_method("set_position_safely"):
			cam.set_position_safely(Vector3(100.0, 0, 100.0))
	var dir := ProjectSettings.globalize_path("res://agent/runs/fog-layers/")
	DirAccess.make_dir_recursive_absolute(dir)
	await _shot(dir, "a_baseline")
	# ① 关体积雾 ✓
	var world := get_viewport().find_world_3d()
	var env := world.environment if world != null else null
	if env != null:
		env.volumetric_fog_enabled = false
	await _shot(dir, "b_no_volumetric")
	# ② 再关环境雾 ✓
	if env != null:
		env.fog_enabled = false
	await _shot(dir, "c_no_env_fog")
	# ③ 再藏 Fog 网格 ✓
	var fog_mesh := m.get_node_or_null("Fog")
	if fog_mesh != null:
		fog_mesh.visible = false
	await _shot(dir, "d_no_fog_mesh")
	print("[LAYERS] 四张已存 ✓（a 基线 / b 关体积雾 / c 再关环境雾 / d 再藏 Fog 网格）")
	get_tree().quit(0)


func _shot(dir: String, name: String) -> void:
	await get_tree().create_timer(1.8).timeout
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	img.save_png(dir + name + ".png")
	print("[LAYERS] saved ", name)
