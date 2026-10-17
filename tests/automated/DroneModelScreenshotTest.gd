extends Node

## 一次性验收：无人机新模型 SM_Prop_Drone_03 + 新离地高度 HOVER_OFFSET=3.5。
## 在 PlainAndSimple 上开对局生成无人机，游戏同款 45° 等距正交相机截图。用完即删。

const MAP_PATH := "res://source/match/maps/PlainAndSimple.tscn"
const DRONE := preload("res://source/match/units/Drone.tscn")

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

	a_match.get_node_or_null("HUD").visible = false
	var fog = a_match.get_node_or_null("FogOfWar")
	if fog != null:
		fog.visible = false

	var anchor: Vector3 = player.get_child(0).global_position
	var drone = DRONE.instantiate()
	MatchSignals.setup_and_spawn_unit.emit(
		drone, Transform3D(Basis(), anchor + Vector3(6, 0, 0)), player)
	await get_tree().create_timer(2.5).timeout

	var ground := _ground(a_match, drone.global_position)
	print("[DRONE] root_y=%.3f ground=%.3f hover=%+.3f (期望 3.5)" % [
		drone.global_position.y, ground, drone.global_position.y - ground])
	if absf(drone.global_position.y - ground - 3.5) > 0.05:
		print("[DRONE] FAIL 离地高度不符")
		_failures += 1

	await _screenshot("G:/AIRTS/临时文件夹/drone_model_verify.png", drone.global_position)
	print("[DRONE] saved G:/AIRTS/临时文件夹/drone_model_verify.png")


func _ground(a_match: Node, at: Vector3) -> float:
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
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 7.0
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
