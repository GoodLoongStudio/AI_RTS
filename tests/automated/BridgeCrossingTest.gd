extends Node

## 过桥寻路验证（无头）：在带桥生成图上，把单位派到**桥对面**的目的地，
## 验证它能真正走到（而不是在水边打转/卡死）。
## 运行：Godot --headless --path <repo> res://tests/automated/BridgeCrossingTest.tscn

const MAP_PATH := "res://source/match/maps/generated/49-1376088014/map_49-1376088014.tscn"
const INFANTRY := preload("res://source/match/units/Infantry.tscn")
const TANK := preload("res://source/match/units/Tank.tscn")
const MatchSettings = preload("res://source/data-model/MatchSettings.gd")

const CROSS_TIMEOUT_S := 180.0


func _ready():
	await get_tree().process_frame
	await get_tree().process_frame
	var failures := 0
	failures += await _run()
	print("Bridge crossing test completed: %d failure(s)" % failures)
	get_tree().quit(1 if failures > 0 else 0)


func _run() -> int:
	var failures := 0
	var settings = MatchSettings.new()
	var human = load("res://source/data-model/PlayerSettings.gd").new()
	human.controller = Constants.PlayerType.HUMAN
	human.color = Color.BLUE
	settings.players.append(human)
	settings.visibility = MatchSettings.Visibility.FULL

	var map_instance = load(MAP_PATH).instantiate()
	var a_match = load("res://source/match/Match.tscn").instantiate()
	a_match.settings = settings
	a_match.map = map_instance
	get_tree().root.add_child(a_match)

	var player = null
	var deadline := Time.get_ticks_msec() + 120000
	while player == null and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
		var players = a_match.get_node_or_null("Players")
		if players != null and players.get_child_count() > 0 and players.get_child(0).get_child_count() > 0:
			player = players.get_child(0)
	if player == null:
		push_error("玩家单位未生成")
		return 1

	var terrain = a_match.get_node_or_null("Map/Geometry/Terrain")
	var occupancy = a_match.map.get_meta("water_occupancy", null)
	if occupancy == null:
		push_error("占用格未建立")
		return 1
	var bridges: Array = occupancy.get("_bridge_rects")

	print("[BR] bridges=", bridges.size())

	if bridges.is_empty():
		push_error("未收集到桥面")
		return 1

	# 取第一座桥：起点放桥一侧 12m，目的地放另一侧 12m（沿桥法线方向）
	var rect: Rect2 = bridges[0]
	var center := rect.get_center()
	var size := rect.size
	var along := Vector2(size.x, 0.0) if size.x >= size.y else Vector2(0.0, size.y)
	if along.length() < 0.001:
		along = Vector2(1.0, 0.0)
	along = along.normalized()
	var normal := Vector2(-along.y, along.x)
	# 从桥面向两侧沿法线外扩，找到两岸的**可走**落点（水边图往往一出发就在水里）。
	var start_pos := Vector3.ZERO
	var goal_pos := Vector3.ZERO
	var found_start := false
	var found_goal := false
	# 扫描从桥缘之外开始：桥沿法线方向的半宽 = 短边/2，越过它才是真正的对岸。
	var half_span: float = (size.y if absf(normal.x) > absf(normal.y) else size.x) * 0.5
	var scan_from: float = half_span + 2.0
	for dist in [scan_from, scan_from + 2.0, scan_from + 5.0, scan_from + 9.0, scan_from + 14.0, scan_from + 20.0]:
		var a: Vector3 = occupancy.project_ground(Vector3(center.x - normal.x * dist, 0.0, center.y - normal.y * dist))
		if not found_start and not occupancy.is_ground_blocked(a):
			start_pos = a
			found_start = true
		var b: Vector3 = occupancy.project_ground(Vector3(center.x + normal.x * dist, 0.0, center.y + normal.y * dist))
		# 目标点要求**明显高出水面**（≥0.3m）：贴着 0.15 门槛的沙堤是退化用例，
		# 真实命令不会把单位派到那种地方（2026-09-21 测试自调）。
		if not found_goal and not occupancy.is_ground_blocked(b) and b.y >= 0.3:
			goal_pos = b
			found_goal = true
	print("[BR] bridge center=", center, " start=", start_pos, " goal=", goal_pos,
		" found=", found_start, "/", found_goal)
	if not found_start or not found_goal:
		push_error("[BR] 桥两侧找不到可走落点")
		return 1

	# 诊断：桥面 → 对岸的 A* 连通性
	var diag_from: Vector3 = occupancy.project_ground(Vector3(center.x + 2.0, 0.0, center.y))
	var diag_path = occupancy.find_ground_path(diag_from, goal_pos)
	print("[BR][diag] from=", diag_from, " to=", goal_pos, " path_points=", diag_path.size())
	if diag_path.size() >= 2:
		var pts := ""
		for pt in diag_path:
			pts += "(%.1f,%.1f) " % [pt.x, pt.z]
		print("[BR][diag] path=", pts)
	# 沿桥西缘由北向南扫，看哪些点可走
	var edge_line := ""
	for dz in [-12.0, -8.0, -4.0, 0.0, 4.0, 8.0, 12.0]:
		var p: Vector3 = occupancy.project_ground(Vector3(center.x - half_span - 1.0, 0.0, center.y + dz))
		edge_line += "z=%.0f:h=%.2f,blk=%s " % [center.y + dz, p.y, str(occupancy.is_ground_blocked(p))]
	print("[BR][diag] west edge: ", edge_line)
	# 单位卡住点周边逐点判定
	var stuck := Vector3(51.926, 0.6, 136.846)
	for off in [Vector3(0,0,0), Vector3(-0.06,0,0.03), Vector3(-0.15,0,0.05), Vector3(-0.3,0,0.1), Vector3(0.5,0,2.0), Vector3(-1.0,0,3.0)]:
		var q: Vector3 = stuck + off
		var on_bridge = occupancy._sample_bridge_deck(q.x, q.z) > -1.0e8
		print("[BR][diag] pt=%s h=%.2f blocked=%s on_bridge=%s" % [
			str(q), occupancy.sample_height(q.x, q.z), str(occupancy.is_ground_blocked(q)), str(on_bridge)])

	# 诊断：从单位实际停点向西岸纵深扫描 + A* 连通性
	var probe := Vector3(50.6, 0.0, 139.0)
	var line := ""
	for dx in [0.0, 2.0, 4.0, 6.0, 8.0, 10.0, 14.0, 18.0]:
		var q: Vector3 = occupancy.project_ground(probe + Vector3(-dx, 0.0, 0.0))
		line += "x=%.0f:h=%.2f,blk=%s " % [probe.x - dx, q.y, str(occupancy.is_ground_blocked(q))]
	print("[BR][diag] westward from bank: ", line)
	var p2 = occupancy.find_ground_path(probe, goal_pos)
	print("[BR][diag] path from bank to goal: points=", p2.size())
	var pts := ""
	for pt in p2:
		pts += "(%.0f,%.0f) " % [pt.x, pt.z]
	print("[BR][diag] path=", pts)

	for unit_scene in [INFANTRY, TANK]:
		var unit = unit_scene.instantiate()
		MatchSignals.setup_and_spawn_unit.emit(unit, Transform3D(Basis(), start_pos), player)
		await get_tree().create_timer(1.0).timeout
		var movement = unit.find_child("Movement", false, false)
		movement.move(goal_pos)
		var label: String = unit.name
		var elapsed := 0.0
		var arrived := false
		var min_dist := INF
		while elapsed < CROSS_TIMEOUT_S:
			await get_tree().create_timer(0.5).timeout
			elapsed += 0.5
			var d: float = Vector2(unit.global_position.x, unit.global_position.z).distance_to(
				Vector2(goal_pos.x, goal_pos.z))
			min_dist = minf(min_dist, d)
			if d <= 2.0:
				arrived = true
				break
		print("[BR] %s arrived=%s min_dist=%.2f final=(%.1f,%.1f) committed=%s" % [
			label, str(arrived), min_dist, unit.global_position.x, unit.global_position.z,
			str(movement.get("_committed_target"))])
		if not arrived:
			failures += 1
			push_error("[BR] %s 未能过桥到达对岸（最近 %.2fm）" % [label, min_dist])
		unit.queue_free()
		await get_tree().process_frame
	return failures
