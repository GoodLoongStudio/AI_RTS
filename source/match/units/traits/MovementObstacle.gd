extends NavigationObstacle3D

@export var domain = Constants.Match.Navigation.Domain.TERRAIN
@export var path_height_offset = 0.0
## true = 由 CollisionShape3D 的 XZ 包围网格反推 carve 顶点（默认）。
## 没有可读碰撞形状时才回退到 `radius` 圆环；非圆形脚印也可关掉并自填 vertices。
@export var carve_vertices_from_radius := true

const Structure = preload("res://source/match/units/Structure.gd")
const AiPerfStats = preload("res://source/match/players/simple-clairvoyant-ai/AiPerfStats.gd")

@onready var _match = find_parent("Match")
@onready var _unit = get_parent()


## carve 顶点环的段数。16 段时外接半径=radius，内切=0.981×radius，
## 对 0.25m 体素的导航烘焙已足够圆，且不显著增加 carve 多边形数。
const CARVE_SEGMENTS := 16


func _enter_tree() -> void:
	# 【2026-09-30 归一化后】父链 scale 恒为 1，不再需要 1/父缩放 的补偿。
	_sync_carve_vertices()
	if affect_navigation_mesh and not Constants.Match.Terrain.Navmesh.STRUCTURE_AVOIDANCE_ENABLED:
		avoidance_enabled = false


## 【2026-09-30 阶段 4 实测：carve 只看 vertices，radius 与物理体都不参与】
## 单障碍受控场景（tests/automated/_NavCarveLab.gd，每次改属性后真正重烘：
## NavigationServer3D.parse_source_geometry_data + bake_from_source_geometry_data）：
##   ② radius=7.0、vertices 为空      → 洞边界 1.0m（**完全没有洞**）
##   ③ radius=7.0、vertices 世界外缘 1.4 → 洞 4.0m（=1.4 + agent 2.8）
##   ④ 只把 radius 改成 1.0（vertices 不动）→ 洞 4.0m（**radius 与 carve 无关**）
##   ⑤ vertices 世界外缘改成 5.0       → 洞 8.0m（=5.0 + 2.8）
##   ⑥ 再乘 obstacle global scale 3    → 洞 18.0m（=5.0×3 + 2.8）
##   ⑦ 只留 CollisionShape3D（世界 7.0）、障碍 affect=false → 洞 1.0m（物理体不参与烘焙）
## 因此 09-29 那条"radius × scale + agent"的记录不能作为公式依据
## （那次 A/B 的读数来自另一套夹具，与本次受控实验冲突，以受控实验为准）。
##
## 本文件要修的真实缺陷：五栋建筑的 vertices 世界外缘只有 1.4m，于是主基地
## 脚下 4.2m 内仍是"可走的导航面"，**比 footprint 7.0m 还小** —— 寻路会把单位
## 送进建筑体内，再被碰撞/避让顶出来，表现为卡住、抖动、到不了目标。
## 几何外缘在实测里 = 1.4m（in-tree，obstacle global scale=1）。
##
## 修法：优先把 CollisionShape3D 的世界包围面写入 vertices，
## 令 carve 洞 = 碰撞包围网格 + navmesh.agent_radius；没有碰撞形状时才使用
## radius 作为保守回退。这样碰撞、导航和调试显示不会再各画一套圆。
## 想自定义非圆形脚印的单位把 `carve_vertices_from_radius` 关掉并自填 vertices。
## 【2026-09-30 形状化后】carve 用哪套几何：
##   true  = 用碰撞形状的世界包围面（长方体脚印 ⇒ 方形洞，贴形准，但直角容易卡单位）
##   false = 用 radius 生成圆形洞（RA3 的导航同理：物理体可以很精确，导航层用简化圆）
## 实测：五栋建筑换成 BoxShape3D 后方形洞让"绕墙/建楼中途"场景的单位卡住打转
## （stall 84 / repath 115 / escape 83，只走了 3.85m），故建筑/炮塔走圆形洞。
@export var carve_from_collision_bounds := true
## 只对 affect_navigation_mesh 的障碍生效（资源等不挖洞的障碍保持贴形）。
@export var carve_margin_m: float = Constants.Match.Terrain.Navmesh.STRUCTURE_CARVE_MARGIN_M

