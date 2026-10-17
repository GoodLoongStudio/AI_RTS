extends Node

## =============================================================================
## 独立复核探针（复核方自写，不复用任何已有探针的结论）
##
## 目的：在**真实 Match** 里直接量 CollisionShape3D 形状与逻辑半径，
##       独立核对"逐单位定制碰撞体"重构的主张表。
##
## 量什么：
##   ① CollisionShape3D 的形状类型（枚举**全部**后代，不只第一个）
##   ② 水平半宽（含节点缩放）：Box = size.x/2 * scale.x；Cylinder/Capsule = radius * scale
##   ③ unit.radius（Unit.gd getter：Movement.radius → MovementObstacle.radius）
##      并分别打印 Movement.radius / MovementObstacle.radius 原始值
##   ④ 金矿：MovementObstacle.affect_navigation_mesh / carve_clearance_of / navmesh 最近点
##
## 运行（必须带实例环境变量，否则实例注册会自退）：
##   $env:AIRTS_INSTANCE_DIR=''; $env:AIRTS_INSTANCE_STRICT_DCS='0';
##   & 'G:\Godot_v4.7.1-stable_mono_win64\Godot_v4.7.1-stable_mono_win64_console.exe' --headless --path . res://tests/automated/_IndepVerifyColliders.tscn
## 输出全部带 [IVC] 前缀。
## =============================================================================

const MAP_SCENE := "res://source/match/maps/PlainAndSimple.tscn"

## 探针自带的清单（不引用任何断言表 / 已有探针的常量表）
const ROSTER := [
	["command_center", "res://source/match/units/CommandCenter.tscn"],
	["vehicle_factory", "res://source/match/units/VehicleFactory.tscn"],
	["barracks", "res://source/match/units/Barracks.tscn"],
	["aircraft_factory", "res://source/match/units/AircraftFactory.tscn"],
	["ore_refinery", "res://source/match/units/OreRefinery.tscn"],
	["anti_ground_turret", "res://source/match/units/AntiGroundTurret.tscn"],
	["anti_air_turret", "res://source/match/units/AntiAirTurret.tscn"],
	["machine_gun_turret", "res://source/match/units/MachineGunTurret.tscn"],
	["tank", "res://source/match/units/Tank.tscn"],
	["heavy_tank", "res://source/match/units/HeavyTank.tscn"],
	["apc", "res://source/match/units/APC.tscn"],
	["transport_truck", "res://source/match/units/TransportTruck.tscn"],
	["worker", "res://source/match/units/Worker.tscn"],
	["scout", "res://source/match/units/Scout.tscn"],
	["infantry", "res://source/match/units/Infantry.tscn"],
	["rocketeer", "res://source/match/units/Rocketeer.tscn"],
	["sniper", "res://source/match/units/Sniper.tscn"],
	["helicopter", "res://source/match/units/Helicopter.tscn"],
	["drone", "res://source/match/units/Drone.tscn"],
]

const ORES := [
	["ore_A_scene", "res://source/match/units/non-player/ResourceA.tscn"],
	["ore_B_scene", "res://source/match/units/non-player/ResourceB.tscn"],
]

var _t0 := 0


func _ready() -> void:
	_t0 = Time.get_ticks_msec()
	_watchdog()
	_run()


func _watchdog() -> void:
	await get_tree().create_timer(420.0).timeout
	print("[IVC] WATCHDOG_TIMEOUT 420s — 强制退出 rc=3")
	get_tree().quit(3)


