extends Node3D

# air needs to be put on separate map so that air agents do not collide with terrain ones:
@onready var navigation_map_rid = NavigationServer3D.map_create()

@onready var _navigation_region = find_child("NavigationRegion3D")
@onready var _reference_static_collider_shape = find_child("CollisionShape3D")


func _ready():
	assert(_safety_checks())
	NavigationServer3D.map_set_cell_size(navigation_map_rid, Constants.Match.Air.Navmesh.CELL_SIZE)
	NavigationServer3D.map_set_cell_height(
		navigation_map_rid, Constants.Match.Air.Navmesh.CELL_HEIGHT
	)
	NavigationServer3D.region_set_map(_navigation_region.get_region_rid(), navigation_map_rid)
	NavigationServer3D.map_force_update(navigation_map_rid)
	NavigationServer3D.map_set_active(navigation_map_rid, true)
	_reference_static_collider_shape.global_transform.origin.y = Constants.Match.Air.Y


## 释放由本节点通过 NavigationServer3D 直接创建的空域地图 RID。
func release_navigation_map():
	if not navigation_map_rid.is_valid():
		return
	NavigationServer3D.map_set_active(navigation_map_rid, false)
	NavigationServer3D.free_rid(navigation_map_rid)
	navigation_map_rid = RID()


## 调整空中参考碰撞体后等待 PhysicsServer 同步，再据此烘焙运行时 NavMesh。
func bake(map):
	var terrain_navigation = get_parent().terrain
	while terrain_navigation.server_busy:
		await get_tree().process_frame
	_navigation_region.navigation_mesh = get_parent().copy_navmesh_settings(
		_navigation_region.navigation_mesh
	)
	var shape = BoxShape3D.new()
	shape.size = Vector3(map.size.x, 0, map.size.y)
	_reference_static_collider_shape.shape = shape
	_reference_static_collider_shape.global_transform.origin.x = map.size.x / 2.0
	_reference_static_collider_shape.global_transform.origin.z = map.size.y / 2.0
	await get_tree().physics_frame
	await get_tree().physics_frame
	terrain_navigation.server_busy = true
	# on_thread：烘焙移到后台线程，完成后 bake_finished 信号唤醒本协程。
	var air_baked: Array = [false]
	var on_air_baked: Callable = func(): air_baked[0] = true
	_navigation_region.bake_finished.connect(on_air_baked, CONNECT_ONE_SHOT)
	_navigation_region.bake_navigation_mesh(true)
	while not air_baked[0]:
		await get_tree().process_frame
	await get_tree().process_frame
	terrain_navigation.server_busy = false


func _safety_checks():
	assert(
		is_equal_approx(
			_navigation_region.navigation_mesh.agent_radius,
			Constants.Match.Air.Navmesh.MAX_AGENT_RADIUS
		),
		"Navmesh 'agent_radius' must match established constant"
	)
	assert(
		is_equal_approx(
			_navigation_region.navigation_mesh.cell_size, Constants.Match.Air.Navmesh.CELL_SIZE
		),
		"Navmesh 'cell_size' must match established constant"
	)
	assert(
		is_equal_approx(
			_navigation_region.navigation_mesh.cell_height, Constants.Match.Air.Navmesh.CELL_HEIGHT
		),
		"Navmesh 'cell_height' must match established constant"
	)
	return true
