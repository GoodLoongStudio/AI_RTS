extends Node

## 运行时碰撞体核对：直接读**真正的**运行时对象 —— 碰撞形状（类型 + 水平半宽）、
## 逻辑半径（Movement/MovementObstacle）、carve 顶点世界外缘。
## 用于回答"可视化里那个 13m 的盒子到底是碰撞体还是 carve 洞"。

const MAP_SCENE := "res://source/match/maps/PlainAndSimple.tscn"
const ROSTER := ["CommandCenter", "OreRefinery", "Barracks", "AntiGroundTurret", "Tank", "HeavyTank",
	"Worker", "Infantry", "Helicopter", "Drone"]


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
	print("[RT] 单位|形状|水平半宽|逻辑r|carve外缘")
	for u in spawned:
		if not is_instance_valid(u):
			continue
		var cs := u.find_child("CollisionShape3D", true, false) as CollisionShape3D
		var shape_name := "无"
		var half := -1.0
		if cs != null and cs.shape != null:
			var s := cs.shape
			var sc: Vector3 = cs.global_transform.basis.get_scale()
			if s is CylinderShape3D:
				shape_name = "Cylinder"; half = (s as CylinderShape3D).radius * sc.x
			elif s is BoxShape3D:
				shape_name = "Box"; half = (s as BoxShape3D).size.x * 0.5 * sc.x
			elif s is CapsuleShape3D:
				shape_name = "Capsule"; half = (s as CapsuleShape3D).radius * sc.x
		var logic: Variant = u.get("radius")
		var carve := 0.0
		var ob: Node = u.find_child("MovementObstacle", true, false)
		if ob != null:
			var verts: PackedVector3Array = ob.get("vertices")
			for v in verts:
				carve = maxf(carve, Vector2(v.x, v.z).length())
		print("[RT] %s|%s|%.2f|%s|%.2f" % [
			str(u.get("unit_type_id")), shape_name, half,
			("null" if logic == null else "%.2f" % float(logic)), carve])
	get_tree().quit(0)
