extends Node

## 尺寸审计探针 v3（2026-09-30）。
## 口径修正史（重要，别再犯）：
##   v1: collision = CylinderShape3D.radius 原值        → 漏乘 root scale 3（把本地当世界）
##   v2: 用 AABB 角点距离当半径                          → 对圆柱/方形网格多算 √2
##   v3: 半径 = 世界 AABB 在 X 与 Z 上的【分量半宽】取大者（圆柱=AABB半宽=真半径；
##       立方体=面到心距离）。同时打印角点距离供对照，并逐形状/逐网格列明细，避免最大值掩盖异常。
## 四类口径：visual / collision / logical(Movement|MovementObstacle) / nav carve(NavigationObstacle3D)

const AUDIT_SCENES := {
	"CommandCenter": "res://source/match/units/CommandCenter.tscn",
	"VehicleFactory": "res://source/match/units/VehicleFactory.tscn",
	"Barracks": "res://source/match/units/Barracks.tscn",
	"OreRefinery": "res://source/match/units/OreRefinery.tscn",
	"AntiGroundTurret": "res://source/match/units/AntiGroundTurret.tscn",
	"Infantry": "res://source/match/units/Infantry.tscn",
	"Tank": "res://source/match/units/Tank.tscn",
	"Worker": "res://source/match/units/Worker.tscn",
	"Drone": "res://source/match/units/Drone.tscn",
	"ResourceA": "res://source/match/units/non-player/ResourceA.tscn",
}

const MAP_SCENE := "res://source/match/maps/PlainAndSimple.tscn"


func _ready():
	var settings = load("res://source/data-model/MatchSettings.gd").new()
	var human = load("res://source/data-model/PlayerSettings.gd").new()
	human.controller = Constants.PlayerType.HUMAN
	human.color = Constants.Player.COLORS[0]
	settings.players.append(human)
	settings.visible_player = 0
	var a_match: Node = load("res://source/match/Match.tscn").instantiate()
	a_match.settings = settings
	a_match.map = load(MAP_SCENE).instantiate()
	add_child(a_match)
	get_tree().current_scene = a_match
	for _frame in range(240):
		await get_tree().physics_frame

	var human_node: Node = a_match.get_node("Players").get_children()[0]
	var agent_radius := 2.8
	var nav_region = a_match.get_node_or_null("Navigation/Terrain/NavigationRegion3D")
	if nav_region != null:
		var mesh = nav_region.get("navigation_mesh")
		if mesh != null:
			agent_radius = float(mesh.get("agent_radius"))

	print("[AUDIT] agent_radius=%.3f  半径口径=世界AABB分量半宽" % agent_radius)
	print("[AUDIT] %-17s %8s %8s %8s %8s %7s  %s" % ["unit", "visual", "collis", "logical", "carve", "corner", "detail"])
	for key in AUDIT_SCENES:
		var scene: PackedScene = load(AUDIT_SCENES[key])
		if scene == null:
			print("[AUDIT] %-17s 场景加载失败" % key)
			continue
		var node: Node3D = scene.instantiate()
		# 【2026-09-30 修正】旧实现把单位生成在 (1000,0,1000)——**地图外**，
		# _setup_and_spawn_unit 会把它吸附到最近导航点 (204.9,204.9)，而炮塔那种
		# 由 RemoteTransform3D 托管的 Geometry 没跟着搬，于是量出"视觉外缘 797m"
		# 的假异常（实为探针假象，非玩家可见缺陷）。现在在地图内的空地生成，
		# 并回读真实落点，保证"测的就是摆在那儿的那个单位"。
		a_match.call("_setup_and_spawn_unit", node,
			Transform3D(Basis.IDENTITY, Vector3(170, 0, 40)), human_node, false)
		await get_tree().physics_frame
		await get_tree().process_frame
		print("[AUDIT] %-18s 实际落点=%s（期望 170,0,40）" % [key, str(node.global_position.snapped(Vector3(0.01, 0.01, 0.01)))])

		var center := Vector2(node.global_position.x, node.global_position.z)
		var vis := _visual_extent(node, center)
		var col := _collision_extent(node, center)
		var cor := maxf(vis.y, col.y)
		var logical := 0.0
		var mv = node.find_child("Movement", true, false)
		var ob = node.find_child("MovementObstacle", true, false)
		if mv != null:
			logical = float(mv.get("radius"))
		elif ob != null:
			logical = float(ob.get("radius"))
		var carve := 0.0
		var nav_detail := "-"
		var nav_ob: Node = node.find_child("NavigationObstacle3D", true, false)
		if nav_ob == null:
			for sub in node.find_children("*", "NavigationObstacle3D", true, false):
				nav_ob = sub
				break
		if nav_ob != null:
			var ns: float = nav_ob.global_transform.basis.get_scale().x
			var verts := 0
			if nav_ob.get("vertices") != null:
				verts = (nav_ob.get("vertices") as PackedVector3Array).size()
			carve = float(nav_ob.get("radius")) * ns + agent_radius
			nav_detail = "r=%.3f scale=%.2f verts=%d affect=%s" % [
				float(nav_ob.get("radius")), ns, verts, str(nav_ob.get("affect_navigation_mesh"))]
		print("[AUDIT] %-17s %8.2f %8.2f %8.2f %8.2f %7.2f  %s" % [
			key, vis.x, col.x, logical, carve, cor, nav_detail])
		if logical > 0.0:
			print("[AUDIT]%-18s Δ(collis-logical)=%+.2f (%.1f%%)   Δ(visual-logical)=%+.2f (%.1f%%)" % [
				"", col.x - logical, (col.x - logical) / logical * 100.0,
				vis.x - logical, (vis.x - logical) / logical * 100.0])
		for line in vis.y:
			pass
		node.queue_free()
		await get_tree().process_frame

	get_tree().quit(0)


