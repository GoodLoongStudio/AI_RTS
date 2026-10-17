extends Node3D

## 受控实验：NavigationObstacle3D 的 vertices 在烘焙时是否跟随障碍旋转。
## 细长矩形（沿局部 X 半长 6、半宽 0.5），分别 yaw=0 / yaw=90° 烘焙，
## 沿世界 +X 量洞边：跟随旋转 ⇒ yaw=90 时洞边≈0.5+agent；忽略旋转 ⇒ 仍≈6+agent。
## 同时打印 avoidance_enabled 的默认值。

var _region: NavigationRegion3D
var _nm: NavigationMesh
var _map_rid: RID
var _obstacle: NavigationObstacle3D


func _ready():
	var ground := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(100, 1, 100)
	cs.shape = box
	ground.add_child(cs)
	ground.position = Vector3(0, -0.5, 0)
	add_child(ground)
	_region = NavigationRegion3D.new()
	_nm = NavigationMesh.new()
	_nm.agent_radius = 0.9
	_nm.cell_size = 0.3
	_nm.cell_height = 0.4
	_nm.geometry_parsed_geometry_type = NavigationMesh.PARSED_GEOMETRY_STATIC_COLLIDERS
	_nm.geometry_source_geometry_mode = NavigationMesh.SOURCE_GEOMETRY_ROOT_NODE_CHILDREN
	_nm.geometry_collision_mask = 0xFFFFFFFF
	_region.navigation_mesh = _nm
	add_child(_region)
	_obstacle = NavigationObstacle3D.new()
	print("[ROT] default avoidance_enabled=%s" % str(_obstacle.avoidance_enabled))
	_obstacle.affect_navigation_mesh = true
	_obstacle.vertices = PackedVector3Array([
		Vector3(-6, 0, -0.5), Vector3(6, 0, -0.5), Vector3(6, 0, 0.5), Vector3(-6, 0, 0.5)])
	add_child(_obstacle)
	await _bake()
	print("[ROT] yaw=0  +X 洞边=%.2f  +Z 洞边=%.2f" % [_boundary(Vector3.RIGHT), _boundary(Vector3.BACK)])
	_obstacle.rotation = Vector3(0, PI / 2.0, 0)
	await _bake()
	print("[ROT] yaw=90 +X 洞边=%.2f  +Z 洞边=%.2f" % [_boundary(Vector3.RIGHT), _boundary(Vector3.BACK)])
	get_tree().quit(0)


func _bake() -> void:
	for _f in range(3):
		await get_tree().physics_frame
	var source := NavigationMeshSourceGeometryData3D.new()
	NavigationServer3D.parse_source_geometry_data(_nm, source, self)
	NavigationServer3D.bake_from_source_geometry_data(_nm, source)
	_region.navigation_mesh = _nm
	_map_rid = _region.get_navigation_map()
	for _f in range(4):
		await get_tree().physics_frame


func _boundary(direction: Vector3) -> float:
	var d := 0.1
	while d <= 30.0:
		var p := direction * d
		var closest: Vector3 = NavigationServer3D.map_get_closest_point(_map_rid, p)
		if Vector2(closest.x - p.x, closest.z - p.z).length() < 0.2:
			return d
		d += 0.1
	return -1.0
