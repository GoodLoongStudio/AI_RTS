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


static func units_adhere(unit_a, unit_b):
	"""checks if distance between unit borders is within margin"""
	return _unit_in_range_of_other(unit_a, unit_b, Constants.Match.Units.ADHERENCE_MARGIN_M)


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
