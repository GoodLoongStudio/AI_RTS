extends Node
## Full-coverage renderer. Modes (after "--"):
##   cats    per-category contact sheets (80/page)
##   scenes  demo scene reconstructions
##   terrain terrain-keyword sheets per package
##   overview one representative sheet per package (round-robin categories)
## Texture binding: GUID-chain map (texture_map.json) -> material name
## match -> per-pack default atlas (defaults.json).

const CELL := 1.7
const COLS := 10
const TARGET_SIZE := 1.2
const PAGE := 80
const OUT_ROOT := "res://../../预览图"

var manifest_all: Dictionary = {}
var scenes: Dictionary = {}
var tex_map: Dictionary = {}
var defaults: Dictionary = {}
var tex_bank: Dictionary = {}


func _ready() -> void:
	manifest_all = _load_json("res://manifest_all.json")
	scenes = _load_json("res://scenes.json")
	tex_map = _load_json("res://texture_map.json")
	defaults = _load_json("res://defaults.json")
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


func _pick_for(fbx_res: String, mat_name: String, default_texs: Array) -> Texture2D:
	var candidates: Array = tex_map.get(fbx_res, [])
	for c: String in candidates:
		var t: Texture2D = load(c)
		if t != null:
			return t
	var by_name := _tex_by_material_name(mat_name)
	if by_name != null:
		return by_name
	for dc: String in default_texs:
		var dt: Texture2D = load(dc)
		if dt != null:
			return dt
	return null


func _bind_mesh(mi: MeshInstance3D, fbx_res: String, default_texs: Array) -> void:
	if mi.mesh == null:
		return
	for i in mi.mesh.get_surface_count():
		var mat := mi.get_active_material(i)
		if mat == null or not (mat is BaseMaterial3D):
			continue
		var bm := mat as BaseMaterial3D
		if bm.albedo_texture != null:
			continue
		var tex := _pick_for(fbx_res, bm.resource_name, default_texs)
		if tex == null:
			continue
		var dup := bm.duplicate() as BaseMaterial3D
		dup.albedo_texture = tex
		dup.metallic = 0.0
		dup.roughness = 0.9
		mi.set_surface_override_material(i, dup)


func _bind_tree(node: Node, fbx_res: String, default_texs: Array) -> void:
	if node is MeshInstance3D:
		_bind_mesh(node as MeshInstance3D, fbx_res, default_texs)
	for c in node.get_children():
		_bind_tree(c, fbx_res, default_texs)


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
	pm.size = Vector2(1200.0, 1200.0)
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


func _place_grid(paths: Array, holder: Node3D, default_texs: Array) -> int:
	var idx := 0
	var loaded := 0
	for p: String in paths:
		var ps: PackedScene = load(p)
		if ps == null:
			continue
		var inst := ps.instantiate()
		holder.add_child(inst)
		loaded += 1
		_bind_tree(inst, p, default_texs)
		var inst3d := inst as Node3D
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
		inst3d.scale = Vector3.ONE * s
		var col := idx % COLS
		var row := idx / COLS
		var cell := Vector3(float(col) * CELL, 0.0, float(row) * CELL)
		inst3d.position = cell - aabb.get_center() * s + Vector3(0.0, aabb.size.y * s * 0.5, 0.0)
		idx += 1
	return loaded


func _grid_camera(idx: int) -> Camera3D:
	var rows := ceili(float(maxi(idx, 1)) / float(COLS))
	var cx := (float(COLS - 1) * CELL) * 0.5
	var cz := (float(rows - 1) * CELL) * 0.5
	var span := maxf(float(COLS) * CELL, float(rows) * CELL)
	var cam := Camera3D.new()
	cam.fov = 52.0
	var dist := span * 0.85 + 2.2
	cam.position = Vector3(cx, dist * 0.95, cz + dist * 0.45)
	cam.set_meta("target", Vector3(cx, 0.4, cz))
	return cam