func _run() -> void:
	var settings = load("res://source/data-model/MatchSettings.gd").new()
	var hs = load("res://source/data-model/PlayerSettings.gd").new()
	hs.controller = Constants.PlayerType.HUMAN
	hs.color = Constants.Player.COLORS[0]
	settings.players.append(hs)
	settings.visible_player = 0
	settings.local_player_index = 0
	var m: Node = load("res://source/match/Match.tscn").instantiate()
	m.settings = settings
	m.map = load(MAP_SCENE).instantiate()
	add_child(m)
	get_tree().current_scene = m
	print("[IVC] step=boot map_scene=", MAP_SCENE)
	for _f in range(240):
		await get_tree().physics_frame
	print("[IVC] step=match_ready ready=", m.is_node_ready(), " has_map=", m.get_node_or_null("Map") != null)
	var player: Node = m.get_node("Players").get_children()[0]
	print("[IVC] step=player name=", player.name)

	# ---------------------------------------------------------------- 出场：19 个单位
	var spawned := []
	var index := 0
	for entry in ROSTER:
		var inst = load(entry[1]).instantiate()
		var spot := Vector3(110.0, 0.0, 25.0 + float(index) * 9.0)
		m.call("_setup_and_spawn_unit", inst, Transform3D(Basis.IDENTITY, spot), player, false)
		spawned.append([entry[0], entry[1], inst, spot])
		index += 1
	print("[IVC] step=spawned count=", spawned.size())
	for _f in range(180):
		await get_tree().physics_frame

	# ---------------------------------------------------------------- 逐个量
	print("[IVC] ---- 单位形状 / 半径 ----")
	for row in spawned:
		_report_unit(str(row[0]), str(row[1]), row[2], row[3])

	# ---------------------------------------------------------------- 矿：地图自带实例
	print("[IVC] ---- 金矿（地图自带实例）----")
	var map_node: Node = m.get_node_or_null("Map")
	var resources_root: Node = map_node.get_node_or_null("Resources") if map_node != null else null
	if resources_root == null:
		print("[IVC] ORE|map_resources_root=null")
	else:
		var ore_nodes := []
		for child in resources_root.get_children():
			if child is Node3D:
				ore_nodes.append(child)
		print("[IVC] ORE|map_resource_count=", ore_nodes.size())
		for ore in ore_nodes:
			_report_ore("map/" + str(ore.name), ore)

	# ---------------------------------------------------------------- 矿：新实例化（场景默认值）
	# 注意：**不**走 _setup_and_spawn_unit —— 那条路会把矿塞进 "units" 组，
	# FogOfWar._sync_revealed_circles() 会对组内每个节点调 is_revealing()，
	# 而矿（ResourceUnit → Area3D）没有该方法 ⇒ 每帧 SCRIPT ERROR（探针自造的噪音）。
	# 真局里矿挂在 Map/Resources 下，这里按同一父节点挂，链路更忠实。
	print("[IVC] ---- 金矿（探针新实例化，挂 Map/Resources）----")
	var ore_parent: Node = resources_root if resources_root != null else m
	var ores := []
	var omega := 0
	for entry in ORES:
		var inst = load(entry[1]).instantiate()
		var spot := Vector3(60.0, 0.0, 100.0 + float(omega) * 12.0)
		spot.y = m.ground_height_at(spot)
		ore_parent.add_child(inst)
		inst.global_transform = Transform3D(Basis.IDENTITY, spot)
		ores.append([entry[0], inst])
		omega += 1
	for _f in range(90):
		await get_tree().physics_frame
	for row in ores:
		_report_ore(str(row[0]), row[1])

	# ---------------------------------------------------------------- carve_clearance_of 正负对照
	print("[IVC] ---- carve_clearance_of 对照 ----")
	var ref_ore = ores[0][1] if ores.size() > 0 else null
	var ref_building = null
	var ref_unit = null
	for row in spawned:
		if str(row[0]) == "barracks":
			ref_building = row[2]
		if str(row[0]) == "tank":
			ref_unit = row[2]
	if ref_ore != null:
		print("[IVC] CARVE|ore_A=%.4f" % float(Utils.Match.Unit.Movement.carve_clearance_of(ref_ore)))
	if ref_building != null:
		print("[IVC] CARVE|barracks=%.4f" % float(Utils.Match.Unit.Movement.carve_clearance_of(ref_building)))
	if ref_unit != null:
		print("[IVC] CARVE|tank=%.4f" % float(Utils.Match.Unit.Movement.carve_clearance_of(ref_unit)))
	if ref_ore != null and ref_building != null:
		print("[IVC] CARVE|building/ore 无关性: barracks>0 且 ore==0 ⇒ 洞只对 affect_navigation_mesh=true 的目标存在")

	# ---------------------------------------------------------------- navmesh 最近点（独立于属性的直接测量）
	print("[IVC] ---- navmesh 最近点（洞的间接测量）----")
	var map_rid := RID()
	if m.navigation != null and m.navigation.has_method("get_navigation_map_rid_by_domain"):
		map_rid = m.navigation.get_navigation_map_rid_by_domain(
			Constants.Match.Navigation.Domain.TERRAIN
		)
	print("[IVC] NAV|map_rid_valid=", map_rid.is_valid())
	if map_rid.is_valid():
		_probe_nav(m, map_rid, "open_ground_50_50", Vector3(50.0, 0.0, 50.0))
		if ref_ore != null:
			_probe_nav(m, map_rid, "ore_A(新实例)", ref_ore.global_position)
		if ores.size() > 1:
			_probe_nav(m, map_rid, "ore_B(新实例)", ores[1][1].global_position)
		if resources_root != null and resources_root.get_child_count() > 0:
			var first_ore = resources_root.get_child(0)
			_probe_nav(m, map_rid, "ore(地图自带)", first_ore.global_position)
		if ref_building != null:
			_probe_nav(m, map_rid, "barracks(对照组)", ref_building.global_position)
		if ref_unit != null:
			_probe_nav(m, map_rid, "tank", ref_unit.global_position)

	# ---------------------------------------------------------------- carve 洞边界逐方向直测（圆 vs 方盒）
	# 判据：从建筑中心沿 8 个方向向外走，找第一个"已经在导航面上"的点（最近点 == 自身）。
	#   若洞是 radius 圆 ⇒ 8 个方向半径基本相等（≈ obstacle.radius + agent）
	#   若洞是碰撞盒 + agent ⇒ 方向半径呈各向异性（x/z 两个值）
	# 为此把两栋建筑**孤立**放在远离其他障碍处（x=40，roster 列在 x=110）。
	print("[IVC] ---- carve 洞边界逐方向直测 ----")
	var region_node = m.get_node_or_null("Navigation/Terrain/NavigationRegion3D")
	if region_node != null and region_node.get("navigation_mesh") != null:
		var nm = region_node.get("navigation_mesh")
		print("[IVC] NAVMESH|agent_radius=%.4f|cell_size=%.4f|cell_height=%.4f" % [
			float(nm.get("agent_radius")), float(nm.get("cell_size")), float(nm.get("cell_height"))])
	var isolated := []
	for entry in [
		["barracks_isolated", "res://source/match/units/Barracks.tscn", Vector3(40.0, 0.0, 150.0)],
		["aircraft_isolated", "res://source/match/units/AircraftFactory.tscn", Vector3(40.0, 0.0, 178.0)],
	]:
		var inst = load(entry[1]).instantiate()
		m.call("_setup_and_spawn_unit", inst, Transform3D(Basis.IDENTITY, entry[2]), player, false)
		isolated.append([str(entry[0]), inst])
	for _f in range(180):
		await get_tree().physics_frame
	if map_rid.is_valid():
		for row in isolated:
			_probe_hole(m, map_rid, str(row[0]), row[1])

	# ---------------------------------------------------------------- 独立复算"碰撞体 ≤ 视觉半宽"不变量
	# 与 UnitRadiusCoverageSmokeTest 同口径，但由本探针自己在**真实 Match**里复算，
	# 不复用该测试的判定结果（该测试在 Match 外实例化单位，_ready 会报错退出）。
	print("[IVC] ---- 碰撞体 vs 视觉半宽（独立复算）----")
	for row in spawned:
		_report_coverage(str(row[0]), row[2])

	print("[IVC] DONE elapsed_ms=", Time.get_ticks_msec() - _t0)
	get_tree().quit(0)