## carve 轮廓（含 margin、不含 agent 半径）在障碍本地 XZ 的矩形半宽；ZERO = 圆形轮廓。
var _carve_box_half := Vector2.ZERO
var _carve_outline_radius := 0.0


func effective_carve_margin() -> float:
	return maxf(carve_margin_m, 0.0) if affect_navigation_mesh else 0.0


## 从障碍中心朝 world_point 方向到 carve 轮廓的距离（不含 agent 半径）。
func carve_extent_toward(world_point: Vector3) -> float:
	if _carve_box_half == Vector2.ZERO:
		return _carve_outline_radius
	var local := global_transform.affine_inverse() * world_point
	var dx := absf(local.x)
	var dz := absf(local.z)
	if dx < 0.0001 and dz < 0.0001:
		return carve_extent_max()
	var t := INF
	if dx > 0.0001:
		t = minf(t, _carve_box_half.x / dx)
	if dz > 0.0001:
		t = minf(t, _carve_box_half.y / dz)
	return Vector2(dx, dz).length() * t


func carve_extent_max() -> float:
	if _carve_box_half == Vector2.ZERO:
		return _carve_outline_radius
	return _carve_box_half.length()


## 碰撞体沿世界方向的前伸（米）。不含导航 carve 的 agent 半径和 margin。
## 逻辑地形没有导航洞，出兵要贴这面墙，而不是贴外接对角。
func collision_extent_along(world_direction: Vector3) -> float:
	var flat := Vector3(world_direction.x, 0.0, world_direction.z)
	if flat.length_squared() < 0.000001:
		return 0.0
	if is_inside_tree():
		flat = global_transform.basis.inverse() * flat
	flat.y = 0.0
	if flat.length_squared() < 0.000001:
		return 0.0
	flat = flat.normalized()
	var vertices := _collision_bounds_vertices(0.0)
	if vertices.size() < 3:
		if _carve_outline_radius > 0.0:
			return _carve_outline_radius
		return float(radius)
	var extent := 0.0
	for vertex in vertices:
		extent = maxf(extent, Vector3(vertex.x, 0.0, vertex.z).dot(flat))
	return maxf(extent, 0.0)


func _sync_carve_vertices() -> void:
	if not carve_vertices_from_radius:
		return
	var margin := effective_carve_margin()
	var collision_vertices := _collision_bounds_vertices(margin) if carve_from_collision_bounds else PackedVector3Array()
	if collision_vertices.size() >= 4:
		vertices = collision_vertices
		_carve_box_half = Vector2(
			maxf(absf(collision_vertices[0].x), absf(collision_vertices[2].x)),
			maxf(absf(collision_vertices[0].z), absf(collision_vertices[2].z)))
		return
	_carve_box_half = Vector2.ZERO
	var world_radius := float(radius) + margin
	_carve_outline_radius = world_radius
	if float(radius) <= 0.0:
		return
	var world_scale := 1.0
	if is_inside_tree():
		world_scale = global_transform.basis.get_scale().x
	if world_scale <= 0.0001:
		return
	var local_radius := world_radius / world_scale
	var points := PackedVector3Array()
	for index in CARVE_SEGMENTS:
		var angle := TAU * float(index) / float(CARVE_SEGMENTS)
		points.append(Vector3(cos(angle) * local_radius, 0.0, sin(angle) * local_radius))
	vertices = points


