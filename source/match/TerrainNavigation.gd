extends Node3D

const DOMAIN = Constants.Match.Navigation.Domain.TERRAIN

static var server_busy := false

var _earliest_frame_to_perform_next_rebake = null
var _is_baking = false
var _rebake_queued := false
var _map_geometry = NavigationMeshSourceGeometryData3D.new()

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
	NavigationServer3D.bake_from_source_geometry_data(
		_navigation_region.navigation_mesh, _map_geometry
	)
	server_busy = false
	_sync_navmesh_changes()


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

	server_busy = true
	NavigationServer3D.bake_from_source_geometry_data_async(
		_navigation_region.navigation_mesh, full_geometry, _on_bake_finished
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
	if _is_baking or server_busy:
		_rebake_queued = true
		return
	if _earliest_frame_to_perform_next_rebake == null:
		_earliest_frame_to_perform_next_rebake = get_tree().get_frame() + 1


func _on_bake_finished():
	server_busy = false
	if not is_inside_tree():
		return
	_sync_navmesh_changes()
	_is_baking = false
	if _rebake_queued:
		_rebake_queued = false
		_earliest_frame_to_perform_next_rebake = get_tree().get_frame() + 1