func _is_ui_gizmo(node_name: String) -> bool:
	for keyword in ["Highlight", "Selection", "HealthBar", "Targetability", "Anchor", "Marker"]:
		if keyword in node_name:
			return true
	return false


## 视觉半宽：所有 MeshInstance3D 世界 AABB 并集的 max(size.x, size.z)/2（剔除 UI 告板）。
func _visual_half(u: Node3D) -> float:
	var result := AABB()
	var first := true
	var stack: Array = [u]
	while not stack.is_empty():
		var node = stack.pop_back()
		for child in node.get_children():
			stack.push_back(child)
		if not (node is MeshInstance3D):
			continue
		if _is_ui_gizmo(node.name):
			continue
		var mesh: Mesh = node.mesh
		if mesh == null:
			continue
		var world_aabb: AABB = node.global_transform * mesh.get_aabb()
		result = world_aabb if first else result.merge(world_aabb)
		first = false
	if first:
		return -1.0
	return maxf(result.size.x, result.size.z) / 2.0


## 几何碰撞半宽：三种形状都从 CollisionShape3D 回读（与修复后的判据同口径）。
func _geometric_collision_half(u: Node3D) -> float:
	var cs := u.find_child("CollisionShape3D", true, false) as CollisionShape3D
	if cs == null or cs.shape == null:
		return -1.0
	var scale: Vector3 = cs.global_transform.basis.get_scale()
	var s := cs.shape
	if s is CylinderShape3D:
		return (s as CylinderShape3D).radius * scale.x
	if s is CapsuleShape3D:
		return (s as CapsuleShape3D).radius * scale.x
	if s is BoxShape3D:
		var box := s as BoxShape3D
		return maxf(box.size.x * scale.x, box.size.z * scale.z) * 0.5
	return -1.0


