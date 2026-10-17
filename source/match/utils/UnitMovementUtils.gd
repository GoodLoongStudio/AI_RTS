# TODO: refactor required after porting from Godot 3
const DISTANCE_REDUCTION_BY_DIVISION_ITERATIONS_MAX = 10
const DISTANCE_REDUCTION_BY_SUBTRACTION_ITERATIONS_MAX = 10

# crowd - group of units
# pivot - pivot point, central point of crowd


static func crowd_moved_to_new_pivot(units, new_pivot):
	"""calculates new unit positions relative to new_pivot"""
	if units.is_empty():
		return []
	if units.size() == 1:
		return [[units[0], new_pivot]]
	# 选项 C（2026-09-12 用户选定）：点击点落在**群体包围盒内部**时，玩家语义是
	# "向我点的地方靠拢"，而不是"保持队形整体平移"——整体平移在两个单位中间点一下，
	# 每个单位的目标 = 点击点 + (自己位置 − 群体中心) ≈ 自己脚下，
	# 实测两个步兵相距 2.5m、点正中间 → 两个目标旗就贴在原地，一动不动。
	# 这里改走"以当前位置为起点朝点击点收拢"（二分逼近到刚好不重叠为止）。
	if _yless_point_inside_crowd_aabb(units, new_pivot):
		return _converge_units_towards_pivot(units, new_pivot)
	var old_pivot = calculate_aabb_crowd_pivot_yless(units)
	var yless_unit_offsets_from_old_pivot = _calculate_yless_unit_offsets_from_old_pivot(
		units, old_pivot
	)
	var new_unit_positions = _calculate_new_unit_positions(
		yless_unit_offsets_from_old_pivot, new_pivot
	)
	var condensed_unit_positions = _attract_unit_positions_towards_pivot(
		new_unit_positions, new_pivot, Constants.Match.Units.ADHERENCE_MARGIN_M * 2
	)
	return condensed_unit_positions


## 点击点（去 Y）是否落在群体包围盒内部（含边界，留 1mm 容差）。
static func _yless_point_inside_crowd_aabb(units, point):
	var test_point = point * Vector3(1, 0, 1)
	var positions = []
	for unit in units:
		positions.append(unit.global_position)
	var begin = Vector3(_calculate_min_x(positions), 0.0, _calculate_min_z(positions))
	var end = Vector3(_calculate_max_x(positions), 0.0, _calculate_max_z(positions))
	var epsilon = 0.001
	return (
		test_point.x >= begin.x - epsilon
		and test_point.x <= end.x + epsilon
		and test_point.z >= begin.z - epsilon
		and test_point.z <= end.z + epsilon
	)


## 选项 C 的收拢：各单位从**当前位置**沿直线朝 pivot 走，走到"再靠近就会和已就位的
## 同伴（或 pivot 本身）相撞"为止；用二分求最大可达比例，所以能贴到临界值。
##
## 与 `_attract_unit_positions_towards_pivot` 的区别：那个是"第一个候选点一撞就整段
## 放弃"（两个兵相隔 2.5m、点中线时距离已在安全垫内 → 一步都不做），这里则保证真的收敛。
## 安全距离用 `ADHERENCE_MARGIN_M`（0.5m，与 units_adhere 同口径），
## 于是两个步兵最近可到 半径和+0.5 ≈ 0.92m，离点击点最近 半径+0.5 ≈ 0.71m。
static func _converge_units_towards_pivot(units, pivot):
	var threshold = Constants.Match.Units.ADHERENCE_MARGIN_M
	var ordered = []
	for unit in units:
		ordered.append([unit, unit.global_position * Vector3(1, 0, 1)])
	ordered.sort_custom(func(a, b): return a[1].distance_to(pivot) < b[1].distance_to(pivot))
	var placed = [[pivot, 0.0]]
	var converged = []
	for tuple in ordered:
		var unit = tuple[0]
		var position = tuple[1]
		var to_pivot = pivot - position
		to_pivot.y = 0.0
		var travel = to_pivot.length()
		var final_position = position
		if travel > 0.0001:
			var direction = to_pivot / travel
			var low = 0.0
			var high = 1.0
			for _i in range(24):
				var mid = (low + high) / 2.0
				var candidate = position + direction * travel * mid
				if _disc_collides_with_others([candidate, unit.radius], placed, threshold):
					high = mid
				else:
					low = mid
			final_position = position + direction * travel * low
		converged.append([unit, final_position])
		placed.append([final_position, unit.radius])
	return converged


