extends Node

const TankScene = preload("res://source/match/units/Tank.tscn")
const TurretScene = preload("res://source/match/units/AntiGroundTurret.tscn")
const FactoryScene = preload("res://source/match/units/VehicleFactory.tscn")


func _ground_half_along(node: Node3D, towards: Vector3) -> float:
	var origin: Vector3 = node.global_position
	var dir := Vector2(towards.x - origin.x, towards.z - origin.z)
	if dir.length() < 0.0001:
		dir = Vector2.RIGHT
	dir = dir.normalized()
	var out := 0.0
	for gi in node.find_children("*", "GeometryInstance3D", true, false):
		var path := str(gi.get_path())
		if path.contains("Selection") or path.contains("Highlight") or path.contains("Targetability") \
				or path.contains("HealthBar") or path.contains("RallyPoint"):
			continue
		var local: AABB = (gi as GeometryInstance3D).get_aabb()
		if gi is MeshInstance3D and (gi as MeshInstance3D).mesh != null and local.size.length() < 0.01:
			local = (gi as MeshInstance3D).mesh.get_aabb()
		if local.size.length() < 0.001:
			continue
		var xf: Transform3D = (gi as Node3D).global_transform
		for i in range(8):
			var pt: Vector3 = xf * local.get_endpoint(i)
			if pt.y - origin.y > 0.6:
				continue
			out = maxf(out, Vector2(pt.x - origin.x, pt.z - origin.z).dot(dir))
	return maxf(out, 0.0)


## 与 GDScript 侧同一几何、但取"所有方向的最大半程"（有向投影的保守上界）。
func _ground_half_max(node: Node3D) -> float:
	var origin: Vector3 = node.global_position
	var out := 0.0
	for gi in node.find_children("*", "GeometryInstance3D", true, false):
		var path := str(gi.get_path())
		if path.contains("Selection") or path.contains("Highlight") or path.contains("Targetability") \
				or path.contains("HealthBar") or path.contains("RallyPoint"):
			continue
		var local: AABB = (gi as GeometryInstance3D).get_aabb()
		if gi is MeshInstance3D and (gi as MeshInstance3D).mesh != null and local.size.length() < 0.01:
			local = (gi as MeshInstance3D).mesh.get_aabb()
		if local.size.length() < 0.001:
			continue
		var xf: Transform3D = (gi as Node3D).global_transform
		for i in range(8):
			var pt: Vector3 = xf * local.get_endpoint(i)
			if pt.y - origin.y > 0.6:
				continue
			out = maxf(out, Vector2(pt.x - origin.x, pt.z - origin.z).length())
	return out


func _collision_half_max(node: Node3D) -> float:
	var out := 0.0
	for cs in node.find_children("*", "CollisionShape3D", true, false):
		var shape: CollisionShape3D = cs
		if shape.shape == null:
			continue
		var local: AABB = shape.shape.get_marginless_aabb()
		var xf: Transform3D = shape.global_transform
		var origin: Vector3 = node.global_position
		for i in range(8):
			var pt: Vector3 = xf * local.get_endpoint(i)
			if pt.y - origin.y > 0.6:
				continue
			out = maxf(out, Vector2(pt.x - origin.x, pt.z - origin.z).length())
	return out


func _movement_radius(node: Node) -> float:
	var movement = node.get_node_or_null("Movement")
	if movement == null:
		return -1.0
	return float(movement.get("radius"))


func _report(label: String, scene: PackedScene, others: Array) -> void:
	var node: Node3D = scene.instantiate()
	add_child(node)
	print("PROBE %s movement_radius=%.3f collision_half_max=%.3f hull_half_max=%.3f" % [
		label, _movement_radius(node), _collision_half_max(node), _ground_half_max(node)
	])
	for other in others:
		var o: Node3D = other
		print("PROBE   %s hull_half_along(towards %s)=%.3f  pair_required=%.3f" % [
			label, o.name, _ground_half_along(node, o.global_position),
			_ground_half_along(node, o.global_position) + _ground_half_along(o, node.global_position)
		])
	return


func _ready():
	var tank: Node3D = TankScene.instantiate()
	tank.global_position = Vector3(0, 0, 0)
	add_child(tank)
	var turret: Node3D = TurretScene.instantiate()
	turret.global_position = Vector3(10, 0, 0)
	add_child(turret)
	var factory: Node3D = FactoryScene.instantiate()
	factory.global_position = Vector3(0, 0, 10)
	add_child(factory)
	await get_tree().process_frame
	await get_tree().process_frame
	_report("tank", TankScene, [turret, factory])
	_report("turret", TurretScene, [tank])
	_report("factory", FactoryScene, [tank])
	print("PROBE done")
	get_tree().quit(0)
