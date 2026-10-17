extends Node

## R46：发白逐层隔离（默认机位 ✓ 一次一层 ✓ 每层截图 ✓）
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
	get_window().size = Vector2i(1100, 640)
	await get_tree().create_timer(15.0).timeout
	var dir := ProjectSettings.globalize_path("res://agent/runs/fog-iso/")
	DirAccess.make_dir_recursive_absolute(dir)
	var fog_mesh := m.get_node_or_null("Fog") as MeshInstance3D
	var overlay := m.get_node_or_null("FogOfWar/ScreenOverlay") as MeshInstance3D
	var fog_node := m.get_node_or_null("FogOfWar")
	print("[ISO] Fog网格=" + str(fog_mesh != null) + " ScreenOverlay=" + str(overlay != null) + " FogOfWar节点=" + str(fog_node != null))
	await _shot(dir, "a_base")
	if fog_mesh != null:
		fog_mesh.visible = false
	await _shot(dir, "b_no_fog_mesh")
	if overlay != null:
		overlay.visible = false
	await _shot(dir, "c_no_fog_mesh_no_overlay")
	if fog_node != null:
		fog_node.visible = false
	await _shot(dir, "d_no_fog_system")
	print("[ISO] 完成 ✓")
	get_tree().quit(0)


func _shot(dir: String, name: String) -> void:
	await get_tree().create_timer(1.6).timeout
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(dir + name + ".png")
	print("[ISO] saved " + name)
