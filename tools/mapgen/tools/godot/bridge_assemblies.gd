extends SceneTree

const BASE = "res://assets/4006_科幻世界/PolygonSciFiWorlds/Models/"
const OUT = "G:/AIRTS/RTS_Map_Tool/review/G4/bridge_assemblies/single_tier_ends"
const DECK_HEIGHT = 0.7
var world: Node3D
var camera: Camera3D
var measurements: Dictionary = {}

func _initialize():
	call_deferred("run")

func bounds(n: Node3D, xf: Transform3D, boxes: Array):
	if n is MeshInstance3D:
		boxes.append(xf * n.get_aabb())
	for c in n.get_children():
		if c is Node3D:
			bounds(c, xf * c.transform, boxes)

func part(parent: Node3D, suffix: String, pos: Vector3, target: Vector3, yaw: float = 0.0):
	var path = BASE + "SM_Bld_Bridge" + suffix + "_01.fbx"
	var resource = load(path)
	if resource == null:
		push_error("Missing bridge asset: " + path)
		quit(1)
		return
	var inst = resource.instantiate()
	var boxes: Array = []
	bounds(inst, inst.transform, boxes)
	var box: AABB = boxes[0]
	for b in boxes:
		box = box.merge(b)
	measurements[suffix] = {"source": path, "position": str(box.position), "size": str(box.size)}
	var holder = Node3D.new()
	parent.add_child(holder)
	holder.add_child(inst)
	inst.position -= box.get_center()
	holder.scale = target / box.size
	holder.rotation.y = yaw
	holder.position = pos
	var nodes: Array = [inst]
	var tex = load(BASE + "PolygonScifiWorlds_Texture_01_A.png")
	while not nodes.is_empty():
		var n = nodes.pop_back()
		nodes.append_array(n.get_children())
		if n is MeshInstance3D:
			for i in n.mesh.get_surface_count():
				var m = n.get_active_material(i)
				if m is StandardMaterial3D:
					var copy = m.duplicate()
					if copy.albedo_texture == null:
						copy.albedo_texture = tex
					copy.roughness = 0.85
					n.set_surface_override_material(i, copy)

func block(parent: Node3D, pos: Vector3, size: Vector3, color: Color):
	var mi = MeshInstance3D.new()
	var mesh = BoxMesh.new()
	mesh.size = size
	mi.mesh = mesh
	var mat = StandardMaterial3D.new()
	mat.albedo_color = color
	mi.material_override = mat
	mi.position = pos
	parent.add_child(mi)

func run():
	DirAccess.make_dir_recursive_absolute(OUT)
	root.size = Vector2i(1600, 1000)
	world = Node3D.new()
	root.add_child(world)
	var env = WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color(0.76, 0.82, 0.86)
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color.WHITE
	env.environment.ambient_light_energy = 0.65
	world.add_child(env)
	var light = DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-55, -25, 0)
	light.shadow_enabled = true
	world.add_child(light)
	camera = Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 36
	world.add_child(camera)
	camera.position = Vector3(28, 30, 35)
	camera.look_at(Vector3.ZERO)
	for variant in range(3):
		var assembly = Node3D.new()
		world.add_child(assembly)
		var count = 2 if variant == 0 else 3
		var length = count * 8.0
		block(assembly, Vector3(0, -1.4, 0), Vector3(65, 0.1, 60), Color(0.17, 0.43, 0.57))
		for side in [-1, 1]:
			block(assembly, Vector3(0, -1.2, side * (length / 2 + 10)), Vector3(65, 2.4, 20), Color(0.57, 0.52, 0.40))
		for i in count:
			var z = (i - (count - 1) / 2.0) * 8
			part(assembly, "", Vector3(0, DECK_HEIGHT - 0.35, z), Vector3(8, 0.7, 8))
			if variant != 2:
				for side in [-1, 1]:
					part(assembly, "_Rail", Vector3(side * 3.8, DECK_HEIGHT + 0.1, z), Vector3(0.65, 1.35, 8), PI if side == -1 else 0)
			else:
				for side in [-1, 1]:
					part(assembly, "_Rail_Half", Vector3(side * 3.8, DECK_HEIGHT + 0.1, z), Vector3(0.65, 1.35, 4), PI if side == -1 else 0)
		for end in [-1, 1]:
			part(assembly, "_End", Vector3(0, 0.35, end * (length / 2 + 1.1)), Vector3(8, 0.7, 2.2), PI if end == -1 else 0)
			for side in [-1, 1]:
				part(assembly, "_Rail_Pillar", Vector3(side * 3.8, DECK_HEIGHT + 0.45, end * (length / 2 - 0.25)), Vector3(0.7, 1, 0.7))
		for frame in 12:
			await process_frame
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png(OUT + "/bridge_%s.png" % (variant + 1))
		assembly.queue_free()
		await process_frame
	var f = FileAccess.open(OUT + "/measurements.json", FileAccess.WRITE)
	f.store_string(JSON.stringify(measurements, "  "))
	quit()
