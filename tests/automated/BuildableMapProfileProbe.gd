extends Node

## 一次性诊断（2026-09-28 第二支探针）：把"哪里能建/哪里是空的"画出来。
## 只读，不改游戏代码；不烘焙（避免与并发会话抢 CPU）。
##   1) ASCII 图：地表 navmesh 覆盖 vs 逻辑地图边界；
##   2) 人类与 AI 基地位置 → 到 navmesh 的最近点距离（判断是否落在地面外）；
##   3) 以基地为心的径向剖面：每米采样"到 navmesh 的平面距离"，量出基地周围空洞大小；
##   4) 矿点（ResourceA）位置与半径，核对空洞是不是它们啃出来的。

const MatchSettings = preload("res://source/data-model/MatchSettings.gd")
const PlayerSettings = preload("res://source/data-model/PlayerSettings.gd")


func _ready() -> void:
	await get_tree().process_frame
	await get_tree().process_frame

	var settings = MatchSettings.new()
	var human = PlayerSettings.new()
	human.controller = Constants.PlayerType.HUMAN
	human.color = Color.BLUE
	settings.players.append(human)
	var ai = PlayerSettings.new()
	ai.controller = Constants.PlayerType.SIMPLE_CLAIRVOYANT_AI
	ai.color = Color.RED
	settings.players.append(ai)
	settings.visible_player = 0
	settings.visibility = MatchSettings.Visibility.PER_PLAYER

	var a_match: Node = load("res://source/match/Match.tscn").instantiate()
	a_match.settings = settings
	a_match.map = load("res://source/match/maps/PlainAndSimple.tscn").instantiate()
	get_tree().root.add_child(a_match)
	get_tree().current_scene = a_match

	var terrain_nav: Node = null
	var map_size := Vector2.ZERO
	var deadline := Time.get_ticks_msec() + 90000
	while Time.get_ticks_msec() < deadline:
		await get_tree().physics_frame
		terrain_nav = a_match.get_node_or_null("Navigation/Terrain")
		var map_node: Node = a_match.get_node_or_null("Map")
		if map_node != null:
			map_size = map_node.get("size")
		if terrain_nav != null and not terrain_nav.server_busy and map_size != Vector2.ZERO:
			var region: NavigationRegion3D = terrain_nav.find_child("NavigationRegion3D", false, false)
			if region != null and region.navigation_mesh != null \
					and region.navigation_mesh.get_polygon_count() > 0:
				break
	for _i in range(180):
		await get_tree().physics_frame

	var navigation: Node = a_match.get_node("Navigation")
	var map_rid: RID = navigation.call("get_navigation_map_rid_by_domain", 1)
	print("[P2] map_size=", map_size, " polygons=",
		(terrain_nav.find_child("NavigationRegion3D", false, false) as NavigationRegion3D).navigation_mesh.get_polygon_count())

	# ---- 1) ASCII 覆盖图 ----
	var step := 8.0
	print("[P2] ASCII：# = 该点在 navmesh 上，. = 不在（每格 ", step, "m；x 向右，z 向下）")
	var header := "     "
	var x := step * 0.5
	while x < map_size.x:
		header += str(int(fmod(x, 100.0) / 10.0))
		x += step
	print("[P2] " + header)
	var zi := 0
	var z := step * 0.5
	while z < map_size.y:
		var row := "%3d: " % int(z)
		var xx := step * 0.5
		while xx < map_size.x:
			var p := Vector3(xx, 0.0, z)
			var closest: Vector3 = NavigationServer3D.map_get_closest_point(map_rid, p)
			var d := Vector2(p.x - closest.x, p.z - closest.z).length()
			row += "#" if d <= 0.05 else "."
			xx += step
		print("[P2] " + row)
		z += step
		zi += 1

	# ---- 2) 两侧基地 ----
	var players: Node = a_match.get_node_or_null("Players")
	if players == null:
		print("[P2] FATAL: no Players")
		get_tree().quit(1)
		return
	for pi in players.get_child_count():
		var player: Node = players.get_child(pi)
		var cc: Node3D = null
		for child in player.get_children():
			if child is Node3D and str(child.get("unit_type_id")) == "command_center":
				cc = child
				break
		if cc == null:
			print("[P2] player", pi, " 无指挥中心")
			continue
		var pos: Vector3 = cc.global_position
		var closest: Vector3 = NavigationServer3D.map_get_closest_point(map_rid, pos)
		print("[P2] player%d 基地 pos=(%.1f, %.1f, %.1f)  navmesh最近点=(%.1f, %.1f, %.1f)  平面距离=%.2fm  %s" % [
			pi, pos.x, pos.y, pos.z, closest.x, closest.y, closest.z,
			Vector2(pos.x - closest.x, pos.z - closest.z).length(),
			"→ 落在地面外/空洞里" if Vector2(pos.x - closest.x, pos.z - closest.z).length() > 0.05 else "→ 在地面上"])

	# ---- 3) 人类基地径向剖面 ----
	var human_player: Node = players.get_child(0)
	var human_cc: Node3D = null
	for child in human_player.get_children():
		if child is Node3D and str(child.get("unit_type_id")) == "command_center":
			human_cc = child
			break
	if human_cc != null:
		var c: Vector3 = human_cc.global_position
		print("[P2] 人类基地径向剖面（到 navmesh 的平面距离，米；>0.05 即不可建）")
		for dir_i in 8:
			var angle := TAU * float(dir_i) / 8.0
			var line := "  方向%3d°: " % int(rad_to_deg(angle))
			for r_i in range(2, 41, 2):
				var p := Vector3(c.x + cos(angle) * float(r_i), 0.0, c.z + sin(angle) * float(r_i))
				var cl: Vector3 = NavigationServer3D.map_get_closest_point(map_rid, p)
				var d := Vector2(p.x - cl.x, p.z - cl.z).length()
				line += "%dm=%.1f " % [r_i, d]
			print("[P2] " + line)

	# ---- 4) 矿点 ----
	var map_node2: Node = a_match.get_node("Map")
	var resources: Node = map_node2.get_node_or_null("Resources")
	if resources != null:
		for res in resources.get_children():
			if res is Node3D:
				var rp: Vector3 = (res as Node3D).global_position
				var obstacle: Node = (res as Node3D).find_child("MovementObstacle", true, false)
				var radius: Variant = obstacle.get("radius") if obstacle != null else null
				var col: Node = (res as Node3D).find_child("CollisionShape3D", true, false)
				var shape_desc := "n/a"
				if col != null and col.get("shape") != null:
					var s: Shape3D = col.get("shape")
					shape_desc = "%s %s" % [s.get_class(), str(s.get("radius")) + "/" + str(s.get("height"))]
				print("[P2] 矿点 %-14s pos=(%.1f, %.1f) type=%s obstacle_radius=%s collider=%s body=%s" % [
					res.name, rp.x, rp.z, str(res.get("resource_type_id")) if res.get("resource_type_id") != null else "?",
					str(radius), shape_desc, res.get_class()])

	print("[P2] done")
	get_tree().quit(0)
