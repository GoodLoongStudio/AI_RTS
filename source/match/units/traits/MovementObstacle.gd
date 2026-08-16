extends NavigationObstacle3D

@export var domain = Constants.Match.Navigation.Domain.TERRAIN
@export var path_height_offset = 0.0

@onready var _match = find_parent("Match")
@onready var _unit = get_parent()


func _ready():
	await get_tree().process_frame  # wait for navigation to be operational
	set_navigation_map(_match.navigation.get_navigation_map_rid_by_domain(domain))
	_align_unit_position_to_navigation()
	_affect_navigation_if_needed()


func _exit_tree():
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
		add_to_group(Constants.Match.Navigation.DOMAIN_TO_GROUP_MAPPING[domain])
		MatchSignals.schedule_navigation_rebake.emit(domain)
