extends Node3D

# air needs to be put on separate map so that air agents do not collide with terrain ones:
@onready var navigation_map_rid = NavigationServer3D.map_create()

@onready var _navigation_region = find_child("NavigationRegion3D")
@onready var _reference_static_collider_shape = find_child("CollisionShape3D")


func _ready():
	assert(_safety_checks())
	_ensure_navigation_map()
	_reference_static_collider_shape.global_transform.origin.y = Constants.Match.Air.Y


## **确保空域地图可用**（创建/重建 + 参数 + 挂 region + 激活）。
##
## 【为什么要有这一步（2026-09-14 U1 实测）】`Navigation._release_server_owned_navigation_resources()`
## 会在对局加载流程里调用 `release_navigation_map()` **free 掉本节点的地图 RID**；
## 若同一场景节点被复用（`_ready` 早已跑过、`@onready` 不会重跑），随后 `bake()` 里的
## `region_set_map(region, 失效RID)` 会把 region 挂到**默认世界地图**上
## （所以 `region_get_map().is_valid()` 仍为 true，极具迷惑性），而
## `navigation_map_rid` 已经是失效 RID → `map_set_active(true)` 静默无效 →
## 空域查路恒 `navmesh_unavailable` → 无人机被判"没路"（档案 608 次 `no_path` 的真因）。
## 所以在**每次烘焙前**都保证 RID 有效（失效就重建），而不是只在 `_ready` 里建一次。
func _ensure_navigation_map() -> void:
	if not navigation_map_rid.is_valid():
		print("NAVDBG air map RID invalid -> recreating")
		navigation_map_rid = NavigationServer3D.map_create()
	NavigationServer3D.map_set_cell_size(navigation_map_rid, Constants.Match.Air.Navmesh.CELL_SIZE)
	NavigationServer3D.map_set_cell_height(
		navigation_map_rid, Constants.Match.Air.Navmesh.CELL_HEIGHT
	)
	NavigationServer3D.region_set_map(_navigation_region.get_region_rid(), navigation_map_rid)
	NavigationServer3D.map_force_update(navigation_map_rid)
	NavigationServer3D.map_set_active(navigation_map_rid, true)


## 释放由本节点通过 NavigationServer3D 直接创建的空域地图 RID。
func release_navigation_map():
	if not navigation_map_rid.is_valid():
		return
	NavigationServer3D.map_set_active(navigation_map_rid, false)
	NavigationServer3D.free_rid(navigation_map_rid)
	navigation_map_rid = RID()


## 调整空中参考碰撞体后等待 PhysicsServer 同步，再据此烘焙运行时 NavMesh。
func bake(map):
	if OS.get_environment("NAVDBG_SKIP_AIR") != "":
		print("NAVDBG air.bake SKIPPED (experiment)")
		return
	# 烘焙前先保证地图可用（可能在上一局 teardown 里被 free 过，见 `_ensure_navigation_map`）。
	_ensure_navigation_map()
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
	# 【U1 修复 · 2026-09-14】烘焙完成后**显式再激活**空域地图。
	# 实测（`u1air` 局）：空域网格确实烘出来了（`polygons=2 vertices=4`、`region_map_valid=true`），
	# 但此刻 `map_active=false` → `NavigationServer3D.map_get_closest_point_owner` 对空域恒非法
	# → `op=adjutant_nav_path` 对无人机恒返回 `navmesh_unavailable` → 副官把无人机判成"没路"
	# （档案 `archive_5d6cdb0e` 里 608 次 `no_path` 的真因；计划 U1 点名要查的就是它）。
	# 语义上 "网格烘好了就该能用"，所以这里以实际状态为准再激活一次（幂等）。
	NavigationServer3D.map_set_active(navigation_map_rid, true)
	# 【U1 诊断 · 2026-09-14】空域烘焙结果必须留痕：地面烘焙一直打 `NAVDBG polygons=…`，
	# 而空域**成功路径一行都不打** —— 于是"无人机查不到路"到底是"网格没烘出来"
	# 还是"查询点写错"在日志上无法分辨（当天实测就卡在这里：`op=adjutant_nav_path`
	# 对空域恒返回 `navmesh_unavailable`，档案里折叠成 608 次 `no_path`）。
	# 这里补上与地面**同形状**的一行，并额外打印 region 挂在哪个 map 上。
	var air_mesh: NavigationMesh = _navigation_region.navigation_mesh
	print("NAVDBG air polygons=", air_mesh.get_polygon_count(), " vertices=",
		air_mesh.get_vertices().size(), " rid_valid=", navigation_map_rid.is_valid(),
		 " region_on_our_map=",
		NavigationServer3D.region_get_map(_navigation_region.get_region_rid()) == navigation_map_rid,
		 " map_active=", NavigationServer3D.map_is_active(navigation_map_rid))


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
