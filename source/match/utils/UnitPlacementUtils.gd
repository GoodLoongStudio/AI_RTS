enum { VALID, COLLIDES_WITH_AGENT, NOT_NAVIGABLE }


static func find_valid_position_radially(
	starting_position: Vector3, radius: float, navigation_map_rid: RID, scene_tree
):
	return find_valid_position_radially_yet_skip_starting_radius(
		starting_position, 0.0, radius, 0.0, Vector3(0, 0, 1), true, navigation_map_rid, scene_tree
	)


static func find_valid_position_radially_yet_skip_starting_radius(
	starting_position: Vector3,
	starting_radius: float,
	radius: float,
	spacing: float,
	starting_direction: Vector3,
	shuffle: bool,
	navigation_map_rid: RID,
	scene_tree,
	max_ring_count: int = -1,
	occupancy = null,
	ignored_units: Array = []
):
	var starting_position_yless = starting_position * Vector3(1, 0, 1)
	var units = (
		scene_tree.get_nodes_in_group("units") + scene_tree.get_nodes_in_group("resource_units")
	)
	var starting_distance = (
		0 if is_zero_approx(starting_radius) else starting_radius + radius + spacing
	)
	var starting_offset = 1 if is_zero_approx(starting_radius) else 0
	if (
		is_zero_approx(starting_radius)
		and _is_agent_placement_position_valid(
			starting_position_yless, radius, units, navigation_map_rid, occupancy, ignored_units
		)
	):
		return starting_position_yless
	var ring_end = 999999 if max_ring_count < 0 else starting_offset + max_ring_count
	for ring_number in range(starting_offset, ring_end):
		var ring_distance_from_starting_position: float = (
			starting_distance + radius * 0.5 * ring_number
		)
		var rotation_angle_rad = asin((radius + spacing) / ring_distance_from_starting_position)
		var radial_positions = []
		var next_rotation_angle_rad = 0.0
		while next_rotation_angle_rad <= PI * 2.0 - rotation_angle_rad:
			radial_positions.append(
				(
					starting_position_yless
					+ (
						starting_direction.normalized().rotated(Vector3.UP, next_rotation_angle_rad)
						* ring_distance_from_starting_position
					)
				)
			)
			next_rotation_angle_rad += rotation_angle_rad
		if shuffle:
			radial_positions.shuffle()
		for radial_position in radial_positions:
			if _is_agent_placement_position_valid(
				radial_position, radius, units, navigation_map_rid, occupancy, ignored_units
			):
				return radial_position
	if max_ring_count < 0:
		assert(false, "unexpected flow")
	return Vector3.INF


static func validate_agent_placement_position(
	position, radius, existing_units, navigation_map_rid, occupancy = null, ignored_units: Array = []
):
	for existing_unit in existing_units:
		# ignored_units：本次搜索的"东道主"（生产建筑/矿场）。它的 footprint 半径会
		# 把落点锁在 footprint 外沿，出兵因此永远离建筑很远（2026-09-29 实测兵营出步兵
		# 7.70m）。东道主自身不参与碰撞判定，落点由"模型外缘 + 单位半径 + spacing"
		# 的起始半径保证不嵌进模型。
		if ignored_units.has(existing_unit):
			continue
		if (
			(existing_unit.global_position * Vector3(1, 0, 1)).distance_to(
				position * Vector3(1, 0, 1)
			)
			<= existing_unit.radius + radius
		):
			return COLLIDES_WITH_AGENT
	var points_expected_to_be_navigable = []
	for x in [-1, 0, 1]:
		for z in [-1, 0, 1]:
			points_expected_to_be_navigable.append(
				position + Vector3(x, 0, z).normalized() * radius
			)
	if occupancy != null and occupancy.has_method("is_ground_blocked"):
		for point_expected_to_be_navigable in points_expected_to_be_navigable:
			if occupancy.is_ground_blocked(point_expected_to_be_navigable):
				return NOT_NAVIGABLE
		return VALID
	if not navigation_map_rid.is_valid():
		return NOT_NAVIGABLE
	for point_expected_to_be_navigable in points_expected_to_be_navigable:
		if not (point_expected_to_be_navigable * Vector3(1, 0, 1)).is_equal_approx(
			(
				NavigationServer3D.map_get_closest_point(
					navigation_map_rid, point_expected_to_be_navigable
				)
				* Vector3(1, 0, 1)
			)
		):
			return NOT_NAVIGABLE
	return VALID


static func _is_agent_placement_position_valid(
	position, radius, existing_units, navigation_map_rid, occupancy = null,
	ignored_units: Array = []
):
	return (
		validate_agent_placement_position(
			position, radius, existing_units, navigation_map_rid, occupancy, ignored_units
		)
		== VALID
	)