static func calculate_aabb_crowd_pivot_yless(units):
	"""calculates pivot which is a center of crowd AABB"""
	var unit_positions = []
	for unit in units:
		unit_positions.append(unit.global_position)
	var begin = Vector3(_calculate_min_x(unit_positions), 0.0, _calculate_min_z(unit_positions))
	var end = Vector3(_calculate_max_x(unit_positions), 0.0, _calculate_max_z(unit_positions))
	return (begin + end) / 2.0 * Vector3(1, 0, 1)


## 导航 carve 净空：目标若是"会挖导航洞"的障碍（矿点/建筑），单位中心到它的最近可达
## 距离是 `target.radius + navmesh.agent_radius`，**不是** `a.radius + b.radius`。
## 【2026-09-30 根因】旧口径下 工人(r2.0) 贴 矿点(r0.6) 的阈值 = 2.0+0.6+0.5 = 3.1m，
## 而矿点的 carve 洞是 0.6+2.8 = 3.4m —— 工人**物理上永远进不到 3.1m 内**，
## 于是采集状态机每次都判"到达矿点但未贴合"、重试 4 次后放弃（矿采不掉、经济停摆，
## 全量回归里表现为 ore-refinery 的 5 条断言红）。
static func navigation_agent_radius(unit) -> float:
	var match_node = unit.find_parent("Match") if unit != null else null
	if match_node == null:
		return 2.8
	var region = match_node.get_node_or_null("Navigation/Terrain/NavigationRegion3D")
	if region == null:
		for sub in match_node.find_children("*", "NavigationRegion3D", true, false):
			region = sub
			break
	if region != null and region.get("navigation_mesh") != null:
		return float(region.get("navigation_mesh").get("agent_radius"))
	return 2.8


## 目标自身的 carve 净空（不 carve 的目标返回 0，保持旧口径不变）。
## toward 给出时按"朝该点方向"的 carve 轮廓（方盒洞的面/角距离不同）；否则取轮廓最远点。
static func carve_clearance_of(target, toward = null) -> float:
	if target == null or target.get("radius") == null:
		return 0.0
	var obstacle = target.find_child("MovementObstacle", false, false)
	if obstacle == null or not bool(obstacle.get("affect_navigation_mesh")):
		return 0.0
	var base_radius: float = (
		float(target.get("radius"))
		if target.get("radius") != null else float(obstacle.get("radius"))
	)
	if obstacle.has_method("carve_extent_toward"):
		var extent: float = (
			obstacle.carve_extent_toward(toward) if toward is Vector3 else obstacle.carve_extent_max()
		)
		base_radius = maxf(base_radius, extent)
	return base_radius + navigation_agent_radius(target)


## 挖洞目标（建筑）的靠近落点：在目标 carve 轮廓外一圈采样，只取导航面上的点；
## 离其它挖洞障碍的洞边不足 2×单位半径的点（两栋楼之间的楔形缝口）降为最后选择，
## 否则单位会停进缝口，被两侧推出层夹住、被友军挤进封死的缝里。
## 非挖洞目标或导航未就绪返回 null，调用方沿用旧落点。只在动作开始时调用一次。
const APPROACH_SAMPLES := 16
const APPROACH_EDGE_OFFSET_M := 0.4
## 探针做对照时可关。
static var structure_approach_enabled := true
## 每辆车一个稳定车道。只在选交货落点时读，不进移动帧。
static var _next_approach_slot := 0


