extends Node

## R51：二分测试 —— ① 隐藏整个 FogOfWar ② 列出所有灯光 ③ 关掉所有灯看变化
var _match: Node
var _dir := ""


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	var wd := Timer.new()
	wd.one_shot = true
	wd.wait_time = 360.0
	add_child(wd)
	wd.timeout.connect(func() -> void: print("[B2] WATCHDOG"); get_tree().quit(9))
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
	_dir = ProjectSettings.globalize_path("res://agent/runs/binary-test/")
	DirAccess.make_dir_recursive_absolute(_dir)
	# ② 列出所有灯光 ✓
	var lights: Array = []
	for n in get_tree().root.find_children("*", "Light3D", true, false):
		lights.append(n)
		var l := n as Light3D
		print("[B2] 灯: " + str(l.get_path()) + " 类型=" + l.get_class() + " energy=" + str(l.light_energy) + " color=" + str(l.light_color) + " shadow=" + str(l.shadow_enabled))
	print("[B2] 灯光总数=" + str(lights.size()))
	await _shot("a_original")
	# ① 隐藏整个迷雾系统 ✓
	var fow := _match.get_node_or_null("FogOfWar")
	if fow != null:
		(fow as Node3D).visible = false
		print("[B2] FogOfWar 已隐藏 ✓")
	await _shot("b_no_fow")
	if fow != null:
		(fow as Node3D).visible = true
	# ③ 关掉所有灯 ✓
	for n in lights:
		(n as Light3D).visible = false
	print("[B2] 已关灯 ✓")
	await _shot("c_no_lights")
	print("[B2] 完成 ✓")
	get_tree().quit(0)


func _shot(name: String) -> void:
	await get_tree().create_timer(1.8).timeout
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(_dir + name + ".png")
	print("[B2] saved " + name)
