extends Node

## R52：针对"地表过曝发白"的最终扫描（迷雾保持原样 ✓ 只改亮度链路 ✓）
var _match: Node
var _dir := ""


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	var wd := Timer.new()
	wd.one_shot = true
	wd.wait_time = 420.0
	add_child(wd)
	wd.timeout.connect(func() -> void: print("[V3] WATCHDOG"); get_tree().quit(9))
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
	get_window().size = Vector2i(1000, 580)
	await get_tree().create_timer(13.0).timeout
	_dir = ProjectSettings.globalize_path("res://agent/runs/visual-final/")
	DirAccess.make_dir_recursive_absolute(_dir)
	var world := get_viewport().find_world_3d()
	var env: Environment = world.environment if world != null else null
	var mats: Array = []
	for n in _match.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		if mi.mesh == null or mi.mesh.get_surface_count() == 0:
			continue
		var m = mi.material_override if mi.material_override != null else mi.mesh.surface_get_material(0)
		if m is StandardMaterial3D and not mats.has(m):
			mats.append(m)
	print("[V3] StandardMaterial3D 数=" + str(mats.size()))
	for m in mats:
		print("[V3]   原色=" + str((m as StandardMaterial3D).albedo_color))
	var base: Array = []
	for m in mats:
		base.append((m as StandardMaterial3D).albedo_color)
	await _shot("0_original")
	# ① 只压环境光 + 曝光 ✓
	if env != null:
		env.ambient_light_energy = 0.55
		env.tonemap_exposure = 0.9
	await _shot("1_light_only")
	# ② 再把地表 albedo ×0.55 ✓
	for i in range(mats.size()):
		(mats[i] as StandardMaterial3D).albedo_color = (base[i] as Color) * Color(0.55, 0.55, 0.55, 1.0)
	await _shot("2_light_plus_albedo")
	# ③ 更强：albedo ×0.4 ✓
	for i in range(mats.size()):
		(mats[i] as StandardMaterial3D).albedo_color = (base[i] as Color) * Color(0.4, 0.4, 0.4, 1.0)
	await _shot("3_stronger")
	print("[V3] 完成 ✓")
	get_tree().quit(0)


func _shot(name: String) -> void:
	await get_tree().create_timer(1.8).timeout
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(_dir + name + ".png")
	print("[V3] saved " + name)
