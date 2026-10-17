extends SceneTree

## One-time authored-scene migration. Values use Godot's Variant parser.
const ROOT := "res://source/match/maps/"
const OUT := "res://agent/runs/map512/migration/"
var records: Array = []

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT))
	var dir := DirAccess.open(ROOT + "generated")
	for entry in dir.get_directories():
		var path := ROOT + "generated/" + entry + "/map_" + entry + ".tscn"
		if FileAccess.file_exists(path):
			if "--repair-resources" in OS.get_cmdline_user_args():
				await _repair_resources(path)
			else:
				await _migrate(path, 256.0)
	if not "--repair-resources" in OS.get_cmdline_user_args():
		await _migrate(ROOT + "PlainAndSimple.tscn", 208.0)
	var report_name := "resource-repair.json" if "--repair-resources" in OS.get_cmdline_user_args() else "migration.json"
	var report := FileAccess.open(OUT + report_name, FileAccess.WRITE)
	report.store_string(JSON.stringify(records, "\t"))
	report.close()
	quit(0)

func _repair_resources(path: String) -> void:
	var map = load(path).instantiate()
	var container = map.get_node("Resources")
	var ores = container.get_children()
	# Do not run Unit._ready outside a Match; only terrain is needed for this migration.
	for ore in ores:
		container.remove_child(ore)
	root.add_child(map)
	await process_frame
	var terrain = map.get_node("Geometry/Terrain")
	var moved: Array = []
	var positions := {}
	for ore in ores:
		var old: Vector3 = ore.position
		var point := old
		if not _ore_land(terrain, point):
			var found := false
			for radius in range(1, 61):
				for angle in 64:
					var a := float(angle) * TAU / 64.0
					var candidate := old + Vector3(cos(a), 0, sin(a)) * float(radius)
					if _ore_land(terrain, candidate):
						point = candidate
						found = true
						break
				if found:
					break
			assert(found, "No non-bridge resource destination " + path)
		point.y = terrain.sample_height(point.x, point.z)
		positions[str(ore.name)] = point
		if point.distance_to(old) > 0.05:
			moved.append({"name": ore.name, "from": str(old), "to": str(point)})
		ore.free()
	var lines := FileAccess.get_file_as_string(path).split("\n")
	var name := ""
	var parent := ""
	for i in lines.size():
		var line := lines[i].strip_edges()
		if line.begins_with("[node"):
			name = line.get_slice('name="', 1).get_slice('"', 0)
			parent = line.get_slice('parent="', 1).get_slice('"', 0) if line.contains('parent="') else ""
		elif line.begins_with("transform = ") and parent == "Resources":
			var t: Transform3D = str_to_var(line.get_slice(" = ", 1))
			t.origin = positions[name]
			lines[i] = "transform = " + var_to_str(t)
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string("\n".join(lines))
	file.close()
	records.append({"path": path, "resource_count": positions.size(), "relocated": moved})
	map.queue_free()
	await process_frame

func _ore_land(terrain: Node, point: Vector3) -> bool:
	if point.x < 4 or point.z < 4 or point.x > 508 or point.z > 508 or terrain.is_ground_blocked(point):
		return false
	for rect in terrain._bridge_rects:
		if rect.grow(1.0).has_point(Vector2(point.x, point.z)):
			return false
	return true

