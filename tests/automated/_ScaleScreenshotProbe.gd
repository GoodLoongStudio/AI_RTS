extends Node

## 世界尺度审计 · 可见截图探针（阶段6）：真实 Match + 渲染截图。
## 图1：选中坦克的攻击范围圈（新口径 = attack_range + 自身半径 = 9.5m），
##      敌方指挥中心放在 11.5m 处（权威可及上限 = 7.5+2+3.48=12.98m，圈沿在目标表面附近）。
## 图2：坦克/重坦/步兵/指挥中心的尺度对比。

const MAP_SCENE := "res://source/match/maps/PlainAndSimple.tscn"

var _shots_done := 0


func _ready():
	var settings = load("res://source/data-model/MatchSettings.gd").new()
	var hs = load("res://source/data-model/PlayerSettings.gd").new()
	hs.controller = Constants.PlayerType.HUMAN
	hs.color = Color.BLUE
	settings.players.append(hs)
	settings.visible_player = 0
	var m: Node = load("res://source/match/Match.tscn").instantiate()
	m.settings = settings
	m.map = load(MAP_SCENE).instantiate()
	add_child(m)
	get_tree().current_scene = m
	for _f in range(200):
		await get_tree().physics_frame
	var p: Node = m.get_node("Players").get_children()[0]
	m.get_node_or_null("HUD").visible = false
	var fog = m.get_node_or_null("FogOfWar")
	if fog != null:
		fog.visible = false

	var tank = load("res://source/match/units/Tank.tscn").instantiate()
	var infantry = load("res://source/match/units/Infantry.tscn").instantiate()
	var heavy = load("res://source/match/units/HeavyTank.tscn").instantiate()
	var enemy_cc = load("res://source/match/units/CommandCenter.tscn").instantiate()
	MatchSignals.setup_and_spawn_unit.emit(tank, Transform3D(Basis.IDENTITY, Vector3(30, 0, 30)), p)
	MatchSignals.setup_and_spawn_unit.emit(infantry, Transform3D(Basis.IDENTITY, Vector3(32, 0, 27)), p)
	MatchSignals.setup_and_spawn_unit.emit(heavy, Transform3D(Basis.IDENTITY, Vector3(34, 0, 31)), p)
	# 敌方指挥中心：中心距 11.5m（坦克对它的可及上限 12.98m，圈沿 9.5m + 建筑半径 3.48 ≈ 表面重合）
	# 敌方必须是真 Player（Unit._setup_color 调 player.get_color_material()）
	var enemy := Node3D.new()
	enemy.name = "EnemyHolder"
	enemy.set_script(load("res://source/match/players/Player.gd"))
	enemy.color = Color.RED
	enemy.add_to_group("players")
	m.get_node("Players").add_child(enemy)
	MatchSignals.setup_and_spawn_unit.emit(
		enemy_cc, Transform3D(Basis.IDENTITY, Vector3(30, 0, 41.5)), enemy)
	await get_tree().create_timer(1.5).timeout

	tank.find_child("Selection").select()
	await get_tree().create_timer(0.5).timeout
	await _screenshot(
		"agent/runs/2026-10-01-world-scale-audit/screenshots/attack_circle.png",
		Vector3(30.5, 0, 34.0), 15.0)
	_shots_done += 1

	tank.find_child("Selection").deselect()
	await _screenshot(
		"agent/runs/2026-10-01-world-scale-audit/screenshots/scale_lineup.png",
		Vector3(32.5, 0, 29.0), 13.0)
	_shots_done += 1
	print("[SHOT] done=%d" % _shots_done)
	get_tree().quit(0)


func _screenshot(path: String, focus: Vector3, size: float) -> void:
	var camera := Camera3D.new()
	camera.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	add_child(camera)
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = size
	camera.rotation_degrees = Vector3(-50.0, 0.0, 0.0)
	camera.global_position = focus + Vector3(0.0, size * 0.7, size * 0.7)
	camera.look_at(focus + Vector3(0.0, 0.5, 0.0), Vector3.UP)
	camera.current = true
	await get_tree().process_frame
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var image := get_viewport().get_texture().get_image()
	DirAccess.make_dir_recursive_absolute("res://" + path.get_base_dir())
	image.save_png("res://" + path)
	camera.queue_free()
	await get_tree().process_frame
	print("[SHOT] saved ", ProjectSettings.globalize_path("res://" + path))