## 【2026-09-29 尺寸口径统一】生产/赠送单位的**世界角点出生点**算法（唯一实现，
## ProductionQueue.try_deploy_authoritative 与 OreRefinery._grant_free_miner 共用）。
##
## 为什么需要共用：09-27 统一尺寸后曾出现"一个按模型边缘、另一个按旧 radius"的两套
## 口径，导致同一种建筑送的矿车一个贴脸一个飞出去。现在只有这一个入口。
##
## 算法（与任务要求逐条对应）：
##   1. 遍历 producer 子树所有 GeometryInstance3D，取 AABB 8 个角点；
##   2. 用 instance.global_transform * corner 得到**世界角点**（root scale 天然进入，
##      不再用 affine_inverse 把缩放抵消掉）；
##   3. 世界角点减 producer.global_position，取 XZ 最大距离 = 模型世界外缘；
##   4. 方向取建筑局部 +Z 的世界朝向（建筑转 90° 出生方向跟着转）；
##   5. 起始半径 = max(模型外缘, 物理 footprint(fallback)) + produced_radius + spacing；
##   6. 建筑自身进 ignored_units，避免被自己的 MovementObstacle 推到 footprint 外；
##   7. 找不到 GeometryInstance3D 时用 producer.get("radius")（稳定物理 footprint）。
static func production_spawn_spot(
	producer: Node3D,
	produced_unit,
	spacing: float,
	navigation_map_rid: RID,
	scene_tree,
	max_ring_count: int = 24,
	occupancy = null,
	preferred_direction: Vector3 = Vector3.ZERO
):
	var produced_radius: float = float(produced_unit.get("radius")) if produced_unit.get("radius") != null else 0.5
	var origin: Vector3 = producer.global_position
	var facing: Vector3 = producer.global_transform.basis * Vector3(0, 0, 1)
	if preferred_direction.is_finite() and preferred_direction.length_squared() > 0.0001:
		facing = preferred_direction
	facing.y = 0.0
	if facing.length() < 0.001:
		facing = Vector3(0, 0, 1)
	facing = facing.normalized()
	# 逻辑地形（生成图）传入 occupancy，且不烘导航网格。选中圈平面的对角、血条、
	# 集结点标记都会被旧的整树 AABB 当成“模型外缘”；再加上并不存在的 agent_radius
	# 2.8 米，航空工厂把半径 2.2 米的飞机放到距中心 10.92 米。门口被邻楼挡住后，
	# 搜索继续外扩，单位落到基地外侧空地。这里只沿出门方向量模型和碰撞的前伸。
	var logic_terrain := occupancy != null
	var edge := 0.0
	var agent_radius := 0.0
	if logic_terrain:
		edge = _model_extent_along(producer, facing)
		var door := producer.find_child("MovementObstacle", false, false)
		if door != null and door.has_method("collision_extent_along"):
			edge = maxf(edge, float(door.collision_extent_along(facing)))
		if edge <= 0.0:
			var physical = producer.get("radius")
			edge = float(physical) if physical != null else 0.0
		# 径向采样会在落点周围再探一个单位半径。贴墙时对角采样擦到足迹边，
		# 整环会被判不可走。0.2 米只躲开这条边，不再把出生圈整体外推。
		edge += 0.2
	else:
		edge = _xz_corner_edge(producer, origin)
		if edge <= 0.0:
			var physical_nav = producer.get("radius")
			edge = float(physical_nav) if physical_nav != null else 0.0
		# 【2026-09-29 出生点过远根因】起始半径必须落在建筑自己的导航 carve 洞**之外**：
		# navmesh 烘焙按建筑几何体挖洞，洞半径 = body 世界半径 + navmesh 的 agent_radius
		# （实测车厂 8.35 + 2.80 = 11.15m）。旧实现只给 外缘 + 单位半径 + spacing
		# （8.35 + 2.0 + 0.1 = 10.45m），第一环整圈落在 carve 洞里被判 NOT_NAVIGABLE，
		# 径向搜索被迫逐环外扩 —— 实测矿车出生在距车厂 24.45m 处（用户报"出生点有问题"）。
		# 这不是"放大 buffer 掩盖问题"：agent_radius 是 carve 洞的组成部分，缺了它起始
		# 半径本身就不合法。取 navmesh 本体的 agent_radius，读不到按 2.8 兜底。
		agent_radius = navmesh_agent_radius(producer)
		var obstacle := producer.find_child("MovementObstacle", false, false)
		if obstacle != null and obstacle.has_method("carve_extent_max") and bool(obstacle.get("affect_navigation_mesh")):
			edge = maxf(edge, float(obstacle.carve_extent_max()))
	var start_radius := edge + agent_radius
	var placement = find_valid_position_radially_yet_skip_starting_radius(
		origin, start_radius, produced_radius, spacing, facing.normalized(), false,
		navigation_map_rid, scene_tree, max_ring_count, occupancy, [producer]
	)
	# 【2026-09-30 阶段 5 / 计划第 7 条】搜索失败时**不得**把未复验的"建筑前方一点"
	# 直接交给生成信号 —— 旧实现无条件返回它，等于绕过全部判据（可能与其它单位、
	# 建筑或资源重叠，也可能落在导航面之外/地图外）。现在用**同一套判据**复验一次：
	# 通过才采用；不通过就返回 `Vector3.INF` 明确表示"没有合法落点"，由调用方保持
	# 待部署/重试（GodotProductionDeploymentPort 收到 null 报 Blocked 并重试；
	# OreRefinery 收到 INF 会 free 掉临时实例并复位赠送标记，下个 tick 重试）。
	if placement == Vector3.INF:
		var fallback := origin + facing.normalized() * (start_radius + produced_radius + spacing)
		fallback.y = origin.y
		var fallback_units = (
			scene_tree.get_nodes_in_group("units")
			+ scene_tree.get_nodes_in_group("resource_units")
		)
		if _is_agent_placement_position_valid(
			fallback, produced_radius, fallback_units, navigation_map_rid, occupancy, [producer]
		):
			placement = fallback
	return placement


