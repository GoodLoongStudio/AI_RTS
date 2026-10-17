extends Node

## 出生偏移实测（2026-10-01 世界尺度审计）：对每座生产建筑用**权威出生算法**
## production_spawn_spot 解出其产品出生点，量"建筑中心 → 出生点"距离。
## 口径：start_radius = 模型世界外缘 + navmesh agent_radius(2.8)，再径向搜索合法落点。

const MAP_SCENE := "res://source/match/maps/PlainAndSimple.tscn"

const CASES := [
	["VehicleFactory", "Tank"],
	["VehicleFactory", "Worker"],
	["Barracks", "Infantry"],
	["AircraftFactory", "Drone"],
	["AircraftFactory", "Helicopter"],
]


func _ready():
	var settings = load("res://source/data-model/MatchSettings.gd").new()
	var hs = load("res://source/data-model/PlayerSettings.gd").new()
	hs.controller = Constants.PlayerType.HUMAN
	hs.color = Constants.Player.COLORS[0]
	settings.players.append(hs)
	settings.visible_player = 0
	var m: Node = load("res://source/match/Match.tscn").instantiate()
	m.settings = settings
	m.map = load(MAP_SCENE).instantiate()
	add_child(m)
	get_tree().current_scene = m
	for _f in range(200):
		await get_tree().physics_frame
	var p: Node = m.get_node("Players").get_children()[0]
	var nav_map: RID = m.navigation.get_navigation_map_rid_by_domain(1) \
		if m.get("navigation") != null else RID()
	print("[SPAWN] 建筑|产品|建筑模型外缘|agentR|出生点距中心|出生点世界坐标")
	var z := 60.0
	for case in CASES:
		var building = load("res://source/match/units/%s.tscn" % case[0]).instantiate()
		m.call("_setup_and_spawn_unit", building, Transform3D(Basis.IDENTITY, Vector3(80.0, 0.0, z)), p, false)
		var produced = load("res://source/match/units/%s.tscn" % case[1]).instantiate()
		var edge := _visual_edge(building)
		var spot = Utils.Match.Unit.Placement.production_spawn_spot(
			building, produced, 0.1, nav_map, get_tree())
		if spot == Vector3.INF or spot == null:
			print("[SPAWN] %s|%s|%.2f|2.80|FAIL|INF" % [case[0], case[1], edge])
		else:
			var d: float = Vector2(spot.x - building.global_position.x, spot.z - building.global_position.z).length()
			print("[SPAWN] %s|%s|%.2f|2.80|%.2f|(%.2f,%.2f)" % [case[0], case[1], edge, d, spot.x, spot.z])
			produced.queue_free()
		z += 14.0
	get_tree().quit(0)


func _visual_edge(building) -> float:
	var origin: Vector3 = building.global_position
	var edge := 0.0
	for node in building.find_children("*", "GeometryInstance3D", true, false):
		var instance := node as GeometryInstance3D
		if instance == null:
			continue
		var aabb: AABB = instance.get_aabb()
		if aabb.size.length() <= 0.0:
			continue
		var to_world: Transform3D = instance.global_transform
		for index in range(8):
			var corner := Vector3(
				aabb.position.x + (aabb.size.x if index & 1 else 0.0),
				aabb.position.y + (aabb.size.y if index & 2 else 0.0),
				aabb.position.z + (aabb.size.z if index & 4 else 0.0))
			var world_corner: Vector3 = to_world * corner
			edge = maxf(edge, Vector2(world_corner.x - origin.x, world_corner.z - origin.z).length())
	return edge
