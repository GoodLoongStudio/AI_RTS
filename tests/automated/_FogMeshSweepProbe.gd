extends Node

## R50：针对 Fog 网格（淡茶色屏幕叠加）的三个候选 ✓
var _match: Node
var _dir := ""


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	var wd := Timer.new()
	wd.one_shot = true
	wd.wait_time = 360.0
	add_child(wd)
	wd.timeout.connect(func() -> void: print("[F2] WATCHDOG"); get_tree().quit(9))
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
	_dir = ProjectSettings.globalize_path("res://agent/runs/fog-mesh-sweep/")
	DirAccess.make_dir_recursive_absolute(_dir)
	var fog := _match.get_node_or_null("Fog") as MeshInstance3D
	if fog == null:
		print("[F2] 无 Fog 节点 ✗")
		get_tree().quit(1)
		return
	var mat := fog.material_override as ShaderMaterial
	print("[F2] Fog 网格 found=true material=" + str(mat != null))
	if mat != null:
		print("[F2] 原 color=" + str(mat.get_shader_parameter("color")) + " min_density=" + str(mat.get_shader_parameter("min_density_height")) + " max_density=" + str(mat.get_shader_parameter("max_density_height")))
	await _shot("a_original")
	if mat != null:
		# 候选①：把茶色改深（保留雾感 ✓ 不再发白）
		mat.set_shader_parameter("color", Color(0.20, 0.17, 0.15, 1.0))
	await _shot("b_dark_color")
	if mat != null:
		# 候选②：把地面高度处的 alpha 压到 0（雾只留在高处 ✓）
		mat.set_shader_parameter("color", Color(0.85, 0.66, 0.58, 1.0))
		mat.set_shader_parameter("min_density_height", 9999.0)
	await _shot("c_no_ground_fog")
	if mat != null:
		mat.set_shader_parameter("min_density_height", 0.4)
	fog.visible = false
	await _shot("d_fog_hidden")
	print("[F2] 完成 ✓")
	get_tree().quit(0)


func _shot(name: String) -> void:
	await get_tree().create_timer(1.8).timeout
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(_dir + name + ".png")
	print("[F2] saved " + name)
