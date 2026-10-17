extends Node

## 旋转不变足迹探针：把每个几何网格的 **世界** AABB 并集（含炮塔旋转后的扫过范围），
## 这才是"相邻放置不穿模"该用的尺寸；逻辑半径仍可用更小的车宽值（避让紧、不拥挤）。

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
	var player: Node = m.get_node("Players").get_children()[0]
	var spawned := []
	var z := 60.0
	for name in ROSTER:
		var inst = load("res://source/match/units/" + name + ".tscn").instantiate()
		m.call("_setup_and_spawn_unit", inst, Transform3D(Basis.IDENTITY, Vector3(70.0, 0.0, z)), player, false)
		spawned.append(inst)
		z += 12.0
	for _f in range(60):
		await get_tree().physics_frame
	print("[RIAABB] 单位|X|Y|Z")
	for u in spawned:
		if not is_instance_valid(u):
			continue
		var box := AABB()
		var first := true
		for gi in u.find_children("*", "GeometryInstance3D", true, false):
			var path := str(gi.get_path())
			if path.contains("Selection") or path.contains("Highlight") or path.contains("Targetability") \
					or path.contains("HealthBar") or path.contains("RallyPoint"):
				continue
			var w: AABB = (gi as GeometryInstance3D).get_aabb()
			if gi is MeshInstance3D and (gi as MeshInstance3D).mesh != null and w.size.length() < 0.01:
				w = (gi as MeshInstance3D).mesh.get_aabb()
			if w.size.length() < 0.001:
				continue
			var xf: Transform3D = (gi as Node3D).global_transform
			for i in range(8):
				var pt: Vector3 = xf * w.get_endpoint(i)
				if first:
					box = AABB(pt, Vector3.ZERO); first = false
				else:
					box = box.expand(pt)
		print("[RIAABB] %s|%.2f|%.2f|%.2f" % [str(u.get("unit_type_id")), box.size.x, box.size.y, box.size.z])
	get_tree().quit(0)
