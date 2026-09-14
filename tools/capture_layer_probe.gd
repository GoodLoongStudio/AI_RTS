extends SceneTree

## 逐层隔离探针：在内存里把 showcase_land 的 `ALBEDO = col;` 换成单个中间量，
## 一次跑完就能定位"矩形拼缝"出自哪一层（噪声 / 某张贴图 / 宏贴图 / 云影）。
##
## 运行：
##   Godot_v4.7.1-stable_mono_win64_console.exe --path G:/AIRTS/AI_RTS \
##     --resolution 1920x1080 --position -4000,-4000 \
##     --script res://tools/capture_layer_probe.gd

const MAP_PATH := "res://source/match/maps/generated/16-0-7d337ce8be/map_16-0-7d337ce8be.tscn"
const OUT_DIR := "G:/AIRTS/RTS_Map_Tool/review/G4/g2_large_lake_kits"


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var packed: PackedScene = load(MAP_PATH)
	if packed == null:
		push_error("layer probe: map load failed")
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
	env.environment = e
	root.add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-46, -34, 0)
	sun.light_energy = 1.22
	sun.shadow_enabled = false
	root.add_child(sun)

	var terrain := map.find_child("Terrain") as MeshInstance3D
	var mat := terrain.material_override as ShaderMaterial
	var base_code: String = mat.shader.code
	print("HAS_ANCHOR ", base_code.contains("ALBEDO = col;"))

	var camera := Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.far = 12000.0
	camera.current = true
	root.add_child(camera)
	var focus := Vector2(969.999, 1128.96) * 1.024 + Vector2(-40, 40)
	camera.size = 240.0
	camera.position = Vector3(focus.x, 320.0 * sin(deg_to_rad(34.0)),
		focus.y + 320.0 * cos(deg_to_rad(34.0)))
	camera.look_at(Vector3(focus.x, 0.0, focus.y))

	# 每个变体：把末尾 ALBEDO 换成单个中间量（都是 shader 里已有的符号）
	var layers := [
		{"name": "L_sandtex", "expr": "texture(sand_tex, base_uv * 0.015).rgb"},
		{"name": "L_toptex", "expr": "texture(top_tex, base_uv * 0.019).rgb"},
		{"name": "L_detailtex", "expr": "texture(detail_tex, base_uv * 0.026).rgb"},
		{"name": "L_macrotex", "expr": "texture(macro_sand_tex, macro_uv0).rgb"},
		{"name": "L_macro0", "expr": "vec3(macro0)"},
		{"name": "L_macro1", "expr": "vec3(macro1)"},
		{"name": "L_macro2", "expr": "vec3(macro2)"},
		{"name": "L_macro3", "expr": "vec3(macro3)"},
		{"name": "L_macro4", "expr": "vec3(macro4)"},
		{"name": "L_cloud", "expr": "vec3(cloud)"},
		{"name": "L_dune45", "expr": "vec3(dune45)"},
		{"name": "L_belt250", "expr": "vec3(belt250)"},
		{"name": "L_macrofar", "expr": "vec3(macro_far)"},
		{"name": "L_camdist", "expr": "vec3(clamp(cam_dist / 800.0, 0.0, 1.0))"},
		{"name": "L_jitx", "expr": "vec3(fract(uv_jit.x / 40.0))"},
		{"name": "L_plateau_d", "expr": "vec3(clamp(plateau_d / 200.0 + 0.5, 0.0, 1.0))"},
		{"name": "L_cls", "expr": "vec3(clamp(cls * 0.5 + 0.5, 0.0, 1.0))"},
	]
	for l in layers:
		var sh := Shader.new()
		sh.code = base_code.replace("ALBEDO = col;", "ALBEDO = " + str(l["expr"]) + ";")
		mat.shader = sh
		for i in range(8):
			await process_frame
		RenderingServer.force_draw(true)
		var img := root.get_texture().get_image()
		if img == null:
			push_error("layer probe: null texture " + str(l["name"]))
			continue
		img.save_png(OUT_DIR + "/layer_" + str(l["name"]) + ".png")
		print("LAYER ", l["name"])
	print("LAYER_DONE")
	quit(0)