static func approach_slot(unit) -> int:
	if unit == null:
		return 0
	if not unit.has_meta("approach_slot"):
		unit.set_meta("approach_slot", _next_approach_slot % APPROACH_SAMPLES)
		_next_approach_slot += 1
	return int(unit.get_meta("approach_slot"))


static func rotate_approach_slot(unit) -> void:
	if unit == null:
		return
	unit.set_meta("approach_slot", (approach_slot(unit) + 3) % APPROACH_SAMPLES)


## 取本局的地表占用格脚本（只有生成图这类"逻辑地形"才有）。
## 返回 null ⇒ 调用方必须走导航网格旧路径；非逻辑地形/接口缺失都不会改变旧行为。
## 供建筑侧复用：本局若是逻辑地形（生成图）就返回其占用格脚本。
static func logic_terrain_of(unit) -> Node:
	if unit == null or not unit.is_inside_tree():
		return null
	var match_node: Node = unit.find_parent("Match")
	if match_node == null:
		return null
	var map_node: Node = match_node.get_node_or_null("Map")
	if map_node == null or not Utils.Match.is_logic_terrain_map(map_node):
		return null
	var terrain: Node = map_node.find_child("Terrain", true, false)
	if terrain == null or not terrain.has_method("is_ground_blocked"):
		return null
	return terrain


static func structure_approach_point(unit, target) -> Variant:
	if not structure_approach_enabled or unit == null or target == null or not is_instance_valid(target):
		return null
	var obstacle = target.find_child("MovementObstacle", false, false)
	if obstacle == null or not obstacle.has_method("carve_extent_toward"):
		return null
	# 生成图（有高度场）没有导航网格：`MovementObstacle._ready` 在那里会把
	# `affect_navigation_mesh` 关掉，旧写法据此直接返回 null，交货/集结落点于是退化成
	# 楼心——实测 `_RefineryJamProbe` 90s：交付=0、卡住 261.2s、三车全判 drop_overlap，
	# 且所有脱困计数为 0（导航侧的绕行与推出层根本没运行）。逻辑地形改用建筑足迹判空。
	var terrain := logic_terrain_of(unit)
	if not bool(obstacle.get("affect_navigation_mesh")):
		if terrain == null or not bool(obstacle.call("logic_footprint_blocks")):
			return null
	var movement = unit.find_child("Movement", false, false)
	if movement == null or not movement.has_method("get_navigation_map"):
		return null
	var map: RID = movement.get_navigation_map()
	if terrain == null and (not map.is_valid() or NavigationServer3D.map_get_iteration_id(map) == 0):
		return null
	var agent := navigation_agent_radius(target)
	var center: Vector3 = target.global_position * Vector3(1, 0, 1)
	var from: Vector3 = unit.global_position * Vector3(1, 0, 1)
	var pocket_clearance: float = 2.0 * maxf(float(unit.get("radius")) if unit.get("radius") != null else 0.5, 0.5)
	var others: Array = []
	var group_name: String = Constants.Match.Navigation.DOMAIN_TO_OBSTACLE_GROUP_MAPPING.get(
		Constants.Match.Navigation.Domain.TERRAIN, "")
	var reach: float = float(obstacle.carve_extent_max()) + agent + APPROACH_EDGE_OFFSET_M + pocket_clearance
	for other in unit.get_tree().get_nodes_in_group(group_name):
		if other == obstacle or not is_instance_valid(other) or not bool(other.get("affect_navigation_mesh")) \
				or not other.has_method("carve_extent_max"):
			continue
		var other_center: Vector3 = other.global_position * Vector3(1, 0, 1)
		if other_center.distance_to(center) <= reach + other.carve_extent_max() + agent:
			others.append(other)
	var best: Variant = null
	var best_score := INF
	# 靠近侧按车道左右错开，避免所有矿车挤在同一条去程/回程线上。
	var from_center := from - center
	var base_angle := atan2(from_center.z, from_center.x)
	var lane := (approach_slot(unit) % 5) - 2
	var prefer := base_angle + float(lane) * (TAU / float(APPROACH_SAMPLES))
	for index in APPROACH_SAMPLES:
		var angle := TAU * float(index) / float(APPROACH_SAMPLES)
		var dir := Vector3(cos(angle), 0.0, sin(angle))
		var distance: float = obstacle.carve_extent_toward(center + dir) + agent + APPROACH_EDGE_OFFSET_M
		var point := center + dir * distance
		if terrain != null:
			# 没有导航面可查最近点，改用占用格的真足迹/水面判定。
			if bool(terrain.call("is_ground_blocked", point)):
				continue
		else:
			var closest := NavigationServer3D.map_get_closest_point(map, point)
			if Vector2(closest.x - point.x, closest.z - point.z).length() > 0.3:
				continue

		var ang := absf(wrapf(angle - prefer, -PI, PI))
		var score := ang * 12.0 + point.distance_to(from) * 0.02
		for other in others:
			var other_center: Vector3 = other.global_position * Vector3(1, 0, 1)
			var to_edge: float = point.distance_to(other_center) - other.carve_extent_toward(point) - agent
			if to_edge < pocket_clearance:
				score += 1000.0
				break
		if score < best_score:
			best_score = score
			best = point
	return best


