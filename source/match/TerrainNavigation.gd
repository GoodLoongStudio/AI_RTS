extends Node3D

const DOMAIN = Constants.Match.Navigation.Domain.TERRAIN

static var server_busy := false

## 导航烘焙版本号（副官 P0 要求）：**每次成功换入**新网格 +1。
## 用途：副官侧判断"路径查询用的网格是哪一版"，避免把旧网格算出的路径当成当前可用
## （计划 §7：移动任务必须记录 `nav_revision`）。没有它就只能靠猜，而计划禁止猜。
var bake_revision := 0

var _earliest_frame_to_perform_next_rebake = null
var _is_baking = false
var _rebake_queued := false
var _map_geometry = NavigationMeshSourceGeometryData3D.new()
## 运行时重烘的双缓冲目标：烘焙完成后才换入正在使用的 region。
var _pending_navmesh: NavigationMesh = null

@onready var navigation_map_rid = get_world_3d().navigation_map

@onready var _navigation_region = find_child("NavigationRegion3D")


func _ready():
	# Runtime baking should use physics geometry. Parsing MeshInstance3D geometry forces
	# a GPU -> CPU readback and Godot 4.7 reports it as a runtime performance warning.
	_navigation_region.navigation_mesh.geometry_parsed_geometry_type = (
		NavigationMesh.PARSED_GEOMETRY_STATIC_COLLIDERS
	)
	assert(_safety_checks())
	NavigationServer3D.map_set_cell_size(
		navigation_map_rid, Constants.Match.Terrain.Navmesh.CELL_SIZE
	)
	NavigationServer3D.map_set_cell_height(
		navigation_map_rid, Constants.Match.Terrain.Navmesh.CELL_HEIGHT
	)
	NavigationServer3D.map_force_update(navigation_map_rid)
	MatchSignals.schedule_navigation_rebake.connect(_on_schedule_navigation_rebake)


func _process(_delta):
	if (
		not _is_baking
		and _earliest_frame_to_perform_next_rebake != null
		and get_tree().get_frame() >= _earliest_frame_to_perform_next_rebake
	):
		_is_baking = true
		_earliest_frame_to_perform_next_rebake = null
		_rebake()


func bake(map):
	while server_busy:
		await get_tree().process_frame
	_navigation_region.navigation_mesh = get_parent().copy_navmesh_settings(
		_navigation_region.navigation_mesh
	)
	_navigation_region.navigation_mesh.geometry_parsed_geometry_type = (
		NavigationMesh.PARSED_GEOMETRY_STATIC_COLLIDERS
	)
	# setting custom AABB for baking so that height of dynamic AABB is always the same
	# - without such setting, re-baking may yield different results depending on geometry height
	_navigation_region.navigation_mesh.filter_baking_aabb = AABB(
		Vector3.ZERO, Vector3(map.size.x, 5.0, map.size.y)
	)
	NavigationServer3D.parse_source_geometry_data(
		_navigation_region.navigation_mesh, _map_geometry, get_tree().root
	)
	for node in get_tree().get_nodes_in_group("terrain_navigation_input"):
		node.remove_from_group("terrain_navigation_input")
	server_busy = true
	# 异步烘焙：消除"实例化 Match（导航烘焙阻塞点）"的主线程阻塞尖峰。
	# 完成回调 _on_bake_finished 负责置回 server_busy 并同步 navmesh。
	NavigationServer3D.bake_from_source_geometry_data_async(
		_navigation_region.navigation_mesh, _map_geometry, _on_bake_finished
	)
	# 保持 bake() 的协程语义：Navigation.setup 的 await 链等首次烘焙完成后再继续。
	while server_busy:
		await get_tree().process_frame


func _rebake():
	if server_busy:
		_is_baking = false
		_rebake_queued = true
		return
	# parse geometry other than map itself
	var full_geometry = NavigationMeshSourceGeometryData3D.new()
	NavigationServer3D.parse_source_geometry_data(
		_navigation_region.navigation_mesh, full_geometry, get_tree().root
	)
	# add pre-parsed map geometry
	full_geometry.merge(_map_geometry)

	# 双缓冲(2026-09-11)：不要原地重烘"正在被使用"的那个 NavigationMesh。
	# Godot 的异步烘焙在完成前会清空目标资源的多边形，而 region 引用的正是它，
	# 于是建筑新建/拆除触发重烘的那几百毫秒里全地图单位都查不到路径 → 集体站桩
	# （实测：回基地/出兵指令发出后 path 长度为 0、单位纹丝不动）。
	# 改为烘焙到副本，完成回调里再原子换入。
	_pending_navmesh = _navigation_region.navigation_mesh.duplicate()
	server_busy = true
	NavigationServer3D.bake_from_source_geometry_data_async(
		_pending_navmesh, full_geometry, _on_bake_finished
	)


# TODO: remove whenever Godot fixes that on its side
func _sync_navmesh_changes():
	"""this function forces synchronization between server-level primitives and nodes"""
	NavigationServer3D.region_set_navigation_mesh(
		_navigation_region.get_region_rid(), _navigation_region.navigation_mesh
	)


func _safety_checks():
	assert(
		_navigation_region.navigation_mesh.geometry_parsed_geometry_type
		== NavigationMesh.PARSED_GEOMETRY_STATIC_COLLIDERS,
		"runtime terrain navmesh must parse static colliders, not rendering meshes"
	)
	assert(
		is_equal_approx(
			_navigation_region.navigation_mesh.agent_radius,
			Constants.Match.Terrain.Navmesh.MAX_AGENT_RADIUS
		),
		"Navmesh 'agent_radius' must match established constant"
	)
	assert(
		is_equal_approx(
			_navigation_region.navigation_mesh.cell_size, Constants.Match.Terrain.Navmesh.CELL_SIZE
		),
		"Navmesh 'cell_size' must match established constant"
	)
	assert(
		is_equal_approx(
			_navigation_region.navigation_mesh.cell_height,
			Constants.Match.Terrain.Navmesh.CELL_HEIGHT
		),
		"Navmesh 'cell_height' must match established constant"
	)
	return true


func _exit_tree():
	if MatchSignals.schedule_navigation_rebake.is_connected(_on_schedule_navigation_rebake):
		MatchSignals.schedule_navigation_rebake.disconnect(_on_schedule_navigation_rebake)
	if _is_baking:
		server_busy = false
		_is_baking = false


func _on_schedule_navigation_rebake(domain):
	if domain != DOMAIN or not is_inside_tree() or not FeatureFlags.allow_navigation_rebaking:
		return
	# （保留原有排队语义，未改动）
	if _is_baking or server_busy:
		_rebake_queued = true
		return
	if _earliest_frame_to_perform_next_rebake == null:
		_earliest_frame_to_perform_next_rebake = get_tree().get_frame() + 30


func _on_bake_finished():
	server_busy = false
	if not is_inside_tree():
		return
	if _pending_navmesh != null:
		# 原子换入新烘焙的网格：换入前的这一刻，region 仍在提供旧的可用网格。
		_navigation_region.navigation_mesh = _pending_navmesh
		_pending_navmesh = null
		# 烘焙版本 +1：**换入这一刻**才算新网格生效。
		# 副官侧据此判断"这次路径查询用的是哪一版网格"，避免把旧网格算出来的路径
		# 当成当前可用路径（计划 §7 要求记录 nav_revision）。
		bake_revision += 1
	_sync_navmesh_changes()
	_is_baking = false
	if _rebake_queued:
		_rebake_queued = false
		_earliest_frame_to_perform_next_rebake = get_tree().get_frame() + 30
