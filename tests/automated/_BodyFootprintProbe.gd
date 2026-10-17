extends Node

## 本体足迹探针（2026-09-30）：RTS 的碰撞体跟**本体**走，不跟整包 AABB 走。
## 对地炮的炮管、飞机的机翼、建筑的天线都不该算进 footprint。
## 口径：把模型网格按"底部离地高度"分层，取**贴地下半部**（底 <= 总高×0.5）的网格并集
## ⇒ 得到"本体足迹"（长 X × 宽 Z × 高 Y）与整包 AABB 对照。

const MAP_SCENE := "res://source/match/maps/PlainAndSimple.tscn"
const ROSTER := ["CommandCenter", "VehicleFactory", "Barracks", "AircraftFactory", "OreRefinery",
	"AntiGroundTurret", "AntiAirTurret", "MachineGunTurret", "Tank", "HeavyTank", "APC",
	"TransportTruck", "Worker", "Scout", "Helicopter", "Drone"]


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
	var spawned := []
	var z := 60.0
	for name in ROSTER:
		var inst = load("res://source/match/units/" + name + ".tscn").instantiate()
		m.call("_setup_and_spawn_unit", inst, Transform3D(Basis.IDENTITY, Vector3(70.0, 0.0, z)), p, false)
		spawned.append(inst)
		z += 10.0
	for _f in range(40):
		await get_tree().physics_frame
	print("[BODY] 单位|全包X|全包Y|全包Z|本体X|本体Y|本体Z|本体窄边/2|建议半径(窄/2*1.05)")
	for u in spawned:
		if not is_instance_valid(u):
			continue
		var full := _union(u, 1.01)
		var body := _union(u, 0.5)
		var narrow: float = minf(body.size.x, body.size.z)
		print("[BODY] %s|%.2f|%.2f|%.2f|%.2f|%.2f|%.2f|%.2f|%.2f" % [
			str(u.get("unit_type_id")), full.size.x, full.size.y, full.size.z,
			body.size.x, body.size.y, body.size.z, narrow / 2.0, narrow / 2.0 * 1.05])
	get_tree().quit(0)


## 取"底部低于 total_height × ratio"的网格并集（单位本地空间）。
func _union(unit: Node3D, ratio: float) -> AABB:
	var to_local: Transform3D = unit.global_transform.affine_inverse()
	var meshes := []
	var total_top := 0.0
	for gi in unit.find_children("*", "GeometryInstance3D", true, false):
		var path := str(gi.get_path())
		if path.contains("Selection") or path.contains("Highlight") or path.contains("Targetability") \
				or path.contains("HealthBar") or path.contains("RallyPoint"):
			continue
		var aabb: AABB = (gi as GeometryInstance3D).get_aabb()
		if gi is MeshInstance3D and (gi as MeshInstance3D).mesh != null and aabb.size.length() < 0.01:
			aabb = (gi as MeshInstance3D).mesh.get_aabb()
		if aabb.size.length() < 0.001:
			continue
		var xf: Transform3D = to_local * (gi as Node3D).global_transform
		var box := AABB()
		for i in range(8):
			var pt: Vector3 = xf * aabb.get_endpoint(i)
			box = box.expand(pt) if i > 0 else AABB(pt, Vector3.ZERO)
		meshes.append(box)
		total_top = maxf(total_top, box.position.y + box.size.y)
	var limit := total_top * ratio
	var result := AABB()
	var first := true
	for box in meshes:
		if box.position.y > limit:
			continue
		for i in range(8):
			var pt: Vector3 = box.get_endpoint(i)
			if first:
				result = AABB(pt, Vector3.ZERO); first = false
			else:
				result = result.expand(pt)
	return result
