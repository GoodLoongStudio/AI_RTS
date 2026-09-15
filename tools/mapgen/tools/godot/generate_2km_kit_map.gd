extends SceneTree

# Assemble the current reviewed kit scene as a 2 km by 2 km G4 visual map.
const SOURCE := "res://review/G4/kit_samples/all_kits_showcase/all_kits.tscn"
const OUTPUT := "res://review/G4/current_2km_kit_map"
const WORLD_SIZE_M := 2000.0
const SOURCE_SPAN_M := 370.0
const SCALE := WORLD_SIZE_M / SOURCE_SPAN_M

func _initialize() -> void:
	call_deferred("run")

func align_material_coordinates(map: Node3D) -> void:
	var copies: Dictionary = {}
	var pending: Array[Node] = [map]
	while not pending.is_empty():
		var node: Node = pending.pop_back()
		for child in node.get_children():
			pending.append(child)
		if node is MeshInstance3D and node.material_override is ShaderMaterial:
			var original: ShaderMaterial = node.material_override
			if original.shader.code.contains("showcase_shapes.gdshaderinc"):
				if not copies.has(original):
					var material := original.duplicate() as ShaderMaterial
					material.set_shader_parameter("showcase_world_scale", SCALE)
					copies[original] = material
				node.material_override = copies[original]

func capture(camera: Camera3D, name: String, position: Vector3, target: Vector3, size: float, top_down := false) -> void:
	camera.position = position
	camera.size = size
	if top_down:
		camera.rotation_degrees = Vector3(-90, 0, 0)
	else:
		camera.look_at(target)
	for frame in 18:
		await process_frame
	await RenderingServer.frame_post_draw
	var image := root.get_texture().get_image()
	assert(image != null and not image.is_empty())
	assert(image.save_png(OUTPUT + "/" + name + ".png") == OK)

func run() -> void:
	DirAccess.make_dir_recursive_absolute(OUTPUT)
	root.size = Vector2i(2200, 1500)
	root.msaa_3d = Viewport.MSAA_4X
	var packed := load(SOURCE) as PackedScene
	assert(packed != null, "Reviewed kit scene is missing")
	var map := packed.instantiate() as Node3D
	map.name = "G4KitMap_2km"
	map.scale = Vector3(SCALE, SCALE, SCALE)
	root.add_child(map)
	align_material_coordinates(map)
	var camera := Camera3D.new()
	camera.name = "G4InspectionCamera"
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.current = true
	root.add_child(camera)
	await capture(camera, "g4_ortho", Vector3(0, 2400, .01), Vector3.ZERO, 2240.0, true)
	await capture(camera, "g4_iso45", Vector3(1000, 1720, 2050), Vector3.ZERO, 2240.0)
	await capture(camera, "g4_oblique", Vector3(910, 760, 1290), Vector3(-120, 0, 40), 1390.0)
	await capture(camera, "g4_lake_detail", Vector3(-360, 480, 940), Vector3(-360, 0, 560), 460.0)
	var packed_output := PackedScene.new()
	assert(packed_output.pack(map) == OK)
	assert(ResourceSaver.save(packed_output, OUTPUT + "/g4_2km_kit_map.tscn") == OK)
	var report := {
		"id": "current_2km_kit_map",
		"world_size_m": [2000, 2000],
		"source_scene": SOURCE,
		"kit_scene_scale": SCALE,
		"components": ["plateau_and_ramps", "river_and_bridge", "lake", "earth_ridges", "square_top_mountains", "terraced_massif", "mixed_mountain_range"],
		"main_ramp": {"source_width_m": 20.0, "world_width_m": 20.0 * SCALE, "slope_degrees": 20.0, "style": "deep_inset"},
		"side_ramps": {"slope_degrees": 30.0, "style": "shallow_inset"},
		"status": "kit_composition_rendered",
		"scene_path": OUTPUT + "/g4_2km_kit_map.tscn",
		"navigation_validated": false
	}
	FileAccess.open(OUTPUT + "/g4_kit_report.json", FileAccess.WRITE).store_string(JSON.stringify(report, "  "))
	print("G4_2KM_KIT_MAP_RENDERED")
	map.queue_free()
	await process_frame
	call_deferred("quit")
