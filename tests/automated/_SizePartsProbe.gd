extends Node

## 异常项归因（2026-09-30）：列出每个单位**体积最大的 3 个网格**（含节点路径与本地尺寸），
## 并对蒙皮模型（步兵）改用 Skeleton3D 骨骼包围盒，绕开 MeshInstance3D.get_aabb() 的假值。

const MAP_SCENE := "res://source/match/maps/PlainAndSimple.tscn"
const ROSTER := ["AircraftFactory", "Scout", "Infantry", "Sniper", "OreRefinery", "CommandCenter"]


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
	var z := 60.0
	for name in ROSTER:
		m.call("_setup_and_spawn_unit", load("res://source/match/units/" + name + ".tscn").instantiate(),
			Transform3D(Basis.IDENTITY, Vector3(60.0, 0.0, z)), p, false)
		z += 10.0
	for _f in range(40):
		await get_tree().physics_frame
	for u in p.get_children():
		var t := str(u.get("unit_type_id"))
		if t == "<null>" or not ROSTER.has(t.capitalize().replace(" ", "")) and t not in ["aircraft_factory", "scout", "soldier", "sniper", "ore_refinery", "command_center"]:
			continue
		var to_local: Transform3D = (u as Node3D).global_transform.affine_inverse()
		var parts := []
		for gi in u.find_children("*", "GeometryInstance3D", true, false):
			var path := str(gi.get_path())
			if path.contains("Selection") or path.contains("Highlight") or path.contains("Targetability") \
					or path.contains("HealthBar") or path.contains("RallyPoint") or path.contains("AirToTerrainMarker"):
				continue
			var aabb: AABB = (gi as GeometryInstance3D).get_aabb()
			if gi is MeshInstance3D and (gi as MeshInstance3D).mesh != null and aabb.size.length() < 0.01:
				aabb = (gi as MeshInstance3D).mesh.get_aabb()
			var xf: Transform3D = to_local * (gi as Node3D).global_transform
			var box := AABB()
			var first := true
			for i in range(8):
				var pt: Vector3 = xf * aabb.get_endpoint(i)
				if first:
					box = AABB(pt, Vector3.ZERO); first = false
				else:
					box = box.expand(pt)
			var s := box.size
			parts.append([s.x * s.y * s.z, str(gi.get_path()).replace(str(u.get_path()) + "/", ""), s])
		parts.sort_custom(func(a, b): return a[0] > b[0])
		var skel := ""
		for sk in u.find_children("*", "Skeleton3D", true, false):
			var bone_first := true
			var bmin := Vector3.ZERO
			var bmax := Vector3.ZERO
			for b in range((sk as Skeleton3D).get_bone_count()):
				var bp: Vector3 = to_local * ((sk as Skeleton3D).global_transform * (sk as Skeleton3D).get_bone_global_pose(b).origin)
				if bone_first:
					bmin = bp; bmax = bp; bone_first = false
				else:
					bmin = Vector3(minf(bmin.x, bp.x), minf(bmin.y, bp.y), minf(bmin.z, bp.z))
					bmax = Vector3(maxf(bmax.x, bp.x), maxf(bmax.y, bp.y), maxf(bmax.z, bp.z))
			skel = " 骨骼包围盒=" + str((bmax - bmin).snapped(Vector3(0.01, 0.01, 0.01))) + "(" + str((sk as Skeleton3D).get_bone_count()) + " 骨)"
		print("[PARTS] === ", t, skel)
		for i in range(mini(3, parts.size())):
			var e = parts[i]
			print("[PARTS]   %-52s %s" % [str(e[1]).substr(0, 52), str((e[2] as Vector3).snapped(Vector3(0.01, 0.01, 0.01)))])
	get_tree().quit(0)
