extends SceneTree
## 隔离测试：高度场 trimesh 能否被 recast 烘焙成导航网格。
## 分别测试 (a) 开放单面高度场 trimesh, (b) 封闭固体高度场 trimesh。
func _bake_count(mesh: Mesh, label: String) -> void:
	var body := StaticBody3D.new()
	body.collision_layer = 2
	body.collision_mask = 0
	body.add_to_group("terrain_navigation_input")
	var cs := CollisionShape3D.new()
	cs.shape = mesh.create_trimesh_shape()
	body.add_child(cs)
	root.add_child(body)
	await process_frame
	var nm := NavigationMesh.new()
	nm.geometry_parsed_geometry_type = NavigationMesh.PARSED_GEOMETRY_STATIC_COLLIDERS
	nm.geometry_source_group_name = "terrain_navigation_input"
	nm.cell_size = 0.3
	nm.cell_height = 0.3
	nm.agent_height = 1.8
	nm.agent_radius = 0.9
	nm.agent_max_climb = 0.5
	nm.filter_baking_aabb = AABB(Vector3.ZERO, Vector3(256, 5, 256))
	var region := NavigationRegion3D.new()
	region.navigation_mesh = nm
	root.add_child(region)
	await process_frame
	region.bake_navigation_mesh(false)
	await process_frame
	print("BAKE ", label, " polygons=", nm.get_polygon_count())
	body.queue_free()
	region.queue_free()


func _init() -> void:
	await process_frame
	var map = load("res://source/match/maps/generated/16-0/map_16-0.tscn").instantiate()
	root.add_child(map)
	await process_frame
	await process_frame
	var terrain = map.find_child("Terrain", true, false)
	var mesh: Mesh = terrain.mesh
	print("TEST mesh verts class=", mesh.get_class())
	await _bake_count(mesh, "open_heightfield")
	quit(0)
