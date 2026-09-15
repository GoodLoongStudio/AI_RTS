extends SceneTree
## 诊断：加载生成地图场景，打印 Terrain 网格/材质/高度统计。
func _init() -> void:
	await process_frame
	var map = load("res://source/match/maps/generated/16-0/map_16-0.tscn").instantiate()
	root.add_child(map)
	await process_frame
	await process_frame
	var terrain = map.find_child("Terrain", true, false)
	print("DIAG terrain node: ", terrain, " script: ", terrain.get_script())
	var mesh = terrain.mesh
	print("DIAG mesh: ", mesh, " class: ", mesh.get_class() if mesh else "null")
	if mesh is ArrayMesh:
		print("DIAG surfaces: ", mesh.get_surface_count())
		var arrays = mesh.surface_get_arrays(0)
		var verts = arrays[Mesh.ARRAY_VERTEX]
		print("DIAG verts: ", verts.size())
		var ymin = 1e9
		var ymax = -1e9
		for k in range(0, verts.size(), 997):
			ymin = min(ymin, verts[k].y)
			ymax = max(ymax, verts[k].y)
		print("DIAG y range: ", ymin, " .. ", ymax)
	print("DIAG material: ", terrain.material_override, " mesh material: ", (mesh.surface_get_material(0) if mesh is ArrayMesh else null))
	print("DIAG visible: ", terrain.visible, " global_pos: ", terrain.global_position)
	var f = FileAccess.open("res://source/match/maps/generated/16-0/height_data.bin", FileAccess.READ)
	print("DIAG height_data open: ", f != null, " size: ", (f.get_length() if f else -1))
	quit(0)
