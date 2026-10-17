extends Node3D

## 阶段 4 判定实验 v5：单障碍受控场景，改用官方显式烘焙 API。
## 变量矩阵：radius / vertices / obstacle scale / 自带的 CollisionShape3D（物理体是否也参与烘焙）

var _region: NavigationRegion3D
var _nm: NavigationMesh
var _map_rid: RID
var _obstacle: NavigationObstacle3D
var _shape_holder: Node3D
var _agent := 2.8


func _ready():
	var ground := StaticBody3D.new()
	ground.name = "Ground"
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(300, 1, 300)
	cs.shape = box
	ground.add_child(cs)
	ground.position = Vector3(0, -0.5, 0)
	add_child(ground)

	_region = NavigationRegion3D.new()
	_nm = NavigationMesh.new()
	_nm.agent_radius = _agent
	_nm.cell_size = 0.25
	_nm.cell_height = 0.25
	_nm.geometry_parsed_geometry_type = NavigationMesh.PARSED_GEOMETRY_STATIC_COLLIDERS
	_nm.geometry_source_geometry_mode = NavigationMesh.SOURCE_GEOMETRY_ROOT_NODE_CHILDREN
	_nm.geometry_collision_mask = 0xFFFFFFFF
	_region.navigation_mesh = _nm
	add_child(_region)
	await _bake("① 无遮挡")
	print("[NB] ① 基线：polys=%d verts=%d 洞=%.1f" % [
		_nm.get_polygon_count(), _nm.get_vertices().size(), await _boundary()])

	_obstacle = NavigationObstacle3D.new()
	_obstacle.radius = 7.0
	_obstacle.affect_navigation_mesh = true
	add_child(_obstacle)
	await _bake("② radius=7 verts=0")
	print("[NB] ② radius=7.0 verts=0 scale=1：polys=%d 洞=%.1f（radius 预测 9.8）" % [
		_nm.get_polygon_count(), await _boundary()])

	_obstacle.vertices = _octagon(1.4)
	await _bake("③ radius=7 verts外缘1.4")
	print("[NB] ③ radius=7.0 verts外缘=1.4：洞=%.1f（vertices 预测 4.2 / radius 预测 9.8）" % await _boundary())

	_obstacle.radius = 1.0
	await _bake("④ radius=1 verts外缘1.4")
	print("[NB] ④ radius=1.0 verts外缘=1.4：洞=%.1f" % await _boundary())

	_obstacle.vertices = _octagon(5.0)
	await _bake("⑤ radius=1 verts外缘5")
	print("[NB] ⑤ radius=1.0 verts外缘=5.0：洞=%.1f（vertices 预测 7.8）" % await _boundary())

	_obstacle.scale = Vector3(3, 3, 3)
	await _bake("⑥ scale=3")
	print("[NB] ⑥ radius=1.0 verts外缘=5.0 scale=3：洞=%.1f（×3 预测 17.8）" % await _boundary())
	_obstacle.scale = Vector3.ONE

	# ⑦ 物理体是否也参与烘焙：给障碍挂一个半径 2.333 的圆柱（世界 7.0）
	_shape_holder = Node3D.new()
	var phys := StaticBody3D.new()
	var pcs := CollisionShape3D.new()
	var cyl := CylinderShape3D.new()
	cyl.radius = 2.333
	cyl.height = 1.6
	pcs.shape = cyl
	phys.add_child(pcs)
	phys.scale = Vector3(3, 3, 3)
	_shape_holder.add_child(phys)
	add_child(_shape_holder)
	_obstacle.affect_navigation_mesh = false
	_obstacle.vertices = PackedVector3Array()
	await _bake("⑦ 物理圆柱(世界7.0) + 障碍关闭")
	print("[NB] ⑦ 只有 CollisionShape3D(世界半径 7.0)、障碍关闭：洞=%.1f（若≈9.8 说明物理体参与烘焙）" % await _boundary())

	get_tree().quit(0)


func _octagon(outer: float) -> PackedVector3Array:
	var pts := PackedVector3Array()
	for i in 8:
		var a := TAU * float(i) / 8.0
		pts.append(Vector3(cos(a) * outer, 0, sin(a) * outer))
	return pts


func _bake(tag: String) -> void:
	for _f in range(3):
		await get_tree().physics_frame
	var source := NavigationMeshSourceGeometryData3D.new()
	NavigationServer3D.parse_source_geometry_data(_nm, source, self)
	NavigationServer3D.bake_from_source_geometry_data(_nm, source)
	_region.navigation_mesh = _nm
	_map_rid = _region.get_navigation_map()
	for _f in range(4):
		await get_tree().physics_frame
	print("[NB]   bake(%s): source_verts=%d polys=%d regions=%d" % [
		tag, source.get_vertices().size(), _nm.get_polygon_count(),
		NavigationServer3D.map_get_regions(_map_rid).size()])


func _boundary() -> float:
	if not _map_rid.is_valid():
		return -2.0
	var d := 1.0
	while d <= 60.0:
		var p := Vector3(d, 0, 0)
		var closest: Vector3 = NavigationServer3D.map_get_closest_point(_map_rid, p)
		if Vector2(closest.x - p.x, closest.z - p.z).length() < 0.4:
			return d
		d += 0.5
	return -1.0
