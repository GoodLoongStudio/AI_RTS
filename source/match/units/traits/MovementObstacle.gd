extends NavigationObstacle3D

@export var domain = Constants.Match.Navigation.Domain.TERRAIN
@export var path_height_offset = 0.0

@onready var _match = find_parent("Match")
@onready var _unit = get_parent()


func _ready():
	await get_tree().process_frame  # wait for navigation to be operational
	set_navigation_map(_match.navigation.get_navigation_map_rid_by_domain(domain))
	_align_unit_position_to_navigation()
	if "is_under_construction" in _unit and _unit.is_under_construction():
		# 施工中的建筑不阻挡寻路（虚化无碰撞体积）；完工信号后再加入导航障碍并重烘
		_unit.constructed.connect(_affect_navigation_if_needed)
	else:
		_affect_navigation_if_needed()


func _exit_tree():
	remove_from_group(Constants.Match.Navigation.DOMAIN_TO_OBSTACLE_GROUP_MAPPING[domain])
	if affect_navigation_mesh:
		remove_from_group(Constants.Match.Navigation.DOMAIN_TO_GROUP_MAPPING[domain])
		MatchSignals.schedule_navigation_rebake.emit(domain)


func _align_unit_position_to_navigation():
	var navigation_map := get_navigation_map()
	var source_position: Vector3 = get_parent().global_transform.origin
	var closest_point_owner := NavigationServer3D.map_get_closest_point_owner(
		navigation_map, source_position
	)
	# Invalid owner means the closest-point result is only the zero sentinel;
	# preserve the authored/spawned position until a usable navigation region exists.
	if not closest_point_owner.is_valid():
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