func _shoot_sheet(scene_root: Node3D, paths: Array, default_texs: Array,
		out_path: String) -> void:
	var holder := Node3D.new()
	scene_get_tree().root.add_child(holder)
	var loaded := _place_grid(paths, holder, default_texs)
	var cam := _grid_camera(paths.size())
	scene_get_tree().root.add_child(cam)
	cam.current = true
	await get_tree().process_frame
	cam.look_at(cam.get_meta("target"))
	await get_tree().process_frame
	RenderingServer.force_draw(true)
	DirAccess.make_dir_recursive_absolute(out_path.get_base_dir())
	var img := get_tree().root.get_viewport().get_texture().get_image()
	img.save_png(out_path)
	print("SHEET %s picked=%d loaded=%d md5=%s" % [out_path.get_file(), paths.size(), loaded, _md5_of(out_path)])
	holder.queue_free()
	cam.queue_free()
	await get_tree().process_frame


func _pack_root(short: String) -> String:
	var roots := {
		"4006_科幻世界": "PolygonSciFiWorlds",
		"4041_西部土著": "PolygonWesternFrontier",
		"4050_微缩城市": "PolygonMini_City",
		"4019_战争地图": "PolygonWarMap",
		"463_末日废墟": "PolygonApocalypse",
	}
	return roots.get(short, "")


func _run_cats(scene_root: Node3D, out_dir: String) -> void:
	for short: String in manifest_all.keys():
		_scan_textures(short, _pack_root(short))
		var default_texs: Array = defaults.get(short, [])
		var cats: Dictionary = manifest_all[short]
		var ordered: Array[String] = []
		for k: String in cats.keys():
			ordered.append(k)
		ordered.sort()
		var small: Array[String] = []
		for k in ordered:
			if (cats[k] as Array).size() < 6:
				small.append(k)
		var merged: Dictionary = {}
		for k in ordered:
			if k in small:
				continue
			merged[k] = cats[k]
		if small.size() > 0:
			var lump: Array = []
			for k in small:
				lump.append_array(cats[k])
			merged["其他"] = lump
		for cat: String in merged.keys():
			var list: Array = merged[cat]
			var pages := ceili(float(list.size()) / float(PAGE))
			for pg in pages:
				var slice: Array = list.slice(pg * PAGE, (pg + 1) * PAGE)
				var suffix := "" if pages == 1 else "_p%02d" % (pg + 1)
				await _shoot_sheet(scene_root, slice, default_texs,
					"%s/分类/%s_%s%s.png" % [out_dir, short, cat, suffix])


func _run_terrain(scene_root: Node3D, out_dir: String) -> void:
	var kws := ["terr", "ground", "hill", "mount", "cliff", "rock", "canyon",
		"dune", "cave", "tile", "road"]
	for short: String in manifest_all.keys():
		_scan_textures(short, _pack_root(short))
		var default_texs: Array = defaults.get(short, [])
		var picked: Array = []
		for cat: String in manifest_all[short].keys():
			for p: String in manifest_all[short][cat]:
				var low := p.to_lower()
				for kw: String in kws:
					if kw in low:
						picked.append(p)
						break
		if picked.is_empty():
			print("TERRAIN %s: none" % short)
			continue
		var pages := ceili(float(picked.size()) / float(PAGE))
		for pg in pages:
			var slice: Array = picked.slice(pg * PAGE, (pg + 1) * PAGE)
			var suffix := "" if pages == 1 else "_p%02d" % (pg + 1)
			await _shoot_sheet(scene_root, slice, default_texs,
				"%s/地形/%s_地形%s.png" % [out_dir, short, suffix])


func _run_overview(scene_root: Node3D, out_dir: String) -> void:
	for short: String in manifest_all.keys():
		_scan_textures(short, _pack_root(short))
		var default_texs: Array = defaults.get(short, [])
		var cats: Dictionary = manifest_all[short]
		var keys: Array[String] = []
		for k: String in cats.keys():
			keys.append(k)
		keys.sort()
		# round-robin across categories for a representative mix
		var picked: Array = []
		var cursors: Dictionary = {}
		var added := true
		while added and picked.size() < PAGE:
			added = false
			for k in keys:
				var list: Array = cats[k]
				var i: int = cursors.get(k, 0)
				if i < list.size() and picked.size() < PAGE:
					picked.append(list[i])
					cursors[k] = i + 1
					added = true
		await _shoot_sheet(scene_root, picked, default_texs,
			"%s/%s_overview.png" % [out_dir, short])