## 用父单位真实 CollisionShape3D 的包围网格生成导航障碍轮廓。
## 这比把所有单位强行当圆形更稳定：长方体/旋转碰撞体会按其实际 XZ 包围面 carve。
func _collision_bounds_vertices(margin: float = 0.0) -> PackedVector3Array:
	if _unit == null:
		return PackedVector3Array()
	var shape_nodes: Array[CollisionShape3D] = []
	for child in _unit.find_children("*", "CollisionShape3D", true, false):
		var shape_node := child as CollisionShape3D
		if shape_node == null or shape_node.shape == null:
			continue
		if _shape_local_aabb(shape_node.shape).size.length_squared() <= 0.0:
			continue
		shape_nodes.append(shape_node)
	# 单个方盒：按旋转后的实际矩形外扩，避免 45° 摆放时世界 AABB 把洞放大约 √2 倍。
	if shape_nodes.size() == 1 and shape_nodes[0].shape is BoxShape3D:
		return _box_outline_vertices(shape_nodes[0], margin)
	var world_min := Vector2(1e20, 1e20)
	var world_max := Vector2(-1e20, -1e20)
	var found := false
	for shape_node in shape_nodes:
		var local_aabb := _shape_local_aabb(shape_node.shape)
		var p := local_aabb.position
		var s := local_aabb.size
		# Include all eight corners so rotated/non-uniformly transformed shapes are safe.
		for y in [p.y, p.y + s.y]:
			for x in [p.x, p.x + s.x]:
				for z in [p.z, p.z + s.z]:
					var world_corner: Vector3 = shape_node.global_transform * Vector3(x, y, z)
					world_min.x = minf(world_min.x, world_corner.x)
					world_min.y = minf(world_min.y, world_corner.z)
					world_max.x = maxf(world_max.x, world_corner.x)
					world_max.y = maxf(world_max.y, world_corner.z)
					found = true
	if not found:
		return PackedVector3Array()
	world_min -= Vector2(margin, margin)
	world_max += Vector2(margin, margin)
	var parent_inverse := global_transform.affine_inverse()
	var world_corners := [
		Vector3(world_min.x, global_position.y, world_min.y),
		Vector3(world_max.x, global_position.y, world_min.y),
		Vector3(world_max.x, global_position.y, world_max.y),
		Vector3(world_min.x, global_position.y, world_max.y),
	]
	var result := PackedVector3Array()
	for world_corner in world_corners:
		var local_corner: Vector3 = parent_inverse * world_corner
		result.append(Vector3(local_corner.x, 0.0, local_corner.z))
	return result


func _box_outline_vertices(shape_node: CollisionShape3D, margin: float) -> PackedVector3Array:
	var basis := shape_node.global_transform.basis
	var half := (shape_node.shape as BoxShape3D).size * 0.5
	var axis_x := Vector3(basis.x.x, 0.0, basis.x.z)
	var axis_z := Vector3(basis.z.x, 0.0, basis.z.z)
	if axis_x.length() < 0.0001 or axis_z.length() < 0.0001:
		return PackedVector3Array()
	var extent_x := axis_x.normalized() * (half.x * axis_x.length() + margin)
	var extent_z := axis_z.normalized() * (half.z * axis_z.length() + margin)
	var center := shape_node.global_position
	center.y = global_position.y
	var parent_inverse := global_transform.affine_inverse()
	var result := PackedVector3Array()
	for signs in [Vector2(-1, -1), Vector2(1, -1), Vector2(1, 1), Vector2(-1, 1)]:
		var local_corner: Vector3 = parent_inverse * (center + extent_x * signs.x + extent_z * signs.y)
		result.append(Vector3(local_corner.x, 0.0, local_corner.z))
	return result


## 【2026-10-01 提示词 §1A/§75 要求】显式报告形状支持状态，禁止"静默返回空 AABB 当作没有障碍"。
## 返回 "supported" 或 "unsupported:<类名>"；调用方（carve / 放置 / 调试）必须据此拒绝或走保守路径。
static func shape_support(shape: Shape3D) -> String:
	if shape == null:
		return "unsupported:null"
	if shape is CylinderShape3D or shape is SphereShape3D or shape is BoxShape3D or shape is CapsuleShape3D:
		return "supported"
	return "unsupported:" + shape.get_class()


func _shape_local_aabb(shape: Shape3D) -> AABB:
	if shape is CylinderShape3D:
		var cylinder := shape as CylinderShape3D
		return AABB(
			Vector3(-cylinder.radius, -cylinder.height * 0.5, -cylinder.radius),
			Vector3(cylinder.radius * 2.0, cylinder.height, cylinder.radius * 2.0)
		)
	if shape is SphereShape3D:
		var sphere := shape as SphereShape3D
		return AABB(
			Vector3(-sphere.radius, -sphere.radius, -sphere.radius),
			Vector3.ONE * sphere.radius * 2.0
		)
	if shape is BoxShape3D:
		var box := shape as BoxShape3D
		return AABB(-box.size * 0.5, box.size)
	if shape is CapsuleShape3D:
		var capsule := shape as CapsuleShape3D
		return AABB(
			Vector3(-capsule.radius, -capsule.height * 0.5, -capsule.radius),
			Vector3(capsule.radius * 2.0, capsule.height, capsule.radius * 2.0)
		)
	# 【提示词 §75】不支持的形状必须显式暴露，不能静默返回空 bounds 当作"没有障碍"。
	push_warning("[MovementObstacle] 不支持的碰撞形状 %s（实体=%s）⇒ 本障碍不会被正确读取" % [
		shape.get_class() if shape != null else "<null>", str(_unit.name) if _unit != null else "<no unit>"])
	return AABB()


