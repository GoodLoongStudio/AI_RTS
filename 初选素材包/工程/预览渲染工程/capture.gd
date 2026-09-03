extends SceneTree
## Pack preview capturer (windowed run only; headless viewport texture is null).
## Texture binding priority: GUID-chain map (texture_map.json) -> material name
## match -> per-pack default atlas (defaults.json). Saves PNG + MD5 per pack.

const CELL := 1.7
const COLS := 10
const TARGET_SIZE := 1.2

var manifest: Dictionary = {}
var tex_map: Dictionary = {}      # fbx res path -> [tex res paths]
var defaults: Dictionary = {}     # pack short -> [tex res paths]
var tex_bank: Dictionary = {}     # normalized stem -> res path (name fallback)
var stats: Dictionary = {}        # per-pack bind counters


func _initialize() -> void:
	manifest = _load_json("res://manifest.json")
	tex_map = _load_json("res://texture_map.json")
	defaults = _load_json("res://defaults.json")
	if manifest.is_empty():
		push_error("manifest.json missing")
		quit(1)
		return
	_run()


func _load_json(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	return parsed if parsed is Dictionary else {}


func _norm(s: String) -> String:
	var out := ""
	for ch in s.to_lower():
		out += ch if (ch >= "a" and ch <= "z") or (ch >= "0" and ch <= "9") else ""
	return out


func _scan_textures(short: String, pack_root: String) -> void:
	tex_bank = {}
	var base := "res://assets/%s/%s/Textures" % [short, pack_root]
	var stack: Array[String] = [base]
	while stack.size() > 0:
		var dir_path: String = stack.pop_back()
		var d := DirAccess.open(dir_path)
		if d == null:
			continue
		d.list_dir_begin()
		var name := d.get_next()
		while name != "":
			var p := dir_path + "/" + name
			if d.current_is_dir():
				stack.append(p)
			elif name.get_extension().to_lower() in ["png", "tga", "jpg"]:
				tex_bank[_norm(name.get_basename())] = p
			name = d.get_next()
		d.list_dir_end()


func _tex_by_material_name(mat_name: String) -> Texture2D:
	var mn := _norm(mat_name)
	if mn != "" and tex_bank.has(mn):
		return load(tex_bank[mn])
	return null


func _bind_instance(inst: Node3D, fbx_res: String, default_texs: Array) -> void:
	var skey: String = fbx_res.get_slice("/", 3)
	if not stats.has(skey):
		stats[skey] = {"map": 0, "name": 0, "default": 0, "surf": 0}
	var pack_stats: Dictionary = stats[skey]

	var candidates: Array = tex_map.get(fbx_res, [])
	var map_tex: Texture2D = null
	for c: String in candidates:
		var t: Texture2D = load(c)
		if t != null:
			map_tex = t
			break

	var stack: Array[Node] = [inst]
	while stack.size() > 0:
		var n: Node = stack.pop_back()
		for c in n.get_children():
			stack.append(c)
		if n is MeshInstance3D:
			var mi := n as MeshInstance3D
			if mi.mesh == null:
				continue
			for i in mi.mesh.get_surface_count():
				var mat := mi.get_active_material(i)
				if mat == null or not (mat is BaseMaterial3D):
					continue
				var bm := mat as BaseMaterial3D
				if bm.albedo_texture != null:
					continue
				pack_stats["surf"] += 1
				var tex := map_tex
				if tex == null:
					tex = _tex_by_material_name(bm.resource_name)
					if tex != null:
						pack_stats["name"] += 1
				if tex != null:
					pack_stats["map"] += 1
				else:
					for dc: String in default_texs:
						var dt: Texture2D = load(dc)
						if dt != null:
							tex = dt
							pack_stats["default"] += 1
							break
				if tex == null:
					continue
				var dup := bm.duplicate() as BaseMaterial3D
				dup.albedo_texture = tex
				dup.metallic = 0.0
				dup.roughness = 0.9
				mi.set_surface_override_material(i, dup)


func _combined_aabb(node: Node3D, xf: Transform3D, result: Array) -> void:
	if node is MeshInstance3D:
		var mi := node as MeshInstance3D
		var aabb: AABB = mi.get_aabb()
		if aabb.size.length() > 0.0001:
			result.append(xf * aabb)
	for c in node.get_children():
		if c is Node3D:
			_combined_aabb(c as Node3D, xf * (c as Node3D).transform, result)


func _add_env(parent: Node3D) -> void:
	var we := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	var mat := ProceduralSkyMaterial.new()
	mat.sky_top_color = Color(0.38, 0.52, 0.70)
	mat.sky_horizon_color = Color(0.76, 0.80, 0.84)
	mat.ground_bottom_color = Color(0.55, 0.55, 0.55)
	mat.ground_horizon_color = Color(0.76, 0.80, 0.84)
	sky.sky_material = mat
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 1.0
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	we.environment = env
	parent.add_child(we)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-52.0, -32.0, 0.0)
	sun.light_energy = 1.25
	sun.shadow_enabled = true
	parent.add_child(sun)

	var ground := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(400.0, 400.0)
	ground.mesh = pm
	var gm := StandardMaterial3D.new()
	gm.albedo_color = Color(0.62, 0.60, 0.57)
	gm.roughness = 0.95
	ground.material_override = gm
	ground.position.y = -0.02
	parent.add_child(ground)


