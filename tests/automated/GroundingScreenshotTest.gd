extends Node

## 浮空修复的**可视化**验证（非 headless 运行）：在 PlainAndSimple 上开对局，
## 生成步兵/坦克/工人，用与游戏内一致的 45° 等距正交相机截图，直观看单位是否踩在沙面上。
## 运行：Godot（带窗口） --path <repo> res://tests/automated/GroundingScreenshotTest.tscn

const MAP_PATH := "res://source/match/maps/PlainAndSimple.tscn"
const INFANTRY := preload("res://source/match/units/Infantry.tscn")
const TANK := preload("res://source/match/units/Tank.tscn")

var _failures := 0


func _ready():
	await get_tree().process_frame
	await get_tree().process_frame
	await _run()
	get_tree().quit(1 if _failures > 0 else 0)


func _run():
	var settings = load("res://source/data-model/MatchSettings.gd").new()
	var human = load("res://source/data-model/PlayerSettings.gd").new()
	human.controller = Constants.PlayerType.HUMAN
	human.color = Color.BLUE
	settings.players.append(human)

	var map_instance = load(MAP_PATH).instantiate()
	var a_match = load("res://source/match/Match.tscn").instantiate()
	a_match.settings = settings
	a_match.map = map_instance
	get_tree().root.add_child(a_match)

	var player = null
	var deadline := Time.get_ticks_msec() + 150000
	while player == null and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
		var players = a_match.get_node_or_null("Players")
		if players != null and players.get_child_count() > 0:
			var candidate = players.get_child(0)
			if candidate.get_child_count() > 0:
				player = candidate
	if player == null:
		push_error("玩家单位未生成")
		_failures += 1
		return

	# 关掉对局自带的 HUD/雾，只留地形与单位，避免 UI 干扰判断。
	a_match.get_node_or_null("HUD").visible = false
	var fog = a_match.get_node_or_null("FogOfWar")
	if fog != null:
		fog.visible = false

	# 再造两个单位挨着基地放，保证画面里有兵有车。
	var anchor: Vector3 = player.get_child(0).global_position
	var infantry = INFANTRY.instantiate()
	var tank = TANK.instantiate()
	MatchSignals.setup_and_spawn_unit.emit(infantry, Transform3D(Basis(), anchor + Vector3(3, 0, 0)), player)
	MatchSignals.setup_and_spawn_unit.emit(tank, Transform3D(Basis(), anchor + Vector3(7, 0, 3)), player)
	await get_tree().create_timer(2.5).timeout

	# 选中步兵：把选择圈一起拍进去（圈在单位节点上，浮空时会跟着浮）。
	infantry.find_child("Selection").select()

	var focus: Vector3 = (infantry.global_position + tank.global_position) * 0.5
	await _screenshot("G:/AIRTS/临时文件夹/grounding_verify.png", focus)
	print("[SHOT] saved G:/AIRTS/临时文件夹/grounding_verify.png focus=", focus)

	# 顺带打印量化结论（截图之外的硬证据）。
	var terrain = a_match.get_node_or_null("Map/Geometry/Terrain")
	for unit in [infantry, tank]:
		var gy := _ground(a_match, terrain, unit.global_position)
		print("[SHOT] %s root_y=%.3f ground=%.3f delta=%+.3f" % [
			unit.name, unit.global_position.y, gy, unit.global_position.y - gy])


func _ground(a_match: Node, terrain: Node, at: Vector3) -> float:
	var body: Node3D = a_match.get_node_or_null("Terrain")
	var space: PhysicsDirectSpaceState3D = body.get_world_3d().direct_space_state
	var params := PhysicsRayQueryParameters3D.create(
		Vector3(at.x, at.y + 200.0, at.z), Vector3(at.x, at.y - 200.0, at.z))
	params.collision_mask = 2
	params.collide_with_areas = false
	var hit: Dictionary = space.intersect_ray(params)
	return (hit["position"] as Vector3).y if not hit.is_empty() else at.y


func _screenshot(path: String, focus: Vector3) -> void:
	var camera := Camera3D.new()
	camera.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	add_child(camera)
	# 与游戏内等距相机同参：正交、俯仰 -45°、yaw 0。
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 6.0
	camera.rotation_degrees = Vector3(-45.0, 0.0, 0.0)
	camera.global_position = focus + Vector3(0.0, 4.2, 4.2)
	camera.look_at(focus + Vector3(0.0, 0.3, 0.0), Vector3.UP)
	camera.current = true
	await get_tree().process_frame
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var image := get_viewport().get_texture().get_image()
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	image.save_png(path)
	camera.queue_free()
	await get_tree().process_frame