# 2026-09-30 删除：原 _normalize_scale_for_carve() —— 把 obstacle 的 local scale 设成 1/父缩放
# 的补偿结构（计划明令禁止）。世界米制归一化后父链 scale 恒为 1，验证席确认它 0 调用点；
# carve 顶点由 _sync_carve_vertices() 按最终碰撞包围网格生成；无碰撞形状时才按 radius 回退。


func _ready():
	var perf_on := AiPerfStats.enabled()
	var carve_started := Time.get_ticks_usec() if perf_on else 0
	# 防御性重算：_enter_tree 时父链缩放理论上已定稿（建筑 root scale=3），
	# 但实例化顺序若不同（先入树再设 global_transform），碰撞包围网格换算基准会变；
	# 这里按最终的 global_transform 再算一次，保证 vertices 与最终碰撞包围网格一致。
	_sync_carve_vertices()
	if perf_on:
		AiPerfStats.add("spawn_carve", Time.get_ticks_usec() - carve_started)
	if _uses_logic_terrain():
		avoidance_enabled = false
		affect_navigation_mesh = false
		set_physics_process_internal(false)
		set_navigation_map(RID())
		_snap_to_ground()
		if "is_under_construction" in _unit and _unit.is_under_construction():
			if not _unit.constructed.is_connected(_register_logic_obstacle):
				_unit.constructed.connect(_register_logic_obstacle)
		else:
			call_deferred("_register_logic_obstacle")
		return
	await get_tree().process_frame  # wait for navigation to be operational
	if _match == null or _match.navigation == null:
		_snap_to_ground()
		return
	set_navigation_map(_match.navigation.get_navigation_map_rid_by_domain(domain))
	_align_unit_position_to_navigation()
	if "is_under_construction" in _unit and _unit.is_under_construction():
		# 施工中的建筑不阻挡寻路（虚化无碰撞体积）；完工信号后再加入导航障碍并重烘
		_unit.constructed.connect(_affect_navigation_if_needed)
	else:
		_affect_navigation_if_needed()


func _uses_logic_terrain() -> bool:
	if _match == null:
		return false
	# 唯一实现见 MatchUtils.is_logic_terrain_map（旧内联判据把普通地图误判成逻辑地形）。
	return Utils.Match.is_logic_terrain_map(_match.get_node_or_null("Map"))


func _exit_tree():
	_clear_logic_blocker()
	remove_from_group(Constants.Match.Navigation.DOMAIN_TO_OBSTACLE_GROUP_MAPPING[domain])
	if affect_navigation_mesh:
		remove_from_group(Constants.Match.Navigation.DOMAIN_TO_GROUP_MAPPING[domain])
		MatchSignals.schedule_navigation_rebake.emit(domain)


## 逻辑地形（无导航网格）上本障碍是否真的挡路：只有建筑会登记占用足迹，
## 资源点等不挖洞的障碍不参与"绕楼"落点选择。
func logic_footprint_blocks() -> bool:
	return _unit is Structure


## 交给逻辑地形占用格的**真实足迹**：世界 XZ 凸多边形（相对障碍中心）。
## 【2026-10-12 建筑卡单位】生成图没有导航网格，`GeneratedTerrain` 的圆形足迹（还要再乘
## `STRUCTURE_STAMP_RADIUS_SCALE=0.85`）是唯一的"楼在哪"判据：实测车厂外墙半宽 3.972/3.054、
## 角点 5.011，而判定圆只有 3.376 ⇒ 单位中心被允许进入楼体 0.6~1.64m，卡在墙角出不来。
## 所以这里直接把 carve 用的同一份碰撞包围面交给占用格——导航、碰撞、调试从此一套几何。
## 障碍本地尺度必须为 1（世界米制归一化后的既有约定），否则本地点不是米。
func logic_footprint_outline() -> PackedVector2Array:
	if _unit == null:
		return PackedVector2Array()
	# margin 传 0：导航足迹 == 碰撞体本身，靠近余量由调用方（落点/驱逐）自己加。
	var vertices := _collision_bounds_vertices(0.0)
	if vertices.size() < 3:
		return PackedVector2Array()
	var basis := global_transform.basis
	if absf(basis.get_scale().x - 1.0) > 0.001 or absf(basis.get_scale().z - 1.0) > 0.001:
		push_warning("[MovementObstacle] %s 障碍尺度≠1，逻辑足迹按本地坐标换算会失真" % str(_unit.name))
	var result := PackedVector2Array()
	for vertex in vertices:
		result.append(Vector2(vertex.x, vertex.z))
	return result


