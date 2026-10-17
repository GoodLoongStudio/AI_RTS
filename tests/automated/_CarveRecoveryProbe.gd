extends Node

## 阶段 4 清单补验（2026-09-30 第 3 轮）：障碍移除后的导航恢复 + 地图边缘。
## 计划原文要求"验证基地旁、资源旁、地图边缘、窄通道和障碍移除后的导航恢复"。
##   A. 障碍移除：盖一座兵营 → 等重烘 → 量洞边界；拆掉 → 等重烘 → 洞必须消失（恢复可走）。
##   B. 地图边缘：在贴近角落处盖建筑 → 单位仍能绕着它走到地图内可达点，且洞不越界崩坏。

const MAP_SCENE := "res://source/match/maps/PlainAndSimple.tscn"
const BARRACKS := "res://source/match/units/Barracks.tscn"


func _ready():
	var settings = load("res://source/data-model/MatchSettings.gd").new()
	var human_settings = load("res://source/data-model/PlayerSettings.gd").new()
	human_settings.controller = Constants.PlayerType.HUMAN
	human_settings.color = Constants.Player.COLORS[0]
	settings.players.append(human_settings)
	settings.visible_player = 0
	var m: Node = load("res://source/match/Match.tscn").instantiate()
	m.settings = settings
	m.map = load(MAP_SCENE).instantiate()
	add_child(m)
	get_tree().current_scene = m
	for _f in range(300):
		await get_tree().physics_frame
	var human: Node = m.get_node("Players").get_children()[0]
	var region = m.get_node_or_null("Navigation/Terrain/NavigationRegion3D")
	var nav_map: RID = region.get_navigation_map() if region != null else RID()
	var agent := 2.8
	if region != null and region.get("navigation_mesh") != null:
		agent = float(region.get("navigation_mesh").get("agent_radius"))
	print("[CR] agent=%.2f map_valid=%s" % [agent, str(nav_map.is_valid())])

	# --- A. 障碍移除后的导航恢复 ---
	var spot := Vector3(150.0, 0.0, 150.0)
	var before := await _boundary_from(nav_map, spot)
	var barracks: Node3D = load(BARRACKS).instantiate()
	m.call("_setup_and_spawn_unit", barracks, Transform3D(Basis.IDENTITY, spot), human, false)
	await _settle(nav_map, 150)
	var with_building := await _boundary_from(nav_map, spot)
	print("[CR] A 兵营 footprint=%.2f carve 期望=%.2f" % [
		float(barracks.get("radius")), float(barracks.get("radius")) + agent])
	print("[CR] A 盖之前 +X 首个可走=%.2f；盖之后=%.2f" % [before, with_building])
	barracks.queue_free()
	await _settle(nav_map, 200)
	var after_removal := await _boundary_from(nav_map, spot)
	print("[CR] A 拆掉之后 +X 首个可走=%.2f（应回到 %.2f 附近 ⇒ 洞已恢复）" % [after_removal, before])

	# --- B. 地图边缘 ---
	var edge_spot := Vector3(4.0, 0.0, 4.0)
	var corner: Node3D = load(BARRACKS).instantiate()
	m.call("_setup_and_spawn_unit", corner, Transform3D(Basis.IDENTITY, edge_spot), human, false)
	await _settle(nav_map, 150)
	print("[CR] B 角落兵营实际落点=%s" % str(corner.global_position.snapped(Vector3(0.01, 0.01, 0.01))))
	var dirs := {"+X": Vector3(1, 0, 0), "+Z": Vector3(0, 0, 1), "-X": Vector3(-1, 0, 0), "-Z": Vector3(0, 0, -1)}
	var parts: Array = []
	for key in dirs:
		parts.append("%s=%.1f" % [key, await _boundary_from(nav_map, corner.global_position, dirs[key])])
	print("[CR] B 角落兵营洞边界: %s" % ", ".join(parts))
	# 地图边缘外仍不应被判为可走：沿 -X 采样到负坐标
	var outside: Vector3 = NavigationServer3D.map_get_closest_point(nav_map, Vector3(-8.0, 0.0, 4.0))
	print("[CR] B 图外点 (-8,0,4) 的最近导航点=%s（应被拉回图内）" % str(outside.snapped(Vector3(0.01, 0.01, 0.01))))
	corner.queue_free()
	await _settle(nav_map, 120)
	get_tree().quit(0)


func _settle(nav_map: RID, frames: int) -> void:
	for i in range(frames):
		await get_tree().physics_frame
		if i % 30 == 29 and nav_map.is_valid():
			NavigationServer3D.map_force_update(nav_map)


func _boundary_from(nav_map: RID, center: Vector3, dir: Vector3 = Vector3(1, 0, 0)) -> float:
	if not nav_map.is_valid():
		return -2.0
	var d := 1.0
	while d <= 60.0:
		var p: Vector3 = center + dir * d
		var closest: Vector3 = NavigationServer3D.map_get_closest_point(nav_map, p)
		if Vector2(closest.x - p.x, closest.z - p.z).length() < 0.4:
			return d
		d += 0.5
	return -1.0
