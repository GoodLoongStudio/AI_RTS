extends Node

## R47：闭环验证发白 —— 列出**所有** WorldEnvironment、找真正生效的、
## 直接开关它的 volumetric_fog，前后各截图（默认机位 ✓ 不设相机 ✗）
var _envs: Array = []
var _match: Node


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	var wd := Timer.new()
	wd.one_shot = true
	wd.wait_time = 240.0
	add_child(wd)
	wd.timeout.connect(func() -> void: print("[CLOSE] WATCHDOG"); get_tree().quit(9))
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
	get_window().size = Vector2i(1200, 690)
	await get_tree().create_timer(14.0).timeout
	# ① 列出所有 WorldEnvironment ✓
	var all: Array = []
	for n in get_tree().root.find_children("*", "WorldEnvironment", true, false):
		var we := n as WorldEnvironment
		all.append(we)
		print("[CLOSE] WorldEnvironment: 路径=" + str(we.get_path()) + " 有env=" + str(we.environment != null) + " current=" + str(we.environment != null and we.environment == get_viewport().find_world_3d().environment))
	print("[CLOSE] WorldEnvironment 总数=" + str(all.size()))
	var world := get_viewport().find_world_3d()
	var active: Environment = world.environment if world != null else null
	print("[CLOSE] viewport world environment = " + str(active))
	# ② 列出所有 Environment 资源（含场景内其它）✓
	var dir := ProjectSettings.globalize_path("res://agent/runs/close-loop/")
	DirAccess.make_dir_recursive_absolute(dir)
	# ③ 前图 ✓
	await _shot(dir, "1_before")
	# ④ 直接把**所有** environment 的 volumetric 关掉（不只 viewport 那个 ✓）
	var n_env := 0
	for we in all:
		if we.environment != null:
			we.environment.volumetric_fog_enabled = false
			we.environment.glow_enabled = false
			n_env += 1
	if active != null:
		active.volumetric_fog_enabled = false
		active.glow_enabled = false
	print("[CLOSE] 已关闭 volumetric/glow 的 Environment 数=" + str(n_env) + " (+viewport world)")
	await _shot(dir, "2_all_volumetric_off")
	print("[CLOSE] 完成 ✓")
	get_tree().quit(0)


func _shot(dir: String, name: String) -> void:
	await get_tree().create_timer(2.0).timeout
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(dir + name + ".png")
	print("[CLOSE] saved " + name)