func _report_coverage(key: String, u: Node) -> void:
	if not is_instance_valid(u):
		print("[IVC] COV|%s|INVALID" % key)
		return
	var collision := _geometric_collision_half(u as Node3D)
	var half := _visual_half(u as Node3D)
	var verdict := "PASS"
	if collision < 0.0:
		verdict = "FAIL(读不到几何)"
	elif half < 0.0:
		verdict = "FAIL(读不到视觉)"
	elif collision > half + 0.05:
		verdict = "FAIL(超出视觉)"
	print(
		"[IVC] COV|%s|geometric_collision=%.4f|visual_half=%.4f|margin=%.4f|%s"
		% [key, collision, half, half - collision, verdict]
	)


## 逐方向测 carve 洞边界：从建筑中心沿 8 个方向向外步进，找第一个"已经在导航面上"
## （最近点 ≈ 查询点）的半径。圆洞 ⇒ 8 向半径近似相等；方盒洞 ⇒ 各向异性。
func _probe_hole(m: Node, map_rid: RID, tag: String, u: Node) -> void:
	if not is_instance_valid(u):
		print("[IVC] HOLE|%s|INVALID" % tag)
		return
	var obstacle := u.find_child("MovementObstacle", true, false)
	if obstacle == null:
		print("[IVC] HOLE|%s|NO_OBSTACLE" % tag)
		return
	var ob_radius := float(obstacle.get("radius"))
	var from_bounds := true
	if obstacle.get("carve_from_collision_bounds") != null:
		from_bounds = bool(obstacle.get("carve_from_collision_bounds"))
	var agent := 2.8
	var region = m.get_node_or_null("Navigation/Terrain/NavigationRegion3D")
	if region != null and region.get("navigation_mesh") != null:
		agent = float(region.get("navigation_mesh").get("agent_radius"))
	var half_x := -1.0
	var half_z := -1.0
	var cs := u.find_child("CollisionShape3D", true, false) as CollisionShape3D
	if cs != null:
		var d := _shape_detail(cs)
		half_x = float(d["half_x"])
		half_z = float(d["half_z"])
	var center := Vector3(u.global_position.x, m.ground_height_at(u.global_position), u.global_position.z)
	var parts := []
	for i in 8:
		var ang := TAU * float(i) / 8.0
		var dir := Vector3(cos(ang), 0.0, sin(ang))
		var found := -1.0
		var r := 0.0
		while r <= 9.0:
			var p := center + dir * r
			var c: Vector3 = NavigationServer3D.map_get_closest_point(map_rid, p)
			if Vector2(c.x - p.x, c.z - p.z).length() <= 0.15:
				found = r
				break
			r += 0.1
		parts.append("%.0fdeg:%.1f" % [rad_to_deg(ang), found])
	print(
		(
			"[IVC] HOLE|%s|obstacle.radius=%.3f|carve_from_bounds=%s|agent=%.3f"
			+ "|predicted_circle=%.3f|collision_half=(%.3f,%.3f)|predicted_box=(%.3f,%.3f)"
			+ "|8dirs=[%s]"
		)
		% [
			tag,
			ob_radius,
			str(from_bounds),
			agent,
			ob_radius + agent,
			half_x,
			half_z,
			half_x + agent,
			half_z + agent,
			", ".join(parts),
		]
	)


