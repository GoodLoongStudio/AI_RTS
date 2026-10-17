extends Node

## 世界尺度审计探针（2026-10-01）：一表直读每单位**运行时**全部口径。
## 输出列：类型|视觉AABB|物理形状|物理半宽|物理高|Movement.r|Obstacle.r|carve外缘|
##         speed|attack_range|sight_range|ProjectileOrigin本地偏移|balance footprint
## 来源：运行时属性（ConfigureUnit 注入 + 场景节点）+ 平衡 JSON footprint 对照。

const MAP_SCENE := "res://source/match/maps/PlainAndSimple.tscn"
const ROSTER := [
	["CommandCenter", "建筑"], ["VehicleFactory", "建筑"], ["Barracks", "建筑"],
	["OreRefinery", "建筑"], ["AircraftFactory", "建筑"],
	["AntiGroundTurret", "炮塔"], ["AntiAirTurret", "炮塔"], ["MachineGunTurret", "炮塔"],
	["Tank", "载具"], ["HeavyTank", "载具"], ["APC", "载具"], ["TransportTruck", "载具"],
	["Worker", "载具"], ["Scout", "载具"],
	["Helicopter", "空中"], ["Drone", "空中"],
	["Infantry", "步兵"], ["Rocketeer", "步兵"], ["Sniper", "步兵"],
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
	# 平衡 footprint 对照表
	var balance: Dictionary = {}
	var catalog: Node = m.get_node("BalanceConfigRuntime")
	for entry in ROSTER:
		var proto = load("res://source/match/units/%s.tscn" % entry[0])
		var cost_def = catalog.get("Catalog")
		balance[entry[0]] = _balance_footprint(catalog, proto)
	var spawned := {}
	var z := 60.0
	print("[AUDIT] 类型|单位|visAABB(LxHxW)|physShape|physHalf|physH|Mv.r|Obs.r|carve|speed|atkRange|sight|muzzleXYZ|balFootprint")
	for entry in ROSTER:
		var proto = load("res://source/match/units/%s.tscn" % entry[0])
		var inst = proto.instantiate()
		var scene_default: Variant = inst.find_child("Movement", true, false).get("speed") \
			if inst.find_child("Movement", true, false) != null else null
		m.call("_setup_and_spawn_unit", inst, Transform3D(Basis.IDENTITY, Vector3(60.0, 0.0, z)), p, false)
		var at_spawn: Variant = inst.find_child("Movement", true, false).get("speed") \
			if inst.find_child("Movement", true, false) != null else null
		print("[SPEED-STAGE] %s scene默认=%s 出生后=%s" % [
			entry[0],
			"null" if scene_default == null else "%.3f" % float(scene_default),
			"null" if at_spawn == null else "%.3f" % float(at_spawn)])
		spawned[inst] = entry
		z += 10.0
	for _f in range(60):
		await get_tree().physics_frame
	for inst in spawned:
		if not is_instance_valid(inst):
			continue
		var entry: Array = spawned[inst]
		var vis := _vis_aabb(inst)
		var cs := inst.find_child("CollisionShape3D", true, false) as CollisionShape3D
		var shape := "无"
		var half := -1.0
		var height := -1.0
		if cs != null and cs.shape != null:
			var sc: Vector3 = cs.global_transform.basis.get_scale()
			if cs.shape is CylinderShape3D:
				shape = "Cyl"
				half = (cs.shape as CylinderShape3D).radius * sc.x
				height = (cs.shape as CylinderShape3D).height * sc.y
			elif cs.shape is BoxShape3D:
				shape = "Box"
				var bsize: Vector3 = (cs.shape as BoxShape3D).size * sc
				half = bsize.x * 0.5
				height = bsize.y
			elif cs.shape is CapsuleShape3D:
				shape = "Cap"
				half = (cs.shape as CapsuleShape3D).radius * sc.x
				height = (cs.shape as CapsuleShape3D).height * sc.y
		var mv_r: Variant = inst.get("radius")
		var mv := "null" if mv_r == null else "%.2f" % float(mv_r)
		var mv_node: Node = inst.find_child("Movement", true, false)
		if mv_node != null and mv_node.get("radius") != null:
			mv = "%.2f" % float(mv_node.get("radius"))
		var obs_r := "null"
		var carve := 0.0
		var ob: Node = inst.find_child("MovementObstacle", true, false)
		if ob != null:
			if ob.get("radius") != null:
				obs_r = "%.2f" % float(ob.get("radius"))
			for v in (ob.get("vertices") as PackedVector3Array):
				carve = maxf(carve, Vector2(v.x, v.z).length())
		var speed: Variant = mv_node.get("speed") if mv_node != null else null
		var atk: Variant = inst.get("attack_range")
		var sight: Variant = inst.get("sight_range")
		var muzzle := _muzzle_local(inst)
		print("[AUDIT] %s|%s|%s|%s|%.2f|%.2f|%s|%s|%.2f|%s|%s|%s|%s|%s" % [
			entry[1], str(inst.get("unit_type_id")),
			"%.2fx%.2fx%.2f" % [vis.x, vis.y, vis.z],
			shape, half, height, mv, obs_r, carve,
			("null" if speed == null else "%.2f" % float(speed)),
			("null" if atk == null else "%.2f" % float(atk)),
			("null" if sight == null else "%.2f" % float(sight)),
			muzzle, str(balance.get(entry[0], "n/a"))])
	get_tree().quit(0)


func _balance_footprint(catalog: Node, proto: PackedScene) -> String:
	if catalog == null or catalog.get("Catalog") == null:
		return "n/a"
	var path: String = proto.resource_path
	var unit_type_id: String = catalog.Assets.FindUnitType(path) if catalog.get("Assets") != null else ""
	if unit_type_id.is_empty():
		return "n/a"
	for c in catalog.Catalog.Constructions:
		if c.UnitTypeId.Value == unit_type_id:
			return "%.2f" % c.Placement.FootprintRadius
	return "无(非建筑)"


func _vis_aabb(unit) -> Vector3:
	var first := true
	var box := AABB()
	var to_local: Transform3D = (unit as Node3D).global_transform.affine_inverse()
	for gi in unit.find_children("*", "GeometryInstance3D", true, false):
		var p := str(gi.get_path())
		if p.contains("Selection") or p.contains("Highlight") or p.contains("Targetability") \
				or p.contains("HealthBar") or p.contains("RallyPoint") or p.contains("AirToTerrainMarker") \
				or p.contains("ProjectileOrigin") or p.contains("Anchor"):
			continue
		var aabb: AABB
		if gi is MeshInstance3D and (gi as MeshInstance3D).mesh != null:
			aabb = (gi as MeshInstance3D).get_aabb()
			if aabb.size.length() < 0.01:
				aabb = (gi as MeshInstance3D).mesh.get_aabb()
		else:
			aabb = (gi as GeometryInstance3D).get_aabb()
		if aabb.size.length() < 0.001:
			continue
		var xf: Transform3D = to_local * (gi as Node3D).global_transform
		for i in range(8):
			var pt: Vector3 = xf * aabb.get_endpoint(i)
			if first:
				box = AABB(pt, Vector3.ZERO)
				first = false
			else:
				box = box.expand(pt)
	if box.size.y < 0.1 or box.size.length() < 0.1:
		# 蒙皮退化 → 骨骼姿态包围盒
		for sk in unit.find_children("*", "Skeleton3D", true, false):
			for b in range((sk as Skeleton3D).get_bone_count()):
				var bp: Vector3 = to_local * ((sk as Skeleton3D).global_transform \
					* (sk as Skeleton3D).get_bone_global_pose(b).origin)
				if first:
					box = AABB(bp, Vector3.ZERO)
					first = false
				else:
					box = box.expand(bp)
	return box.size


func _muzzle_local(unit) -> String:
	var out: Array = []
	for marker_name in ["ProjectileOrigin", "Muzzle", "MuzzleMarker"]:
		var mk: Node = unit.find_child(marker_name, true, false)
		if mk is Node3D:
			var lp: Vector3 = (mk as Node3D).position
			out.append("%s(%.2f,%.2f,%.2f)" % [marker_name, lp.x, lp.y, lp.z])
	return "无" if out.is_empty() else "+".join(out)
