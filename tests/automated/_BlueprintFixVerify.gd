extends Node

## 蓝图尺寸最终判定（同口径：只量**几何子树**，排除选择环/血条等表现节点）。
## 真实建筑：取 DetachTransform/Geometry（或 Geometry）子树；蓝图：ghost 自身子树。

const ITEMS := {
	"CommandCenter": "res://source/match/units/CommandCenter.tscn",
	"VehicleFactory": "res://source/match/units/VehicleFactory.tscn",
	"Barracks": "res://source/match/units/Barracks.tscn",
	"OreRefinery": "res://source/match/units/OreRefinery.tscn",
	"AntiGroundTurret": "res://source/match/units/AntiGroundTurret.tscn",
}
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
	for _f in range(240):
		await get_tree().physics_frame
	var human: Node = m.get_node("Players").get_children()[0]
	var handler: Node = human.get_node("StructurePlacementHandler")
	print("[BF3] %-17s %9s %9s %9s %8s  %s" % ["建筑", "真实几何", "蓝图(修前)", "蓝图(修后)", "碰撞", "修后/真实"])
	for key in ITEMS:
		var prototype: PackedScene = load(ITEMS[key])
		var real: Node3D = prototype.instantiate()
		m.call("_setup_and_spawn_unit", real, Transform3D(Basis.IDENTITY, Vector3(150.0, 0.0, 150.0)), human, false)
		await get_tree().physics_frame
		await get_tree().process_frame
		var geo: Node3D = real.get_node_or_null("DetachTransform/Geometry")
		if geo == null:
			geo = real.get_node_or_null("Geometry")
		var real_r := _radius(geo, real.global_position) if geo != null else -1.0
		var collision := _collision(real)
		real.queue_free()
		await get_tree().process_frame
		handler.call("_cancel_structure_placement")
		handler.call("_start_structure_placement", prototype)
		await get_tree().physics_frame
		await get_tree().process_frame
		var ghost: Node3D = handler.get("_active_blueprint_node")
		if ghost == null or real_r <= 0.0:
			print("[BF3] %-17s 缺数据（geo=%s ghost=%s）" % [key, str(geo != null), str(ghost != null)])
			handler.call("_cancel_structure_placement")
			continue
		var fixed_r := _radius(ghost, ghost.global_position)
		var saved := ghost.scale
		ghost.scale = Vector3.ONE
		await get_tree().physics_frame
		var raw_r := _radius(ghost, ghost.global_position)
		ghost.scale = saved
		print("[BF3] %-17s %9.2f %9.2f %9.2f %8.2f  %.2f（修前 %.2f）" % [
			key, real_r, raw_r, fixed_r, collision, fixed_r / real_r, raw_r / real_r])
		handler.call("_cancel_structure_placement")
		await get_tree().process_frame
	get_tree().quit(0)


func _radius(node: Node3D, center: Vector3) -> float:
	var out := 0.0
	for sub in node.find_children("*", "GeometryInstance3D", true, false):
		var gi: GeometryInstance3D = sub
		var aabb: AABB = gi.get_aabb()
		if aabb.size.length_squared() <= 0.0 and gi is MeshInstance3D:
			var mesh: Mesh = (gi as MeshInstance3D).mesh
			if mesh != null:
				aabb = mesh.get_aabb()
		var p := aabb.position
		var s := aabb.size
		for corner in [
			p, p + Vector3(s.x, 0, 0), p + Vector3(0, 0, s.z), p + Vector3(s.x, 0, s.z),
			p + Vector3(0, s.y, 0), p + Vector3(s.x, s.y, 0),
			p + Vector3(0, s.y, s.z), p + Vector3(s.x, s.y, s.z)]:
			var w: Vector3 = gi.global_transform * corner
			out = maxf(out, Vector2(w.x - center.x, w.z - center.z).length())
	return out


func _collision(node: Node3D) -> float:
	var out := 0.0
	for sub in node.find_children("*", "CollisionShape3D", true, false):
		var cs: CollisionShape3D = sub
		if cs.shape is CylinderShape3D:
			out = maxf(out, (cs.shape as CylinderShape3D).radius * cs.global_transform.basis.get_scale().x)
	return out
