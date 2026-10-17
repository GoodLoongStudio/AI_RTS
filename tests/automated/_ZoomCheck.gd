extends Node

## R36：同一场景拍 3 个镜头距离（找"拉远就发白"的临界 ✓）
func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	get_tree().create_timer(200.0).timeout.connect(func() -> void: get_tree().quit(3))
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
	await get_tree().create_timer(12.0).timeout
	var cam = m.get_node_or_null("IsometricCamera3D")
	var dir := ProjectSettings.globalize_path("res://agent/runs/zoom-check/")
	DirAccess.make_dir_recursive_absolute(dir)
	for size in [40.0, 120.0, 260.0]:
		if cam != null:
			cam.edge_scroll_enabled = false
			cam.size = size
			if cam.has_method("set_position_safely"):
				cam.set_position_safely(Vector3(100.0, 0, 100.0))
		await get_tree().create_timer(2.5).timeout
		await RenderingServer.frame_post_draw
		var img := get_viewport().get_texture().get_image()
		var p := dir + "zoom_%d.png" % int(size)
		img.save_png(p)
		print("[ZOOM] saved ", size, " -> ", p)
	get_tree().quit(0)
