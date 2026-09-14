extends SceneTree

## 隔离诊断：TerrainNavigation 异步烘焙期的 0xC0000005 到底崩在哪一步。
## 不加载 Match.tscn，手工分步执行 TerrainNavigation 的烘焙链：
##   parse_source_geometry_data (同步) -> bake_from_pipeline (异步)
## 每步打印；崩在哪条打印后即为根因所在。

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var map_path := "res://source/match/maps/generated/16-0-7d337ce8be/map_16-0-7d337ce8be.tscn"
	print("DIAG step1 load map scene")
	var packed: PackedScene = load(map_path)
	if packed == null:
		print("DIAG FAIL load")
		quit(1)
		return
	print("DIAG step2 instantiate")
	var map = packed.instantiate()
	root.add_child(map)
	print("DIAG step3 find colliders")
	var colliders: Array[Node] = []
	var todo: Array[Node] = [map]
	while not todo.is_empty():
		var n: Node = todo.pop_back()
		todo.append_array(n.get_children())
		if n is StaticBody3D:
			colliders.append(n)
	print("DIAG static bodies: ", colliders.size())
	# 逐个统计碰撞形状规模（坏 shape/超大 poly 嫌疑排查）
	var total_shapes := 0
	for i in range(colliders.size()):
		var total_verts := 0
		for c in colliders[i].get_children():
			if c is CollisionShape3D and c.shape != null:
				total_shapes += 1
				if c.shape is ConcavePolygonShape3D:
					total_verts += c.shape.get_faces().size() / 3
				elif c.shape is ConvexPolygonShape3D:
					total_verts += c.shape.points.size()
		if total_verts > 200000:
			print("DIAG BIG body #", i, " ", colliders[i].name, " tris=", total_verts)
	print("DIAG total shapes: ", total_shapes)

	print("DIAG step4 parse source geometry (sync)")
	var navmesh := NavigationMesh.new()
	navmesh.geometry_parsed_geometry_type = NavigationMesh.PARSED_GEOMETRY_STATIC_COLLIDERS
	navmesh.cell_size = 0.3
	navmesh.cell_height = 0.6
	navmesh.agent_max_climb = 0.0
	navmesh.agent_max_slope = 45.0
	var geometry := NavigationMeshSourceGeometryData3D.new()
	NavigationServer3D.parse_source_geometry_data(
		navmesh, geometry, map)
	print("DIAG parse done: ", geometry.get_triangle_count(), " triangles")

	print("DIAG step5 bake_from_source_geometry_data_async")
	var t0 := Time.get_ticks_msec()
	NavigationServer3D.bake_from_source_geometry_data_async(
		navmesh, geometry, _on_bake_done)
	print("DIAG bake dispatched")
	var done := false
	while not done and Time.get_ticks_msec() - t0 < 180000:
		await physics_frame
		if Time.get_ticks_msec() - t0 > 500 and Time.get_ticks_msec() % 1000 < 40:
			print("DIAG waiting... ", Time.get_ticks_msec() - t0, " ms")

func _on_bake_done() -> void:
	print("DIAG BAKE CALLBACK fired at ", Time.get_ticks_msec())
	var probe := NavigationServer3D.map_get_closest_point(
		root.get_world_3d().navigation_map, Vector3(500, 1, 500))
	print("DIAG probe=", probe)
	print("DIAG COMPLETE")
	quit(0)
