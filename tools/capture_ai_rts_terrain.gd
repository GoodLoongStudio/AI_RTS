extends SceneTree

## 游戏内地形视觉烟测：只加载 map tscn（不进 Match，避免烘焙崩溃），
## RTS 相机截两张 —— 山面立面 + 45° 总览。

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var map_path := "res://source/match/maps/generated/16-0-1ca6e21aa1/map_16-0-1ca6e21aa1.tscn"
	var packed: PackedScene = load(map_path)
	if packed == null:
		push_error("capture: map load failed")
		quit(1)
		return
	var map = packed.instantiate()
	root.add_child(map)

	var environment := WorldEnvironment.new()
	environment.environment = Environment.new()
	environment.environment.background_mode = Environment.BG_COLOR
	environment.environment.background_color = Color("b0a68f")
	environment.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.environment.ambient_light_color = Color(0.709804, 0.615686, 0.454902)
	environment.environment.ambient_light_energy = 0.52
	environment.environment.adjustment_enabled = true
	environment.environment.adjustment_contrast = 1.10
	environment.environment.adjustment_saturation = 1.14
	root.add_child(environment)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-46, -34, 0)
	sun.light_energy = 1.22
	sun.light_color = Color(1, 0.839216, 0.647059)
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 4000
	root.add_child(sun)

	var camera := Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.far = 10000
	camera.current = true
	root.add_child(camera)

	# 山脚外法线立面机位（与 review 的 rts_mountain 同角度同尺度）
	var ffocus := Vector2(1638.672, 1365.234)
	var fnorm := Vector2(-0.36566, -0.93075)
	var mfocus := Vector2(1752.724, 1655.545)

	# 机位：游戏相机范围(size 1..60) + 实测地标；高度随台地抬高同步
	# （台地顶 8.1 语义 x4 = 32m；山体峰 15 语义 x4 = 60m）
	var views := [
		{"name": "game_default_mesa", "size": 21.25,
			"eye": Vector3(1383, 59, 564), "look": Vector3(1356, 32, 537)},
		{"name": "game_far_mesa", "size": 60.0,
			"eye": Vector3(1434, 110, 615), "look": Vector3(1356, 32, 537)},
		{"name": "game_oasis", "size": 60.0,
			"eye": Vector3(448, 86, 1231), "look": Vector3(370, 8, 1153)},
		{"name": "game_far_mountain", "size": 60.0,
			"eye": Vector3(1289, 138, 265), "look": Vector3(1211, 60, 187)},
		{"name": "diag_mesa_full", "size": 340.0,
			"eye": Vector3(1583, 400, 822), "look": Vector3(1253, 32, 492)},
		{"name": "diag_river_edge", "size": 90.0,
			"eye": Vector3(2075, 96, 1167), "look": Vector3(1972, 0, 1064)},
		# 水景机位：坐标取自 tscn 的 WaterBody/WaterMesh* 实测（353 片，
		# 世界范围 x 4..2030 / z 942..1738，中心 (1017,1340)，水面 y=0）
		# 水景机位：直接取自 tscn 实际水面片中心（局部 132,235.5 -> 世界 528,942）
		{"name": "game_water", "size": 120.0,
			"eye": Vector3(606, 72, 1020), "look": Vector3(528, 0, 942)},
		{"name": "game_overview", "size": 3200,
			"eye": Vector3(3200, 3400, 3200), "look": Vector3(1024, 20, 1024)},
		{"name": "game_profile", "size": 700,
			"eye": Vector3(1024, 60, 2200), "look": Vector3(1024, 20, 700)},
	]
	for view in views:
		camera.size = float(view.size)
		camera.position = view.eye
		camera.look_at(view.look)
		for i in range(10):
			await process_frame
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png(
			"G:/AIRTS/RTS_Map_Tool/review/G4/g2_large_lake_kits/" + view.name + ".png")
		print("CAPTURE ", view.name)
	print("GAME_CAPTURE_COMPLETE")
	quit(0)