func _register_logic_obstacle() -> void:
	add_to_group(Constants.Match.Navigation.DOMAIN_TO_OBSTACLE_GROUP_MAPPING[domain])
	if not (_unit is Structure):
		return
	var occupancy := _logic_occupancy()
	if occupancy == null or not occupancy.has_method("set_structure_blocker"):
		if is_inside_tree():
			call_deferred("_retry_logic_blocker")
		return
	occupancy.set_structure_blocker(
		get_instance_id(), _unit.global_position, float(radius), _world_logic_footprint())


func _retry_logic_blocker() -> void:
	if not is_inside_tree() or not (_unit is Structure):
		return
	var occupancy := _logic_occupancy()
	if occupancy != null and occupancy.has_method("set_structure_blocker"):
		occupancy.set_structure_blocker(
			get_instance_id(), _unit.global_position, float(radius), _world_logic_footprint())


## 障碍本地多边形 → 世界 XZ 多边形（占用格只认世界坐标）。
func _world_logic_footprint() -> PackedVector2Array:
	var local := logic_footprint_outline()
	if local.size() < 3:
		return PackedVector2Array()
	var center := global_position
	var basis := global_transform.basis
	var result := PackedVector2Array()
	for point in local:
		var world: Vector3 = basis * Vector3(point.x, 0.0, point.y)
		result.append(Vector2(world.x + center.x, world.z + center.z))
	return result



func _clear_logic_blocker() -> void:
	var occupancy := _logic_occupancy()
	if occupancy != null and occupancy.has_method("clear_structure_blocker"):
		occupancy.clear_structure_blocker(get_instance_id())


func _logic_occupancy() -> Node:
	if _match == null:
		return null
	var map_node: Node = _match.get_node_or_null("Map")
	if map_node == null or not map_node.has_meta("water_occupancy"):
		return null
	var occupancy: Variant = map_node.get_meta("water_occupancy")
	return occupancy if occupancy is Node else null


func _snap_to_ground() -> void:
	if NetSession.is_client_puppet():
		return
	if _match != null and _match.has_method("ground_height_at") and _unit is Node3D:
		_unit.global_position.y = float(_match.ground_height_at(_unit.global_position))


func _align_unit_position_to_navigation():
	if _uses_logic_terrain():
		_snap_to_ground()
		return
	var navigation_map := get_navigation_map()
	var source_position: Vector3 = get_parent().global_transform.origin
	var closest_point_owner := NavigationServer3D.map_get_closest_point_owner(
		navigation_map, source_position
	)
	# Invalid owner means the closest-point result is only the zero sentinel;
	# preserve the authored/spawned position until a usable navigation region exists.
	if not closest_point_owner.is_valid():
		_snap_to_ground()
		return
	# XZ 取网格最近点，Y 取真实地表（2026-09-21 用户报"单位浮空"根因）：
	# Recast 体素量化把可走面抬到碰撞体顶面之上（实测平地图 +1.0~1.2m，
	# path_height_offset=0.6 补不齐），旧写法让建筑连同单位一起悬空 0.6m。
	var closest: Vector3 = NavigationServer3D.map_get_closest_point(navigation_map, source_position)
	_unit.global_transform.origin = Vector3(closest.x, source_position.y, closest.z)
	_snap_to_ground()


func _affect_navigation_if_needed():
	if affect_navigation_mesh:
		# 持久注册表：供移动侧做"落点是否落在避让圈内"的校验（该组不会被烘焙清空）。
		add_to_group(Constants.Match.Navigation.DOMAIN_TO_OBSTACLE_GROUP_MAPPING[domain])
		# 临时输入清单：交给下一次导航网格烘焙。
		add_to_group(Constants.Match.Navigation.DOMAIN_TO_GROUP_MAPPING[domain])
		MatchSignals.schedule_navigation_rebake.emit(domain)