func _probe_nav(m: Node, map_rid: RID, tag: String, at: Vector3) -> void:
	var grounded := Vector3(at.x, m.ground_height_at(at), at.z)
	var closest: Vector3 = NavigationServer3D.map_get_closest_point(map_rid, grounded)
	var d := Vector2(closest.x - grounded.x, closest.z - grounded.z).length()
	print(
		"[IVC] NAV|%s|at=(%.2f,%.2f)|closest=(%.2f,%.2f)|xz_dist=%.3f"
		% [tag, grounded.x, grounded.z, closest.x, closest.z, d]
	)


# =============================================================================
# 形状 / 半径
# =============================================================================
func _shape_detail(cs: CollisionShape3D) -> Dictionary:
	var out := {
		"cls": "null",
		"half_x": -1.0,
		"half_z": -1.0,
		"params": "",
		"scale": Vector3.ONE,
	}
	if cs == null or cs.shape == null:
		return out
	var shape := cs.shape
	var s := cs.global_transform.basis.get_scale()
	out["scale"] = s
	out["cls"] = shape.get_class()
	if shape is CylinderShape3D:
		var c := shape as CylinderShape3D
		out["half_x"] = c.radius * absf(s.x)
		out["half_z"] = c.radius * absf(s.z)
		out["params"] = "radius=%.4f height=%.4f" % [c.radius, c.height]
	elif shape is CapsuleShape3D:
		var c := shape as CapsuleShape3D
		out["half_x"] = c.radius * absf(s.x)
		out["half_z"] = c.radius * absf(s.z)
		out["params"] = "radius=%.4f height=%.4f" % [c.radius, c.height]
	elif shape is BoxShape3D:
		var b := shape as BoxShape3D
		out["half_x"] = b.size.x * 0.5 * absf(s.x)
		out["half_z"] = b.size.z * 0.5 * absf(s.z)
		out["params"] = "size=(%.4f,%.4f,%.4f)" % [b.size.x, b.size.y, b.size.z]
	elif shape is SphereShape3D:
		var sp := shape as SphereShape3D
		out["half_x"] = sp.radius * absf(s.x)
		out["half_z"] = sp.radius * absf(s.z)
		out["params"] = "radius=%.4f" % sp.radius
	else:
		out["params"] = "UNHANDLED_SHAPE"
	return out


func _num_or_null(value) -> String:
	return "null" if value == null else "%.4f" % float(value)


