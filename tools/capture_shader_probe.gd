extends SceneTree

## shader 探针：同一机位（river_close）下切换地形材质 uniforms，定位"矩形拼缝"来源。
## 输出 probe_<variant>.png 到 review/G4/g2_large_lake_kits/。
##
## 运行：
##   Godot_v4.7.1-stable_mono_win64_console.exe --path G:/AIRTS/AI_RTS \
##     --resolution 1920x1080 --position -4000,-4000 \
##     --script res://tools/capture_shader_probe.gd

const MAP_PATH := "res://source/match/maps/generated/16-0-1ca6e21aa1/map_16-0-1ca6e21aa1.tscn"
const OUT_DIR := "G:/AIRTS/RTS_Map_Tool/review/G4/g2_large_lake_kits"


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var packed: PackedScene = load(MAP_PATH)
	if packed == null:
		push_error("probe: map load failed")
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

	var terrain := map.find_child("Terrain") as MeshInstance3D
	assert(terrain != null and terrain.mesh != null, "no Terrain mesh")
	var mat := terrain.material_override as ShaderMaterial
	assert(mat != null, "terrain has no ShaderMaterial")
	print("BASE uniforms: showcase_world_scale=", mat.get_shader_parameter("showcase_world_scale"),
		" use_masks=", mat.get_shader_parameter("use_masks"),
		" use_macro_albedo=", mat.get_shader_parameter("use_macro_albedo"),
		" macro_strength=", mat.get_shader_parameter("macro_strength"))

	var camera := Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.far = 12000.0
	camera.current = true
	root.add_child(camera)

	# river_close 机位
	var focus := Vector2(969.999, 1128.96) * 1.024 + Vector2(-40, 40)
	var pitch := deg_to_rad(34.0)
	var dist := 320.0
	camera.size = 240.0
	camera.position = Vector3(focus.x, dist * sin(pitch), focus.y + dist * cos(pitch))
	camera.look_at(Vector3(focus.x, 0.0, focus.y))

	# 每个变体：要设置的 uniform（null 表示恢复默认）
	var variants := [
		{"name": "base", "set": {}},
		{"name": "nonormal", "set": {"normal_strength": 0.0}},
		{"name": "half_uv", "set": {"showcase_world_scale": 0.512}},
		{"name": "quad_uv", "set": {"showcase_world_scale": 4.096}},
	]
	var base := {}
	for key in ["showcase_world_scale", "use_masks", "use_macro_albedo", "debug_masks",
			"normal_strength"]:
		base[key] = mat.get_shader_parameter(key)

	for v in variants:
		for key in base.keys():
			mat.set_shader_parameter(key, base[key])
		for key in (v["set"] as Dictionary).keys():
			mat.set_shader_parameter(key, v["set"][key])
		for i in range(10):
			await process_frame
		RenderingServer.force_draw(true)
		var img := root.get_texture().get_image()
		if img == null:
			push_error("probe: null texture " + str(v["name"]))
			continue
		img.save_png(OUT_DIR + "/probe_" + str(v["name"]) + ".png")
		print("PROBE ", v["name"])
	print("PROBE_DONE")
	quit(0)