static func units_adhere(unit_a, unit_b):
	"""checks if distance between unit borders is within margin"""
	var margin: float = Constants.Match.Units.ADHERENCE_MARGIN_M
	# Fixed box structures are blocked by their actual surface, including the
	# corners. Their logical radius is a half-width, not a containing circle.
	# Use the same border gap for contact without changing the contact margin.
	# Resource gathering and movable targets retain their existing contract.
	if unit_b.find_child("MovementObstacle", false, false) != null \
			and unit_b.find_child("Movement", false, false) == null \
			and not unit_b.is_in_group("resource_units"):
		var collision = unit_b.get_node_or_null("CollisionShape3D")
		if collision is CollisionShape3D and not collision.disabled and collision.shape is BoxShape3D:
			var transform: Transform3D = collision.global_transform
			var half: Vector3 = collision.shape.size * 0.5
			var local: Vector3 = transform.affine_inverse() * unit_a.global_position
			var closest: Vector3 = transform * Vector3(
				clampf(local.x, -half.x, half.x), local.y,
				clampf(local.z, -half.z, half.z))
			var gap := Vector2(unit_a.global_position.x - closest.x,
				unit_a.global_position.z - closest.z).length()
			if gap <= float(unit_a.radius) + margin:
				return true
	# 两个口径取较大值：border 口径保持原语义，carve 口径覆盖"导航洞把单位挡在外面"。
	# 注意不能复用 _unit_in_range_of_other（它内部还会再加 a.radius + b.radius）。
	var threshold: float = maxf(
		float(unit_a.radius) + float(unit_b.radius) + margin,
		carve_clearance_of(unit_b, unit_a.global_position) + margin
	)
	var a_pos: Vector3 = unit_a.global_position * Vector3(1, 0, 1)
	var b_pos: Vector3 = unit_b.global_position * Vector3(1, 0, 1)
	return a_pos.distance_to(b_pos) <= threshold


static func _unit_in_range_of_other(unit_a, unit_b, b_range):
	"""checks if distance from one unit border to another is within range"""
	var unit_a_position_yless = unit_a.global_position * Vector3(1, 0, 1)
	var unit_b_position_yless = unit_b.global_position * Vector3(1, 0, 1)
	return (
		unit_a_position_yless.distance_to(unit_b_position_yless)
		<= (unit_a.radius + unit_b.radius + b_range)
	)


