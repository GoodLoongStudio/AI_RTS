extends Node

## 蓝图尺寸探针（2026-09-30 第 5 轮，用户报"蓝图显示尺寸 ≠ 实际建造尺寸 ≠ 碰撞尺寸"）。
## 对五栋建筑分别测：
##   ① 建筑场景（真实建造用）经 _setup_and_spawn_unit 出场后的**视觉世界外缘**
##   ② 蓝图场景（structure-geometries/*，玩家拖拽时看到的 ghost）单独实例化后的视觉世界外缘
##   ③ 逻辑/碰撞世界半径（MovementObstacle.radius / CollisionShape3D 世界值）
## 目标：把"三者不一致"量化成比值。

const ITEMS := {
	"CommandCenter": ["res://source/match/units/CommandCenter.tscn", "res://source/match/units/structure-geometries/CommandCenter.tscn"],
	"VehicleFactory": ["res://source/match/units/VehicleFactory.tscn", "res://source/match/units/structure-geometries/VehicleFactory.tscn"],
	"Barracks": ["res://source/match/units/Barracks.tscn", "res://source/match/units/structure-geometries/Barracks.tscn"],
	"OreRefinery": ["res://source/match/units/OreRefinery.tscn", "res://source/match/units/structure-geometries/OreRefinery.tscn"],
	"AntiGroundTurret": ["res://source/match/units/AntiGroundTurret.tscn", "res://source/match/units/structure-geometries/AntiGroundTurret.tscn"],
}
const MAP_SCENE := "res://source/match/maps/PlainAndSimple.tscn"


func _ready():
	var settings = load("res://source/data-model/MatchSettings.gd").new()
	var human_settings = load("res://source/data-model/PlayerSettings.gd").new()
	human_settings.controller = Constants.PlayerType.HUMAN
	human_settings.color = Constants.Player.COLORS[0]
	settings.players.append(human_settings)
	settings.visible_player = 0
	var m: Node = load("res://source/match/Match.tscn").instantiate()
	m.settings = settings
	m.map = load(MAP_SCENE).instantiate()
	add_child(m)
	get_tree().current_scene = m
	for _f in range(240):
		await get_tree().physics_frame
	var human: Node = m.get_node("Players").get_children()[0]

	print("[BP] %-18s %10s %10s %10s %8s %8s" % ["建筑", "真实视觉", "蓝图视觉", "碰撞半径", "蓝图/真实", "碰撞/真实"])
	for key in ITEMS:
		var real_scene: PackedScene = load(ITEMS[key][0])
		var bp_scene: PackedScene = load(ITEMS[key][1])
		if real_scene == null or bp_scene == null:
			print("[BP] %-18s 场景缺失" % key)
			continue
		# 真实建筑
		var real: Node3D = real_scene.instantiate()
		var real_scale: float = real.scale.x
		m.call("_setup_and_spawn_unit", real, Transform3D(Basis.IDENTITY, Vector3(150.0, 0.0, 150.0)), human, false)
		await get_tree().physics_frame
		await get_tree().process_frame
		var real_ext := _visual_extent(real, Vector2(real.global_position.x, real.global_position.z))
		var collision := _collision_extent(real, Vector2(real.global_position.x, real.global_position.z))
		var logical := 0.0
		var ob = real.find_child("MovementObstacle", true, false)
		if ob != null:
			logical = float(ob.get("radius"))
		# 蓝图场景单独实例化（与 StructurePlacementHandler 同路径：不经过 _setup_and_spawn_unit）
		var ghost: Node3D = bp_scene.instantiate()
		add_child(ghost)
		ghost.global_position = Vector3(60.0, 0.0, 150.0)
		await get_tree().physics_frame
		var ghost_ext := _visual_extent(ghost, Vector2(ghost.global_position.x, ghost.global_position.z))
		print("[BP] %-18s %10.2f %10.2f %10.2f %8.2f %8.2f   真实root scale=%.2f 蓝图root scale=%.2f" % [
			key, real_ext, ghost_ext, collision,
			(ghost_ext / real_ext) if real_ext > 0.0 else 0.0,
			(collision / real_ext) if real_ext > 0.0 else 0.0,
			real_scale, ghost.scale.x])
		ghost.queue_free()
		real.queue_free()
		await get_tree().process_frame
	get_tree().quit(0)


func _visual_extent(node: Node3D, center: Vector2) -> float:
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
		for corner in [p, p + Vector3(s.x, 0, 0), p + Vector3(0, 0, s.z), p + Vector3(s.x, 0, s.z)]:
			var w: Vector3 = gi.global_transform * corner
			out = maxf(out, maxf(absf(w.x - center.x), absf(w.z - center.y)))
	return out


func _collision_extent(node: Node3D, center: Vector2) -> float:
	var out := 0.0
	for sub in node.find_children("*", "CollisionShape3D", true, false):
		var cs: CollisionShape3D = sub
		if cs.shape == null or not (cs.shape is CylinderShape3D):
			continue
		var c: CylinderShape3D = cs.shape
		var r: float = c.radius * cs.global_transform.basis.get_scale().x
		out = maxf(out, r)
	return out
