extends Node

## 金矿/装饰物碰撞可视化：铺一个真实 Match，摆上金矿 + 装饰石 + 矿场 + 矿车，
## 打开碰撞体积可视化后存 PNG。用于人眼核对"矿还挖不挖红框（carve 洞）"。

const MAP_SCENE := "res://source/match/maps/PlainAndSimple.tscn"


func _ready():
	var settings = load("res://source/data-model/MatchSettings.gd").new()
	var hs = load("res://source/data-model/PlayerSettings.gd").new()
	hs.controller = Constants.PlayerType.HUMAN
	hs.color = Constants.Player.COLORS[0]
	settings.players.append(hs)
	settings.visible_player = 0
	var m: Node = load("res://source/match/Match.tscn").instantiate()
	m.settings = settings
	m.map = load(MAP_SCENE).instantiate()
	add_child(m)
	get_tree().current_scene = m
	for _f in range(200):
		await get_tree().physics_frame
	# 【2026-09-30】关掉战争迷雾：前几版截图整片暗棕、看不到物件，就是被迷雾遮住了。
	for node in m.find_children("*", "", true, false):
		if node.has_method("set_runtime_enabled"):
			node.call("set_runtime_enabled", false)
			print("[ORESHOT] 已关闭迷雾: %s" % node.name)
			break
	var player: Node = m.get_node("Players").get_children()[0]
	# 【2026-09-30】物件必须摆在**玩家视野内**，否则被战争迷雾遮住（前两版截图全是空地面就是这个原因）。
	var base_pos := Vector3(70.0, 0.0, 70.0)
	for u in get_tree().get_nodes_in_group("units"):
		if u.get("unit_type_id") == "command_center" and is_instance_valid(u):
			base_pos = u.global_position
			break
	print("[ORESHOT] 锚定基地: %s" % str(base_pos))
		# 【2026-10-01】排成一排、彼此留足间距：一张图覆盖全部碰撞类别且标签不互相遮挡。
	var spots := [
		["res://source/match/units/non-player/ResourceA.tscn", base_pos + Vector3(-21.0, 0.0, 10.0)],
		["res://source/match/units/non-player/ResourceB.tscn", base_pos + Vector3(-14.0, 0.0, 10.0)],
		["res://source/match/decorations/RockLargeA.tscn", base_pos + Vector3(-7.0, 0.0, 10.0)],
		["res://source/match/units/AntiGroundTurret.tscn", base_pos + Vector3(0.0, 0.0, 10.0)],
		["res://source/match/units/AntiAirTurret.tscn", base_pos + Vector3(7.0, 0.0, 10.0)],
		["res://source/match/units/OreRefinery.tscn", base_pos + Vector3(14.0, 0.0, 10.0)],
		["res://source/match/units/Worker.tscn", base_pos + Vector3(21.0, 0.0, 10.0)],
	]
	for entry in spots:
		# 【2026-09-30】地图地形有起伏，y=0 生成会被地表埋住（前一版截图是空地面就是这个原因）：
		# 从高空向下打一条射线，落到真实地表再生成。
		var gy := _ground_y(entry[1].x, entry[1].z)
		entry[1] = Vector3(entry[1].x, gy + 0.05, entry[1].z)
		var inst = (load(entry[0]) as PackedScene).instantiate()
		m.call("_setup_and_spawn_unit", inst, Transform3D(Basis.IDENTITY, entry[1]), player, false)
		await get_tree().physics_frame
		print("[ORESHOT] 生成 %s → 有效=%s 位置=%s" % [
			entry[0].get_file(), str(is_instance_valid(inst)), str(inst.global_position if is_instance_valid(inst) else Vector3.ZERO)])
	for _f in range(90):
		await get_tree().physics_frame
	var overlay = m.find_child("CollisionVolumeOverlay", true, false)
	if overlay != null and overlay.has_method("set_enabled"):
		overlay.call("set_enabled", true)
		print("[ORESHOT] overlay 已启用")
	var cam := m.get_viewport().get_camera_3d()
	cam.set_position_safely(base_pos + Vector3(0.0, 34.0, 30.0))
	cam.look_at(base_pos + Vector3(0.0, 0.0, 5.0), Vector3.UP)
	for _f in range(12):
		await get_tree().process_frame
	var img: Image = get_viewport().get_texture().get_image()
	var err := img.save_png("res://tmp_logs/r46_all_classes.png")
	print("[ORESHOT] 保存 err=%d 尺寸=%dx%d" % [err, img.get_width(), img.get_height()])
	get_tree().quit(0)


func _ground_y(x: float, z: float) -> float:
	var space := get_viewport().world_3d.direct_space_state
	var query := PhysicsRayQueryParameters3D.create(Vector3(x, 80.0, z), Vector3(x, -20.0, z))
	var hit := space.intersect_ray(query)
	return float(hit.position.y) if hit else 0.0