func _migrate(path: String, old_span: float) -> void:
	var text := FileAccess.get_file_as_string(path)
	# Idempotence: never expand an already converted scene.
	if text.contains("size = Vector2(512, 512)") or text.contains("size = Vector2(512.0, 512.0)"):
		return
	var backup := OUT + path.get_file() + ".before"
	if FileAccess.file_exists(backup):
		push_error("Refusing to overwrite baseline backup " + backup)
		quit(1)
		return
	DirAccess.copy_absolute(ProjectSettings.globalize_path(path), ProjectSettings.globalize_path(backup))
	var factor := 512.0 / old_span
	var plain := path.ends_with("PlainAndSimple.tscn")
	var lines := text.split("\n")
	var node_name := ""
	var node_parent := ""
	var sub_type := ""
	var in_root := false
	for i in lines.size():
		var line := lines[i].strip_edges()
		if line.begins_with("["):
			node_name = ""
			sub_type = ""
			in_root = false
			if line.begins_with("[node"):
				node_name = line.get_slice('name="', 1).get_slice('"', 0)
				node_parent = line.get_slice('parent="', 1).get_slice('"', 0) if line.contains('parent="') else ""
				in_root = node_parent.is_empty()
			elif line.begins_with("[sub_resource"):
				sub_type = line.get_slice('type="', 1).get_slice('"', 0)
			continue
		if not line.contains(" = "):
			continue
		var key := line.get_slice(" = ", 0)
		var raw := line.substr(line.find(" = ") + 3)
		if key == "size" and in_root:
			lines[i] = "size = Vector2(512, 512)"
		elif key == "scale" and in_root:
			assert(str_to_var(raw).is_equal_approx(Vector3.ONE), "Unexpected preexisting root scale")
		elif key == "semantic_span":
			lines[i] = "semantic_span = 512.0"
		elif key == "world_scale":
			lines[i] = "world_scale = 1.0"
		elif key == "shader_parameter/mask_world_size":
			lines[i] = key + " = 512.0"
		elif key == "transform":
			var t: Transform3D = str_to_var(raw)
			t.origin *= Vector3(factor, 1, factor)
			if node_parent in ["Decorations", "Visual"] or (node_parent.begins_with("Bridge") and node_name.begins_with("P")):
				t.basis = Basis.from_scale(Vector3(factor, 1, factor)) * t.basis
			lines[i] = "transform = " + var_to_str(t)
		elif key == "size" and sub_type in ["BoxShape3D", "BoxMesh"]:
			var v: Vector3 = str_to_var(raw)
			lines[i] = "size = " + var_to_str(v * Vector3(factor, 1, factor))
		elif plain and key == "size" and sub_type == "PlaneMesh":
			lines[i] = "size = Vector2(512, 512)"
		elif plain and key == "center_offset" and sub_type == "PlaneMesh":
			lines[i] = "center_offset = Vector3(256, 0, 256)"
	if plain:
		for i in lines.size():
			if lines[i].begins_with("[gd_scene"):
				lines[i] = '[gd_scene load_steps=7 format=3 uid="uid://cbe63rdjw7y4p"]'
			if lines[i].begins_with('[ext_resource type="Material"'):
				lines[i] += '\n[ext_resource type="Script" path="res://source/match/maps/generated/GeneratedTerrain.gd" id="4_terrain"]'
			if lines[i].begins_with('[node name="Terrain"'):
				lines[i] += '\nscript = ExtResource("4_terrain")\nheight_data_path = "res://source/match/maps/plain512/height_data.bin"\nsemantic_span = 512.0\nworld_scale = 1.0'
		_write_flat_data()
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string("\n".join(lines))
	file.close()
	# Load a separate map to project legacy out-of-bounds/blocked resources onto land.
	var map = load(path).instantiate()
	root.add_child(map)
	await process_frame
	var terrain = map.get_node("Geometry/Terrain")
	var moved: Array = []
	var resources = map.get_node("Resources").get_children()
	for ore in resources:
		var p: Vector3 = ore.position
		var bounded := Vector3(clampf(p.x, 4.0, 508.0), p.y, clampf(p.z, 4.0, 508.0))
		var target: Vector3 = terrain.clamp_ground_destination(bounded)
		if Vector2(target.x, target.z).distance_to(Vector2(p.x, p.z)) > 0.05:
			moved.append({"name": ore.name, "from": str(p), "to": str(target)})
		ore.position = target
	# Update only serialized resource positions; no pack() of runtime-mutated nodes.
	node_name = ""
	node_parent = ""
	for i in lines.size():
		var line := lines[i].strip_edges()
		if line.begins_with("[node"):
			node_name = line.get_slice('name="', 1).get_slice('"', 0)
			node_parent = line.get_slice('parent="', 1).get_slice('"', 0) if line.contains('parent="') else ""
		elif line.begins_with("transform = ") and node_parent == "Resources":
			var t: Transform3D = str_to_var(line.get_slice(" = ", 1))
			t.origin = map.get_node("Resources/" + node_name).position
			lines[i] = "transform = " + var_to_str(t)
	file = FileAccess.open(path, FileAccess.WRITE)
	file.store_string("\n".join(lines))
	file.close()
	var row := {"path": path, "old_span": old_span, "new_span": 512, "resource_count": resources.size(), "relocated": moved}
	if not plain:
		# Signed shader distances are metres too, not source-raster coordinates.
		var mask_path := path.get_base_dir() + "/terrain_masks.png"
		DirAccess.copy_absolute(ProjectSettings.globalize_path(mask_path), ProjectSettings.globalize_path(OUT + path.get_file() + ".mask.before"))
		var mask := Image.load_from_file(ProjectSettings.globalize_path(mask_path))
		for z in mask.get_height():
			for x in mask.get_width():
				var c := mask.get_pixel(x, z)
				mask.set_pixel(x, z, Color(clampf((c.r - 0.5) * factor + 0.5, 0, 1), clampf((c.g - 0.5) * factor + 0.5, 0, 1), clampf((c.b - 0.5) * factor + 0.5, 0, 1), c.a))
		mask.save_png(ProjectSettings.globalize_path(mask_path))
		var index_path := path.get_base_dir() + "/map_index.json"
		DirAccess.copy_absolute(ProjectSettings.globalize_path(index_path), ProjectSettings.globalize_path(OUT + path.get_file() + ".index.before"))
		var index: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(index_path))
		index["size"] = [512, 512]
		index["cell_m"] = 2.0
		index["export_contract_version"] = "world-meters-v2"
		index["source_size"] = [256, 256]
		file = FileAccess.open(index_path, FileAccess.WRITE)
		file.store_string(JSON.stringify(index, "\t"))
		file.close()
	records.append(row)
	print("MAP512_MIGRATE ", JSON.stringify(row))
	map.queue_free()
	await process_frame

func _write_flat_data() -> void:
	var folder := ROOT + "plain512/"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(folder))
	var file := FileAccess.open(folder + "height_data.bin", FileAccess.WRITE)
	file.store_32(257)
	file.store_32(257)
	for _i in 257 * 257:
		file.store_float(0.6)
	file.close()
	var mask := Image.create(257, 257, false, Image.FORMAT_RGBA8)
	mask.fill(Color(1.0, 1.0, 1.0, 0.5))
	mask.save_png(folder + "terrain_masks.png")