static func _attract_unit_positions_towards_pivot(unit_positions, pivot, interunit_threshold):
	"""takes List[Tuple[unit, point]], pivot, and interunit_threshold(min interunit dist)"""
	var new_unit_positions = {}
	var unit_distances_to_pivot = []
	for tuple in unit_positions:
		var unit = tuple[0]
		var point = tuple[1]
		new_unit_positions[unit] = point
		unit_distances_to_pivot.append([unit, point.distance_to(pivot)])
	unit_distances_to_pivot.sort_custom(func(a, b): return a[1] < b[1])
	var discs = [[pivot, 0]]
	for tuple in unit_distances_to_pivot:
		var unit = tuple[0]
		var distance = tuple[1]
		var direction_towards_pivot = (pivot - new_unit_positions[unit]).normalized()
		# reduce distance by division
		for _i in range(DISTANCE_REDUCTION_BY_DIVISION_ITERATIONS_MAX):
			var candidate_pos = new_unit_positions[unit] + direction_towards_pivot * distance / 2.0
			if not _disc_collides_with_others(
				[candidate_pos, unit.radius], discs, interunit_threshold
			):
				distance /= 2.0
				new_unit_positions[unit] = candidate_pos
			else:
				break
		# reduce distance by subtraction
		var reduction_step = max(
			distance / 2.0 / float(DISTANCE_REDUCTION_BY_SUBTRACTION_ITERATIONS_MAX),
			interunit_threshold / 2.0
		)
		for _i in range(DISTANCE_REDUCTION_BY_SUBTRACTION_ITERATIONS_MAX):
			var candidate_pos = new_unit_positions[unit] + direction_towards_pivot * reduction_step
			if not _disc_collides_with_others(
				[candidate_pos, unit.radius], discs, interunit_threshold
			):
				new_unit_positions[unit] = candidate_pos
			else:
				break
		discs.append([new_unit_positions[unit], unit.radius])
	return Utils.Dict.items(new_unit_positions)


static func _disc_collides_with_others(disc, discs, adherence_margin):
	var disc_pos = disc[0]
	var disc_radius = disc[1]
	for other_disc in discs:
		var other_disc_pos = other_disc[0]
		var other_disc_radius = other_disc[1]
		if (
			disc_pos.distance_to(other_disc_pos)
			<= disc_radius + other_disc_radius + adherence_margin
		):
			return true
	return false


static func _calculate_new_unit_positions(yless_unit_offsets_from_old_pivot, new_pivot):
	var new_unit_positions = []
	for tuple in yless_unit_offsets_from_old_pivot:
		var unit = tuple[0]
		var offset = tuple[1]
		new_unit_positions.append([unit, new_pivot + offset])
	return new_unit_positions


static func _calculate_yless_unit_offsets_from_old_pivot(units, old_pivot):
	var old_pivot_yless = old_pivot * Vector3(1, 0, 1)
	var yless_unit_offsets_from_old_pivot = []
	for unit in units:
		var unit_position_yless = unit.global_position * Vector3(1, 0, 1)
		(
			yless_unit_offsets_from_old_pivot
			. append(
				[
					unit,
					unit_position_yless - old_pivot_yless,
				]
			)
		)
	return yless_unit_offsets_from_old_pivot


static func _calculate_min_x(positions):
	return _calculate_extremum(positions, Vector3(1, 0, 0), true)


static func _calculate_min_z(positions):
	return _calculate_extremum(positions, Vector3(0, 0, 1), true)


static func _calculate_max_x(positions):
	return _calculate_extremum(positions, Vector3(1, 0, 0), false)


static func _calculate_max_z(positions):
	return _calculate_extremum(positions, Vector3(0, 0, 1), false)


static func _calculate_extremum(positions, axis, minimum):
	var extremum = null
	for position in positions:
		var value = position.x if axis.x == 1 else position.z
		if extremum == null:
			extremum = value
			continue
		if (minimum and value < extremum) or (not minimum and value > extremum):
			extremum = value
	return extremum
