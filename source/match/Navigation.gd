extends Node3D

var _static_obstacles = []

@onready var air = find_child("Air")
@onready var terrain = find_child("Terrain")

@onready var _match = find_parent("Match")


func _ready():
	await _match.ready
	_setup_static_obstacles()


func get_navigation_map_rid_by_domain(domain):
	return {
		Constants.Match.Navigation.Domain.AIR: air.navigation_map_rid,
		Constants.Match.Navigation.Domain.TERRAIN: terrain.navigation_map_rid,
	}[domain]


func setup(map):
	assert(_static_obstacles.is_empty())
	await air.bake(map)
	await terrain.bake(map)
	_setup_static_obstacles()


## 复制烘焙参数到新 NavigationMesh，避免重开对局时改到 PackedScene 里那份已烘焙网格。
func copy_navmesh_settings(template: NavigationMesh) -> NavigationMesh:
	var mesh := NavigationMesh.new()
	mesh.geometry_parsed_geometry_type = template.geometry_parsed_geometry_type
	mesh.geometry_collision_mask = template.geometry_collision_mask
	mesh.geometry_source_geometry_mode = template.geometry_source_geometry_mode
	mesh.geometry_source_group_name = template.geometry_source_group_name
	mesh.cell_size = template.cell_size
	mesh.cell_height = template.cell_height
	mesh.agent_height = template.agent_height
	mesh.agent_radius = template.agent_radius
	mesh.agent_max_climb = template.agent_max_climb
	mesh.edge_max_error = template.edge_max_error
	return mesh


func _exit_tree():
	_release_server_owned_navigation_resources()


func _setup_static_obstacles():
	if not _static_obstacles.is_empty():
		return
	for domain in [
		Constants.Match.Navigation.Domain.AIR, Constants.Match.Navigation.Domain.TERRAIN
	]:
		var obstacle = NavigationServer3D.obstacle_create()
		NavigationServer3D.obstacle_set_map(obstacle, get_navigation_map_rid_by_domain(domain))
		var obstacle_y = {
			Constants.Match.Navigation.Domain.AIR: Constants.Match.Air.Y,
			Constants.Match.Navigation.Domain.TERRAIN: 0,
		}[domain]
		NavigationServer3D.obstacle_set_position(obstacle, Vector3(0, obstacle_y, 0))
		var obstacle_vertices = [
			Vector3(0, 0, 0),
			Vector3(0, 0, _match.map.size.y),
			Vector3(_match.map.size.x, 0, _match.map.size.y),
			Vector3(_match.map.size.x, 0, 0),
		]
		NavigationServer3D.obstacle_set_vertices(obstacle, obstacle_vertices)
		NavigationServer3D.obstacle_set_avoidance_enabled(obstacle, true)
		_static_obstacles.append(obstacle)


## 按依赖顺序释放脚本直接创建的障碍与空域地图，Node 所有的 RID 仍由 Godot 管理。
func _release_server_owned_navigation_resources():
	for obstacle in _static_obstacles:
		if obstacle.is_valid():
			NavigationServer3D.free_rid(obstacle)
	_static_obstacles.clear()
	if air != null:
		air.release_navigation_map()