func _md5_of(path: String) -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_MD5)
	ctx.update(FileAccess.get_file_as_bytes(path))
	return ctx.finish().hex_encode()


func _run() -> void:
	var scene_root := Node3D.new()
	root.add_child(scene_root)
	_add_env(scene_root)
	await process_frame

	var out_dir := ProjectSettings.globalize_path("res://../预览图")
	DirAccess.make_dir_recursive_absolute(out_dir)

	var pack_roots := {
		"4006_科幻世界": "PolygonSciFiWorlds",
		"4041_西部土著": "PolygonWesternFrontier",
		"4050_微缩城市": "PolygonMini_City",
		"4058_简单战争": "SimpleMilitary",
		"463_末日废墟": "PolygonApocalypse",
	}

	var failures: Array[String] = []
	for short: String in manifest.keys():
		_scan_textures(short, pack_roots.get(short, ""))
		var default_texs: Array = defaults.get(short, [])
		var paths: Array = manifest[short]
		var holder := Node3D.new()
		scene_root.add_child(holder)
		var idx := 0
		var loaded := 0
		for p: String in paths:
			var ps: PackedScene = load(p)
			if ps == null:
				failures.append(p)
				continue
			var inst := ps.instantiate()
			holder.add_child(inst)
			loaded += 1
			var inst3d := inst as Node3D
			_bind_instance(inst3d, p, default_texs)
			var boxes: Array = []
			_combined_aabb(inst3d, inst3d.transform, boxes)
			var aabb := AABB()
			for b: AABB in boxes:
				aabb = b if aabb.size == Vector3.ZERO else aabb.merge(b)
			if aabb.size.length() < 0.0001:
				idx += 1
				continue
			var s: float = TARGET_SIZE / maxf(aabb.size.x, maxf(aabb.size.y, aabb.size.z))
			s = clampf(s, 0.00001, 100.0)
			inst.scale = Vector3.ONE * s
			var col := idx % COLS
			var row := idx / COLS
			var cell := Vector3(float(col) * CELL, 0.0, float(row) * CELL)
			inst.position = cell - aabb.get_center() * s + Vector3(0.0, aabb.size.y * s * 0.5, 0.0)
			idx += 1

		var rows := ceili(float(maxi(idx, 1)) / float(COLS))
		var cx := (float(COLS - 1) * CELL) * 0.5
		var cz := (float(rows - 1) * CELL) * 0.5
		var span := maxf(float(COLS) * CELL, float(rows) * CELL)
		var cam := Camera3D.new()
		scene_root.add_child(cam)
		cam.fov = 52.0
		var dist := span * 0.85 + 2.2
		cam.position = Vector3(cx, dist * 0.95, cz + dist * 0.45)
		cam.current = true
		await process_frame
		cam.look_at(Vector3(cx, 0.4, cz))
		await process_frame
		RenderingServer.force_draw(true)
		print("CAM %s origin=%s loaded=%d/%d grid=%dx%d bind=%s" % [
			short, cam.global_position, loaded, paths.size(), COLS, rows, stats.get(short, {})])
		var img := root.get_viewport().get_texture().get_image()
		var out_path := out_dir + "/" + short + "_overview.png"
		img.save_png(out_path)
		print("SAVED %s md5=%s" % [out_path, _md5_of(out_path)])

		holder.queue_free()
		cam.queue_free()
		await process_frame

	if failures.size() > 0:
		print("LOAD_FAILURES (%d):" % failures.size())
		for p in failures.slice(0, 10):
			print("  ", p)
	print("ALL_DONE")
	quit(0)
