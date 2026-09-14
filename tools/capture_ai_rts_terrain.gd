extends SceneTree

## 游戏内地形视觉烟测：只加载 map tscn（不进 Match，避免烘焙崩溃），
## RTS 相机截两张 —— 山面立面 + 45° 总览。

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var map_path := "res://source/match/maps/generated/16-0-7d337ce8be/map_16-0-7d337ce8be.tscn"
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

	var views := [
		{"name": "game_rts_mountain", "size": 190,
			"eye": Vector3(ffocus.x + fnorm.x * 220.0, 90.0,
				ffocus.y + fnorm.y * 300.0),
			"look": Vector3(mfocus.x, 20.0, mfocus.y)},
		{"name": "game_iso45", "size": 2500,
			"eye": Vector3(2550, 2700, 2900), "look": Vector3(1024, 0, 1024)},
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