func _vec3(a: Array) -> Vector3:
	return Vector3(float(a[0]), float(a[1]), float(a[2]))


func _run_scenes(scene_root: Node3D, out_dir: String) -> void:
	for short: String in scenes.keys():
		_scan_textures(short, _pack_root(short))
		var default_texs: Array = defaults.get(short, [])
		for scene_name: String in scenes[short].keys():
			if scene_name.contains("Universal_RenderPipeline"):
				continue  # duplicate of City_Standard
			var holder := Node3D.new()
			scene_get_tree().root.add_child(holder)
			var n := 0
			for inst: Dictionary in scenes[short][scene_name]:
				var container := Node3D.new()
				holder.add_child(container)
				container.position = _vec3(inst["pos"]) * Vector3(1.0, 1.0, -1.0)
				var q: Array = inst["rot"]
				container.quaternion = Quaternion(float(q[0]), float(-q[1]), float(q[2]), float(q[3]))
				container.scale = _vec3(inst["scl"])
				for mesh: Dictionary in inst["meshes"]:
					var ps: PackedScene = load(mesh["res"])
					if ps == null:
						continue
					var model := ps.instantiate()
					var t := Node3D.new()
					container.add_child(t)
					t.add_child(model)
					t.position = _vec3(mesh["pos"]) * Vector3(1.0, 1.0, -1.0)
					var mq: Array = mesh["rot"]
					t.quaternion = Quaternion(float(mq[0]), float(-mq[1]), float(mq[2]), float(mq[3]))
					t.scale = _vec3(mesh["scl"])
					_bind_tree(model, mesh["res"], default_texs)
					n += 1
			if n == 0:
				holder.queue_free()
				continue
			await get_tree().process_frame
			await get_tree().process_frame
			var boxes: Array = []
			_combined_aabb(holder, Transform3D.IDENTITY, boxes)
			if boxes.is_empty():
				holder.queue_free()
				continue
			# median center (robust against far outliers) + p90 radius
			var centers: Array[Vector3] = []
			for b: AABB in boxes:
				centers.append(b.get_center())
			centers.sort()
			var mid: Vector3 = centers[centers.size() / 2]
			var dists: Array[float] = []
			for b2: AABB in boxes:
				dists.append(b2.get_center().distance_to(mid))
			dists.sort()
			var p90: float = dists[mini(dists.size() - 1, int(dists.size() * 0.9))]
			var radius: float = maxf(p90 * 1.5, 6.0)
			var center := mid
			var cam := Camera3D.new()
			cam.fov = 55.0
			var dist := radius * 2.1 + 6.0
			var dir := Vector3(0.62, 0.72, 0.85).normalized()
			scene_get_tree().root.add_child(cam)
			cam.position = center + dir * dist
			cam.current = true
			await get_tree().process_frame
			cam.look_at(center)
			await get_tree().process_frame
			RenderingServer.force_draw(true)
			var out_path := "%s/场景/%s_%s.png" % [out_dir, short, scene_name]
			DirAccess.make_dir_recursive_absolute(out_path.get_base_dir())
			var img := get_tree().root.get_viewport().get_texture().get_image()
			img.save_png(out_path)
			print("SCENE %s_%s models=%d p90=%.1f md5=%s" % [short, scene_name, n, p90, _md5_of(out_path)])
			holder.queue_free()
			cam.queue_free()
			await get_tree().process_frame


func _run() -> void:
	var mode := OS.get_environment("CAPTURE_MODE")
	if mode.is_empty():
		mode = "all"
	var scene_root := Node3D.new()
	get_tree().root.add_child(scene_root)
	_add_env(scene_root)
	await get_tree().process_frame
	var out_dir := ProjectSettings.globalize_path(OUT_ROOT)
	if mode == "cats" or mode == "all":
		await _run_cats(scene_root, out_dir)
	if mode == "terrain":
		await _run_terrain(scene_root, out_dir)
	if mode == "overview":
		await _run_overview(scene_root, out_dir)
	if mode == "scenes" or mode == "all":
		await _run_scenes(scene_root, out_dir)
	print("ALL_DONE")
	get_tree().quit(0)
