extends Node

## R49：画面发白候选扫描（一次跑完 5 档 ✓ 同进程运行时改 ✓ 每档一张图 ✓）
## 候选：环境光 / 曝光 / 背景能量 / 地表 albedo / 组合
var _match: Node
var _dir := ""


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	var wd := Timer.new()
	wd.one_shot = true
	wd.wait_time = 420.0
	add_child(wd)
	wd.timeout.connect(func() -> void: print("[SWEEP] WATCHDOG"); get_tree().quit(9))
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
	_match = load("res://source/match/Match.tscn").instantiate()
	_match.settings = settings
	_match.map = load("res://source/match/maps/PlainAndSimple.tscn").instantiate()
	get_tree().root.add_child.call_deferred(_match)
	await get_tree().process_frame
	get_tree().current_scene = _match
	get_window().size = Vector2i(1100, 630)
	await get_tree().create_timer(13.0).timeout
	_dir = ProjectSettings.globalize_path("res://agent/runs/visual-sweep/")
	DirAccess.make_dir_recursive_absolute(_dir)
	var world := get_viewport().find_world_3d()
	var env: Environment = world.environment if world != null else null
	if env == null:
		print("[SWEEP] 无 environment ✗")
		get_tree().quit(1)
		return
	print("[SWEEP] 原始: ambient=" + str(env.ambient_light_energy) + " exposure=" + str(env.tonemap_exposure) + " bg=" + str(env.background_energy_multiplier) + " sat=" + str(env.adjustment_saturation))
	await _shot("0_original")
	env.ambient_light_energy = 0.6
	await _shot("1_ambient_0.6")
	env.ambient_light_energy = 1.15
	env.tonemap_exposure = 0.85
	await _shot("2_exposure_0.85")
	env.tonemap_exposure = 1.1
	env.background_energy_multiplier = 0.7
	await _shot("3_bg_0.7")
	env.background_energy_multiplier = 1.25
	# 地表 albedo 调暗（找到材质本体 ✓）
	var mesh := _match.find_child("Terrain", true, false)
	print("[SWEEP] Terrain 节点=" + str(mesh != null))
	var mats: Array = []
	for n in _match.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		var m := mi.material_override if mi.material_override != null else mi.mesh.surface_get_material(0) if mi.mesh != null and mi.mesh.get_surface_count() > 0 else null
		if m != null and m is StandardMaterial3D:
			mats.append(m)
	print("[SWEEP] 找到 StandardMaterial3D 数=" + str(mats.size()))
	for m in mats:
		var sm := m as StandardMaterial3D
		sm.albedo_color = sm.albedo_color * Color(0.62, 0.62, 0.62, 1.0)
	await _shot("4_albedo_darker")
	print("[SWEEP] 完成 ✓")
	get_tree().quit(0)


func _shot(name: String) -> void:
	await get_tree().create_timer(1.8).timeout
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(_dir + name + ".png")
	print("[SWEEP] saved " + name)