## 只看 Geometry 子树，沿出门方向的前伸。选中圈、血条、集结点标记不在这棵子树里。
static func _model_extent_along(producer: Node3D, direction: Vector3) -> float:
	var dir := Vector3(direction.x, 0.0, direction.z)
	if dir.length_squared() < 0.000001:
		return 0.0
	dir = dir.normalized()
	var geometry := producer.get_node_or_null("Geometry") as Node
	if geometry == null:
		return 0.0
	var origin := producer.global_position
	var extent := 0.0
	for node in geometry.find_children("*", "GeometryInstance3D", true, false):
		var instance := node as GeometryInstance3D
		if instance == null:
			continue
		if instance.has_meta("exclude_from_geometry_measurements"):
			continue
		var aabb: AABB = instance.get_aabb()
		if aabb.size.length() <= 0.0:
			continue
		var to_world: Transform3D = instance.global_transform
		for index in 8:
			var corner := Vector3(
				aabb.position.x + (aabb.size.x if index & 1 else 0.0),
				aabb.position.y + (aabb.size.y if index & 2 else 0.0),
				aabb.position.z + (aabb.size.z if index & 4 else 0.0))
			var world_corner: Vector3 = to_world * corner
			var offset := world_corner - origin
			extent = maxf(extent, Vector3(offset.x, 0.0, offset.z).dot(dir))
	return maxf(extent, 0.0)


## 导航图仍用整树 XZ 外接半径（含 carve 所需的外缘）。逻辑地形不走这里。
static func _xz_corner_edge(producer: Node3D, origin: Vector3) -> float:
	var edge := 0.0
	for node in producer.find_children("*", "GeometryInstance3D", true, false):
		var instance := node as GeometryInstance3D
		if instance == null:
			continue
		if instance.has_meta("exclude_from_geometry_measurements"):
			continue
		var aabb: AABB = instance.get_aabb()
		if aabb.size.length() <= 0.0:
			continue
		var to_world: Transform3D = instance.global_transform
		for index in 8:
			var corner := Vector3(
				aabb.position.x + (aabb.size.x if index & 1 else 0.0),
				aabb.position.y + (aabb.size.y if index & 2 else 0.0),
				aabb.position.z + (aabb.size.z if index & 4 else 0.0))
			var world_corner: Vector3 = to_world * corner
			edge = maxf(edge, Vector2(world_corner.x - origin.x, world_corner.z - origin.z).length())
	return edge


## navmesh 的 agent_radius（读 NavigationRegion3D 本体，不复制常量）。
## carve 洞 = 建筑世界几何 + 这个值；取不到时 2.8 与 C# 放置端口同一兜底。
static func navmesh_agent_radius(producer: Node3D) -> float:
	var match = producer.find_parent("Match")
	if match == null:
		return 2.8
	var region = match.get_node_or_null("Navigation/Terrain/NavigationRegion3D")
	if region == null:
		return 2.8
	var mesh = region.get("navigation_mesh")
	if mesh == null:
		return 2.8
	var value = mesh.get("agent_radius")
	return float(value) if value != null else 2.8
