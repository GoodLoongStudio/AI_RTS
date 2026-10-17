extends Node

## 单位/建筑三维尺寸实测（2026-09-30）。
## 口径：把每个**真实几何网格**的 AABB 变换到**单位本地空间**后取并集 ⇒ (长 X, 高 Y, 宽 Z)，
## 因此不受单位朝向影响、也不含选中圈/血条/瞄准圈等装饰。
## 等 30 帧再读：蒙皮网格（步兵）在骨架就位前 get_aabb() 会返回近 0 的假值。

const MAP_SCENE := "res://source/match/maps/PlainAndSimple.tscn"
const ROSTER := [
	["CommandCenter", "建筑"], ["VehicleFactory", "建筑"], ["Barracks", "建筑"],
	["OreRefinery", "建筑"], ["AircraftFactory", "建筑"],
	["AntiGroundTurret", "炮塔"], ["AntiAirTurret", "炮塔"], ["MachineGunTurret", "炮塔"],
	["Tank", "载具"], ["HeavyTank", "载具"], ["APC", "载具"], ["TransportTruck", "载具"], ["Worker", "载具"],
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
	var spawned := {}
	var z := 60.0
	for entry in ROSTER:
		var name: String = entry[0]
		var proto = load("res://source/match/units/" + name + ".tscn")
		var inst = proto.instantiate()
		m.call("_setup_and_spawn_unit", inst, Transform3D(Basis.IDENTITY, Vector3(60.0, 0.0, z)), p, false)
		spawned[str(inst.get("unit_type_id"))] = entry[1]
		z += 9.0
	# 骨架/动画就位
	for _f in range(40):
		await get_tree().physics_frame
	print("[SIZE] 类别|名称|长X|高Y|宽Z|体积|网格数")
	for u in p.get_children():
		var t := str(u.get("unit_type_id"))
		if t == "<null>" or not spawned.has(t):
			continue
		var box := _local_union_aabb(u)
		if box.size.y < 0.1 or box.size.length() < 0.1:
			# 蒙皮网格绑定姿态假值：退化到骨骼姿态包围盒，绝不把 0 当真实尺寸。
			box = _skeleton_union_aabb(u)
		var size := box.size
		print("[SIZE] %s|%s|%.2f|%.2f|%.2f|%.2f|%d" % [
			spawned[t], t, size.x, size.y, size.z, size.x * size.y * size.z, _mesh_count(u)])
	get_tree().quit(0)


## 蒙皮模型（步兵）的网格 AABB 是绑定姿态假值（实测近 0）⇒ 用 Skeleton3D 骨骼
## 运行时姿态包围盒替代（与 _SizePartsProbe 同口径；骨关节并集略小于真实网格）。
func _skeleton_union_aabb(unit) -> AABB:
	var first := true
	var box := AABB()
	var to_local: Transform3D = (unit as Node3D).global_transform.affine_inverse()
	for sk in unit.find_children("*", "Skeleton3D", true, false):
		for b in range((sk as Skeleton3D).get_bone_count()):
			var bp: Vector3 = to_local * ((sk as Skeleton3D).global_transform \
				* (sk as Skeleton3D).get_bone_global_pose(b).origin)
			if first:
				box = AABB(bp, Vector3.ZERO)
				first = false
			else:
				box = box.expand(bp)
	return box


func _mesh_count(unit) -> int:
	var n := 0
	for gi in _visual_meshes(unit):
		n += 1
	return n


func _visual_meshes(unit) -> Array:
	var out := []
	for gi in unit.find_children("*", "GeometryInstance3D", true, false):
		var path := str(gi.get_path())
		if path.contains("Selection") or path.contains("Highlight") or path.contains("Targetability") \
				or path.contains("HealthBar") or path.contains("RallyPoint") or path.contains("AirToTerrainMarker") \
				or path.contains("ProjectileOrigin") or path.contains("Anchor"):
			continue
		out.append(gi)
	return out


## 单位本地空间里所有几何网格 AABB 的并集。
func _local_union_aabb(unit) -> AABB:
	var first := true
	var box := AABB()
	var to_local: Transform3D = (unit as Node3D).global_transform.affine_inverse()
	for gi in _visual_meshes(unit):
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
			var corner: Vector3 = aabb.get_endpoint(i)
			var pt: Vector3 = xf * corner
			if first:
				box = AABB(pt, Vector3.ZERO)
				first = false
			else:
				box = box.expand(pt)
	return box