## 返回 Vector2(分量半宽最大值, 角点距离最大值)；第二分量给碰撞用同一约定
func _visual_extent(node: Node3D, center: Vector2) -> Vector2:
	var ext := 0.0
	var corner := 0.0
	var details: Array = []
	for sub in node.find_children("*", "GeometryInstance3D", true, false):
		var gi: GeometryInstance3D = sub
		var aabb: AABB = gi.get_aabb()
		if aabb.size.length_squared() <= 0.0 and gi is MeshInstance3D:
			var m: Mesh = (gi as MeshInstance3D).mesh
			if m != null:
				aabb = m.get_aabb()
		var e := 0.0
		var c := 0.0
		for pt in _aabb_corners(aabb):
			var w: Vector3 = gi.global_transform * pt
			e = maxf(e, maxf(absf(w.x - center.x), absf(w.z - center.y)))
			c = maxf(c, Vector2(w.x, w.z).distance_to(center))
		if e > ext:
			ext = e
		corner = maxf(corner, c)
		details.append("%s ext=%.2f aabb=%s" % [gi.name, e, str(aabb.size)])
	if details.size() > 0:
		print("[AUDIT]    meshes: " + ", ".join(details).substr(0, 420))
	return Vector2(ext, corner)


func _collision_extent(node: Node3D, center: Vector2) -> Vector2:
	var ext := 0.0
	var corner := 0.0
	var details: Array = []
	for sub in node.find_children("*", "CollisionShape3D", true, false):
		var cs: CollisionShape3D = sub
		if cs.shape == null:
			continue
		var aabb := _shape_local_aabb(cs.shape)
		var e := 0.0
		var c := 0.0
		for pt in _aabb_corners(aabb):
			var w: Vector3 = cs.global_transform * pt
			e = maxf(e, maxf(absf(w.x - center.x), absf(w.z - center.y)))
			c = maxf(c, Vector2(w.x, w.z).distance_to(center))
		ext = maxf(ext, e)
		corner = maxf(corner, c)
		details.append("%s[%s local=%s scale=%.2f] worldExt=%.2f" % [
			cs.name, cs.shape.get_class(), str(aabb.size), cs.global_transform.basis.get_scale().x, e])
	print("[AUDIT]    shapes: " + ", ".join(details).substr(0, 420))
	return Vector2(ext, corner)


func _shape_local_aabb(shape: Shape3D) -> AABB:
	if shape is CylinderShape3D:
		var c: CylinderShape3D = shape
		return AABB(Vector3(-c.radius, -c.height * 0.5, -c.radius),
			Vector3(c.radius * 2.0, c.height, c.radius * 2.0))
	if shape is BoxShape3D:
		var b: BoxShape3D = shape
		return AABB(-b.size * 0.5, b.size)
	if shape is CapsuleShape3D:
		var cap: CapsuleShape3D = shape
		return AABB(Vector3(-cap.radius, -cap.height * 0.5 - cap.radius, -cap.radius),
			Vector3(cap.radius * 2.0, cap.height + cap.radius * 2.0, cap.radius * 2.0))
	if shape is SphereShape3D:
		var s: SphereShape3D = shape
		return AABB(Vector3(-s.radius, -s.radius, -s.radius),
			Vector3(s.radius * 2.0, s.radius * 2.0, s.radius * 2.0))
	return AABB()


func _aabb_corners(aabb: AABB) -> Array:
	var p := aabb.position
	var s := aabb.size
	return [
		p, p + Vector3(s.x, 0, 0), p + Vector3(0, 0, s.z), p + Vector3(s.x, 0, s.z),
	]
