extends Node

## 单位视觉实测（2026-09-30）：把建筑与单位并排生成，量**渲染网格**的世界尺寸，
## 用来核对"建筑 : 单位"的真实比例是否等于快照值（主基地 13.91 / 坦克 4.00 / 步兵 2.70）。

const MAP_SCENE := "res://source/match/maps/PlainAndSimple.tscn"


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
	var roster := ["CommandCenter", "VehicleFactory", "Barracks", "OreRefinery", "AntiGroundTurret", "Tank", "Worker", "Infantry", "HeavyTank"]
	var z := 60.0
	for name in roster:
		var proto = load("res://source/match/units/" + name + ".tscn")
		m.call("_setup_and_spawn_unit", proto.instantiate(), Transform3D(Basis.IDENTITY, Vector3(60.0, 0.0, z)), p, false)
		z += 8.0
	for _f in range(10):
		await get_tree().physics_frame
	print("[VIS] 名称            根缩放  网格世界尺寸(max x/z)  网格数")
	for u in p.get_children():
		var t := str(u.get("unit_type_id"))
		if t == "<null>":
			continue
		var vis := _visual_extent(u)
		print("[VIS] %-15s %-7s %-22s %d" % [t, str(u.scale.x), str(snappedf(vis.x, 0.01)) + " x " + str(snappedf(vis.z, 0.01)), int(vis.y)])
	get_tree().quit(0)


## 渲染网格的世界外接尺寸（只取真实几何，排除选中圈/血条/瞄准圈等装饰）。
func _visual_extent(unit) -> Vector3:
	var best := Vector3.ZERO
	var count := 0
	for gi in unit.find_children("*", "GeometryInstance3D", true, false):
		var path := str(gi.get_path())
		if path.contains("Selection") or path.contains("Highlight") or path.contains("Targetability") \
				or path.contains("HealthBar") or path.contains("RallyPoint") or path.contains("AirToTerrainMarker"):
			continue
		var aabb: AABB
		if gi is MeshInstance3D and (gi as MeshInstance3D).mesh != null:
			aabb = (gi as MeshInstance3D).mesh.get_aabb()
		elif gi is GeometryInstance3D:
			aabb = (gi as GeometryInstance3D).get_aabb()
		else:
			continue
		var ws: Vector3 = (gi as Node3D).global_transform.basis.get_scale()
		var size: Vector3 = Vector3(aabb.size.x * absf(ws.x), aabb.size.y * absf(ws.y), aabb.size.z * absf(ws.z))
		best = Vector3(maxf(best.x, size.x), maxf(best.y, size.y), maxf(best.z, size.z))
		count += 1
	return Vector3(best.x, float(count), best.z)
