extends Node

## R39：发白归因（按 GPT-6 要求）
## ① 固定画质档位（读运行时实际值 ✓ 不凭代码颜色 ✗）
## ② 逐层隔离：体积雾 / 环境雾 / Fog 网格 —— 每层单独一张截图 ✓
## ③ 探针自身先修（长超时 + 每步打印进度 ✓ 避免无声超时 ✗）
## ④ 性能对照期间保持画质不变（本探针只诊断视觉 ✓ 不改产品）
func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	var wd := Timer.new()
	wd.one_shot = true
	wd.wait_time = 600.0
	add_child(wd)
	wd.timeout.connect(func() -> void: print("[FOG] WATCHDOG ⇒ 退出"); get_tree().quit(9))
	wd.start()
	await _run()


func _run() -> void:
	print("[FOG] 开始 ✓")
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
	# ① 运行时实际参数 ✓
	var world := get_viewport().find_world_3d()
	var env: Environment = world.environment if world != null else null
	var fog_mesh := m.get_node_or_null("Fog") as MeshInstance3D
	var overlay := m.get_node_or_null("FogOfWar/ScreenOverlay") as MeshInstance3D
	print("[FOG] 运行时 env 存在=" + str(env != null))
	if env != null:
		print("[FOG] env.fog_enabled=" + str(env.fog_enabled) + " volumetric=" + str(env.volumetric_fog_enabled) + " glow=" + str(env.glow_enabled) + " ssao=" + str(env.ssao_enabled))
	print("[FOG] Fog 网格存在=" + str(fog_mesh != null) + " visible=" + str(fog_mesh.visible if fog_mesh != null else false))
	print("[FOG] ScreenOverlay 存在=" + str(overlay != null))
	if fog_mesh != null and fog_mesh.material_override is ShaderMaterial:
		var mat := fog_mesh.material_override as ShaderMaterial
		print("[FOG] Fog 材质 color=" + str(mat.get_shader_parameter("color")) + " min_density=" + str(mat.get_shader_parameter("min_density_height")) + " max_density=" + str(mat.get_shader_parameter("max_density_height")))
	# 固定机位（用户截图那种拉远视角 ✓）
	var cam = m.get_node_or_null("IsometricCamera3D")
	if cam != null:
		cam.edge_scroll_enabled = false
		cam.size = 200.0
		if cam.has_method("set_position_safely"):
			cam.set_position_safely(Vector3(100.0, 0, 100.0))
	var dir := ProjectSettings.globalize_path("res://agent/runs/fog-attrib/")
	DirAccess.make_dir_recursive_absolute(dir)
	await _shot(dir, "1_baseline")
	if env != null:
		env.volumetric_fog_enabled = false
	await _shot(dir, "2_no_volumetric")
	if env != null:
		env.fog_enabled = false
	await _shot(dir, "3_no_env_fog")
	if fog_mesh != null:
		fog_mesh.visible = false
	await _shot(dir, "4_no_fog_mesh")
	if overlay != null:
		overlay.visible = false
	await _shot(dir, "5_no_overlay")
	print("[FOG] 五张完成 ✓ 全在 " + dir)
	get_tree().quit(0)


func _shot(dir: String, name: String) -> void:
	await get_tree().create_timer(1.5).timeout
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	img.save_png(dir + name + ".png")
	print("[FOG] saved " + name)
