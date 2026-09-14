extends SceneTree

## 游戏内实机多视角截图：直接加载 G4 导出的 map tscn（走 GeneratedTerrain +
## 共享 showcase_land.gdshader 的真实游戏通路），按 review 同焦点的机位出图。
##
## 与 capture_ai_rts_terrain.gd 的区别：
##  - 多视角（总览/河道/台地坡道/桥/山脚），机位尺度贴近 RTS 实战相机而非贴脸特写。
##  - 焦点按 review 的 input.json 换算：review 世界 0..2000，游戏世界 0..2048，
##    系数 1.024。
##
## 运行（必须有窗口：headless 下 viewport texture 为 null；窗口移到屏幕外不抢前台）：
##   Godot_v4.7.1-stable_mono_win64_console.exe --path G:/AIRTS/AI_RTS \
##     --resolution 1920x1080 --position -4000,-4000 \
##     --script res://tools/capture_generated_map_views.gd

const MAP_PATH := "res://source/match/maps/generated/16-0-7d337ce8be/map_16-0-7d337ce8be.tscn"
const OUT_DIR := "G:/AIRTS/RTS_Map_Tool/review/G4/g2_large_lake_kits"
const PREFIX := "g128"

## review 世界 -> 游戏世界（2048/2000）
const K := 1.024


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var packed: PackedScene = load(MAP_PATH)
	if packed == null:
		push_error("capture: map load failed")
		quit(1)
		return
	var map: Node3D = packed.instantiate()
	root.add_child(map)

	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color("b0a68f")
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.709804, 0.615686, 0.454902)
	e.ambient_light_energy = 0.52
	e.adjustment_enabled = true
	e.adjustment_contrast = 1.10
	e.adjustment_saturation = 1.14
	env.environment = e
	root.add_child(env)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-46, -34, 0)
	sun.light_energy = 1.22
	sun.light_color = Color(1, 0.839216, 0.647059)
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 4000
	root.add_child(sun)

	var camera := Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.far = 12000.0
	camera.current = true
	root.add_child(camera)

	# 焦点与尺度（注意三套口径，混用会静默瞄错地方）：
	#  - input.json 的 focuses（riverbank/mountain/mountain_foot/scale_focus）是
	#    **review 世界米**（0..2000）→ 游戏世界 = ×1.024；
	#  - plateaus[].center / ramp_centers / bridges[].a|b 是 **语义格米**（0..512），
	#    review 侧要再 ×logical_cell(3.90625) → 游戏世界 = ×4。
	var K_REVIEW := K
	var K_SEM := 4.0
	var focus_river := Vector2(969.999, 1128.96) * K_REVIEW
	var focus_scale_pt := Vector2(1107.422, 396.484) * K_REVIEW
	# 山体焦点不硬编码：直接从 height_data.bin 求最高顶点（世界坐标）。
	# 硬编码的旧焦点对到了地图边外/低矮区，看不到主峰。
	var hd_path := MAP_PATH.get_base_dir() + "/height_data.bin"
	var peak := Vector2(1024, 1024)
	var hf := FileAccess.open(hd_path, FileAccess.READ)
	if hf != null:
		var hw: int = hf.get_32()
		var hh: int = hf.get_32()
		var heights := hf.get_buffer((hw * hh) * 4).to_float32_array()
		hf.close()
		var bi := 0
		var bv := -1.0e30
		for j in range(4, hh - 4, 2):
			for i in range(4, hw - 4, 2):
				var v: float = heights[j * hw + i]
				if v > bv:
					bv = v
					bi = j * hw + i
		peak = Vector2(float(bi % hw) * 2.0, float(bi / hw) * 2.0)   # 顶点->世界
		print("PEAK height=", bv, " world=", peak)
	# 主峰常在地图角上，直接对准会把半个画幅甩到图外；往地图中心偏 45% 取景。
	var focus_mountain := peak.lerp(Vector2(1024.0, 1024.0), 0.45)
	var focus_mfoot := Vector2(1638.672, 1365.234) * K_REVIEW
	var mfoot_norm := Vector2(-0.36566, -0.93075)
	var focus_plateau := Vector2(386.3502, 358.0448) * K_SEM
	var bridge_mid := Vector2((297.6289 + 286.3711) * 0.5, (274.2289 + 304.203) * 0.5) * K_SEM

	# 每个视图：focus（地面点）、size（正交纵向）、pitch（俯角）、dist、可选朝向
	var views := [
		{"name": "wide_top", "focus": Vector2(1024, 1024), "size": 2900.0,
			"pitch": 90.0, "dist": 3000.0},
		{"name": "wide_iso45", "focus": Vector2(1024, 1024), "size": 2400.0,
			"pitch": 45.0, "dist": 3000.0},
		{"name": "river_wide", "focus": focus_river, "size": 760.0,
			"pitch": 45.0, "dist": 900.0},
		{"name": "river_close", "focus": focus_river + Vector2(-40, 40), "size": 240.0,
			"pitch": 34.0, "dist": 320.0},
		{"name": "plateau_ramp", "focus": focus_plateau, "size": 520.0,
			"pitch": 45.0, "dist": 620.0},
		{"name": "bridge", "focus": bridge_mid, "size": 300.0,
			"pitch": 40.0, "dist": 380.0},
		{"name": "plain_scale", "focus": focus_scale_pt, "size": 520.0,
			"pitch": 45.0, "dist": 620.0},
		{"name": "ramp_central", "focus": Vector2(1080.0, 984.0), "size": 220.0,
			"pitch": 35.0, "dist": 320.0},
		{"name": "ramp_se", "focus": Vector2(1372.0, 1704.0), "size": 220.0,
			"pitch": 35.0, "dist": 320.0},
		{"name": "mountain", "focus": focus_mountain, "size": 900.0,
			"pitch": 40.0, "dist": 1100.0},
		{"name": "mountain_foot", "focus": focus_mfoot + mfoot_norm * 90.0, "size": 460.0,
			"pitch": 22.0, "dist": 560.0},
	]

	var ok := 0
	for v in views:
		var focus: Vector2 = v["focus"]
		var pitch: float = deg_to_rad(float(v["pitch"]))
		var dist: float = float(v["dist"])
		var eye := Vector3(focus.x, dist * sin(pitch), focus.y + dist * cos(pitch))
		camera.size = float(v["size"])
		camera.position = eye
		camera.look_at(Vector3(focus.x, 0.0, focus.y))
		for i in range(12):
			await process_frame
		RenderingServer.force_draw(true)
		var img := root.get_texture().get_image()
		if img == null:
			push_error("capture: null viewport texture for " + str(v["name"]))
			continue
		var err := img.save_png(OUT_DIR + "/" + PREFIX + "_" + str(v["name"]) + ".png")
		if err != OK:
			push_error("capture: save failed " + str(v["name"]))
			continue
		ok += 1
		print("CAPTURE ", v["name"])
	print("VIEWS_DONE ", ok, "/", views.size())
	quit(0)
