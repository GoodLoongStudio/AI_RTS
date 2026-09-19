extends NavigationObstacle3D

@export var domain = Constants.Match.Navigation.Domain.TERRAIN
@export var path_height_offset = 0.0

const Structure = preload("res://source/match/units/Structure.gd")

@onready var _match = find_parent("Match")
@onready var _unit = get_parent()


func _ready():
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


func _register_logic_obstacle() -> void:
	add_to_group(Constants.Match.Navigation.DOMAIN_TO_OBSTACLE_GROUP_MAPPING[domain])
	if not (_unit is Structure):
		return
	var occupancy := _logic_occupancy()
	if occupancy == null or not occupancy.has_method("set_structure_blocker"):
		if is_inside_tree():
			call_deferred("_retry_logic_blocker")
		return
	occupancy.set_structure_blocker(get_instance_id(), _unit.global_position, float(radius))


func _retry_logic_blocker() -> void:
	if not is_inside_tree() or not (_unit is Structure):
		return
	var occupancy := _logic_occupancy()
	if occupancy != null and occupancy.has_method("set_structure_blocker"):
		occupancy.set_structure_blocker(get_instance_id(), _unit.global_position, float(radius))


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
	_unit.global_transform.origin = (
		NavigationServer3D.map_get_closest_point(navigation_map, source_position)
		- Vector3(0, path_height_offset, 0)
	)


func _affect_navigation_if_needed():
	if affect_navigation_mesh:
		# 持久注册表：供移动侧做"落点是否落在避让圈内"的校验（该组不会被烘焙清空）。
		add_to_group(Constants.Match.Navigation.DOMAIN_TO_OBSTACLE_GROUP_MAPPING[domain])
		# 临时输入清单：交给下一次导航网格烘焙。
		add_to_group(Constants.Match.Navigation.DOMAIN_TO_GROUP_MAPPING[domain])
		MatchSignals.schedule_navigation_rebake.emit(domain)
