extends Node

## 归一化 A/B：同一进程里对比"迁移后场景"与"迁移前（git HEAD）场景"的世界值。
## 用 set_script(null) 避免单位脚本在裸环境下报错，只测几何/物理/导航输入。
## 旋转不变：视觉用"去旋转的世界足迹"（每个网格本地 AABB × 该网格世界缩放，取分量最大）。

const NAMES := [
	"CommandCenter", "VehicleFactory", "Barracks", "AircraftFactory", "OreRefinery",
	"AntiGroundTurret", "AntiAirTurret", "MachineGunTurret",
	"Tank", "HeavyTank", "APC", "TransportTruck", "Worker", "Drone", "Scout", "Infantry",
	"Helicopter", "Rocketeer", "Sniper",
]


func _ready():
	var holder := Node3D.new()
	add_child(holder)
	for name in NAMES:
		var cur: Variant = _measure("res://source/match/units/%s.tscn" % name, holder)
		var pre_path := "res://tests/automated/_premigration/%s.tscn" % name
		var pre: Variant = _measure(pre_path, holder) if ResourceLoader.exists(pre_path) else null
		if pre == null:
			print("[AB] %-17s 无迁移前副本，跳过" % name)
			continue
		var ok := (
			_near(cur["visual"], pre["visual"]) and _near(cur["collision"], pre["collision"])
			and _near(cur["carve"], pre["carve"]) and is_equal_approx(cur["logical"], pre["logical"])
		)
		print("[AB] %-17s %s  视觉 %s→%s | 碰撞 %s→%s | carve %s→%s | 逻辑 %.3f→%.3f" % [
			name, ("一致" if ok else "**不一致**"),
			_vec(pre["visual"]), _vec(cur["visual"]),
			_vec(pre["collision"]), _vec(cur["collision"]),
			_vec(pre["carve"]), _vec(cur["carve"]),
			pre["logical"], cur["logical"]])
	await get_tree().process_frame
	get_tree().quit(0)


func _measure(path: String, holder: Node3D) -> Variant:
	if not ResourceLoader.exists(path):
		return null
	var node: Node3D = load(path).instantiate()
	node.set_script(null)
	holder.add_child(node)
	node.position = Vector3.ZERO
	node.rotation = Vector3.ZERO
	var visual := Vector3.ZERO
	# 计划要求：排除血条、选择圈和特效，只测实体模型（Visual 分支）。
	const EXCLUDE := ["Highlight", "Selection", "Targetability", "HealthBar", "RallyPoint"]
	for sub in node.find_children("*", "GeometryInstance3D", true, false):
		var gi: GeometryInstance3D = sub
		var excluded := false
		for part in EXCLUDE:
			if gi.is_ancestor_of(node) == false and str(gi.get_path()).contains(part):
				excluded = true
		if excluded:
			continue
		var aabb: AABB = gi.get_aabb()
		if aabb.size.length_squared() <= 0.0 and gi is MeshInstance3D and (gi as MeshInstance3D).mesh != null:
			aabb = (gi as MeshInstance3D).mesh.get_aabb()
		var s: Vector3 = gi.global_transform.basis.get_scale()
		visual = Vector3(
			maxf(visual.x, aabb.size.x * s.x),
			maxf(visual.y, aabb.size.y * s.y),
			maxf(visual.z, aabb.size.z * s.z))
	var collision := Vector3.ZERO
	for sub in node.find_children("*", "CollisionShape3D", true, false):
		var cs: CollisionShape3D = sub
		if not (cs.shape is CylinderShape3D):
			continue
		var cyl: CylinderShape3D = cs.shape
		var s2: Vector3 = cs.global_transform.basis.get_scale()
		collision = Vector3(
			maxf(collision.x, cyl.radius * 2.0 * s2.x),
			maxf(collision.y, cyl.height * s2.y),
			maxf(collision.z, cyl.radius * 2.0 * s2.z))
	var carve := Vector3.ZERO
	var logical := 0.0
	var mov := node.get_node_or_null("Movement")
	if mov != null and mov.get("radius") != null:
		logical = float(mov.get("radius"))
	var obs := node.get_node_or_null("MovementObstacle")
	if obs != null:
		if obs.get("radius") != null:
			logical = maxf(logical, float(obs.get("radius")))
		var verts: PackedVector3Array = obs.get("vertices")
		var ws: float = (obs as Node3D).global_transform.basis.get_scale().x
		for v in verts:
			var r: float = Vector2(v.x, v.z).length() * ws
			carve = Vector3(maxf(carve.x, r * 2.0), 0.0, maxf(carve.z, r * 2.0))
	node.queue_free()
	return {"visual": visual, "collision": collision, "carve": carve, "logical": logical}


func _near(a: Vector3, b: Vector3) -> bool:
	return a.distance_to(b) < 0.02


func _vec(v: Vector3) -> String:
	return "(%.2f,%.2f,%.2f)" % [v.x, v.y, v.z]