func _report_unit(key: String, scene_path: String, u: Node, spot: Vector3) -> void:
	if not is_instance_valid(u):
		print("[IVC] U|%s|INVALID_INSTANCE" % key)
		return
	var cs_nodes := u.find_children("*", "CollisionShape3D", true, false)
	var detail_parts := []
	var half_max := -1.0
	var classes := []
	for node in cs_nodes:
		var cs := node as CollisionShape3D
		var d := _shape_detail(cs)
		detail_parts.append(
			"%s:%s{%s scale=(%.3f,%.3f,%.3f)}"
			% [
				str(u.get_path_to(cs)),
				str(d["cls"]),
				str(d["params"]),
				d["scale"].x,
				d["scale"].y,
				d["scale"].z,
			]
		)
		classes.append(str(d["cls"]))
		half_max = maxf(half_max, maxf(float(d["half_x"]), float(d["half_z"])))
	var movement := u.find_child("Movement", true, false)
	var obstacle := u.find_child("MovementObstacle", true, false)
	print(
		(
			"[IVC] U|%s|type_id=%s|shapes=%d|classes=%s|half_max=%.4f|radius=%s"
			+ "|Movement.radius=%s|MovementObstacle.radius=%s|spawn=(%.1f,%.1f)|pos=(%.2f,%.2f)|detail=%s"
		)
		% [
			key,
			str(u.get("unit_type_id")),
			cs_nodes.size(),
			str(classes),
			half_max,
			_num_or_null(u.get("radius")),
			_num_or_null(movement.get("radius") if movement != null else null),
			_num_or_null(obstacle.get("radius") if obstacle != null else null),
			spot.x,
			spot.z,
			u.global_position.x,
			u.global_position.z,
			" | ".join(detail_parts),
		]
	)
	for node in cs_nodes:
		var cs := node as CollisionShape3D
		var d := _shape_detail(cs)
		print(
			"[IVC] U-SHAPE|%s|%s|%s|half_x=%.4f|half_z=%.4f"
			% [key, str(u.get_path_to(cs)), str(d["cls"]), d["half_x"], d["half_z"]]
		)


func _report_ore(key: String, ore: Node) -> void:
	if not is_instance_valid(ore):
		print("[IVC] ORE|%s|INVALID_INSTANCE" % key)
		return
	var obstacle := ore.find_child("MovementObstacle", false, false)
	if obstacle == null:
		print("[IVC] ORE|%s|NO_MOVEMENT_OBSTACLE(直接子节点)" % key)
		return
	var verts: PackedVector3Array = obstacle.get("vertices")
	var vert_extent := 0.0
	for v in verts:
		vert_extent = maxf(vert_extent, Vector2(v.x, v.z).length())
	var clearance := float(Utils.Match.Unit.Movement.carve_clearance_of(ore))
	var cs_nodes := ore.find_children("*", "CollisionShape3D", true, false)
	var cs_cls := "none"
	var cs_half := -1.0
	if cs_nodes.size() > 0:
		var d := _shape_detail(cs_nodes[0] as CollisionShape3D)
		cs_cls = str(d["cls"])
		cs_half = float(d["half_x"])
	print(
		(
			"[IVC] ORE|%s|scene=%s|affect_navigation_mesh=%s|carve_from_collision_bounds=%s"
			+ "|obstacle.radius=%s|ore.radius=%s|vertices_n=%d|vertices_extent=%.4f"
			+ "|carve_clearance_of=%.4f|collision_shape=%s half_x=%.4f|pos=(%.2f,%.2f)"
		)
		% [
			key,
			str(ore.get("unit_type_id")),
			str(obstacle.get("affect_navigation_mesh")),
			str(obstacle.get("carve_from_collision_bounds")),
			_num_or_null(obstacle.get("radius")),
			_num_or_null(ore.get("radius")),
			verts.size(),
			vert_extent,
			clearance,
			cs_cls,
			cs_half,
			ore.global_position.x,
			ore.global_position.z,
		]
	)
