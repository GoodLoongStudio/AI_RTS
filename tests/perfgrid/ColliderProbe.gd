extends Node

## 临时探针（2026-09-27）：实测单位物理碰撞体在**世界**中的半径。
## Godot 是否把祖先 scale 应用到 CollisionShape 的形状，不靠记忆——用射线量出来。
## 同时打印视觉 AABB 与 root/Movement/MovementObstacle radius，用于核对覆盖关系。

const UNITS := {
	"Tank": "res://source/match/units/Tank.tscn",
	"HeavyTank": "res://source/match/units/HeavyTank.tscn",
	"Infantry": "res://source/match/units/Infantry.tscn",
	"Worker": "res://source/match/units/Worker.tscn",
	"APC": "res://source/match/units/APC.tscn",
	"Helicopter": "res://source/match/units/Helicopter.tscn",
	"CommandCenter": "res://source/match/units/CommandCenter.tscn",
	"Barracks": "res://source/match/units/Barracks.tscn",
	"VehicleFactory": "res://source/match/units/VehicleFactory.tscn",
	"AircraftFactory": "res://source/match/units/AircraftFactory.tscn",
	"OreRefinery": "res://source/match/units/OreRefinery.tscn",
	"AntiGroundTurret": "res://source/match/units/AntiGroundTurret.tscn",
	"AntiAirTurret": "res://source/match/units/AntiAirTurret.tscn",
	"MachineGunTurret": "res://source/match/units/MachineGunTurret.tscn",
}


func _ready():
	await get_tree().process_frame
	for unit_name in UNITS:
		var unit: Node3D = (load(UNITS[unit_name]) as PackedScene).instantiate()
		unit.position = Vector3(200.0, 0.0, 200.0)
		add_child(unit)
		await get_tree().process_frame
		var root_radius = unit.get("radius")
		var movement = unit.find_child("Movement", false, false)
		var obstacle = unit.find_child("MovementObstacle", false, false)
		var mv_radius = movement.get("radius") if movement != null else null
		var ob_radius = obstacle.get("radius") if obstacle != null else null
		# 视觉 AABB（排除 UI 告板圈）
		var aabb := AABB()
		var first := true
		var stack: Array = [unit]
		while not stack.is_empty():
			var node = stack.pop_back()
			for child in node.get_children():
				stack.push_back(child)
			if node is MeshInstance3D and node.mesh != null and not _is_ui(node.name):
				var world_aabb: AABB = node.global_transform * node.mesh.get_aabb()
				aabb = world_aabb if first else aabb.merge(world_aabb)
				first = false
		# 实测碰撞体：从外向内打射线（mask=2 命中单位层），取命中点到中心的距离。
		# 不能从中心往外打：intersect_ray 默认 hit_from_inside=false，起点在形状内会直接无命中。
		var space := unit.get_world_3d().direct_space_state
		var hit_x := 0.0
		var from := unit.global_position + Vector3(15.0, 0.3, 0.0)
		var to := unit.global_position + Vector3(0.0, 0.3, 0.0)
		var q := PhysicsRayQueryParameters3D.create(from, to)
		q.collision_mask = 2
		q.collide_with_areas = true
		var hit := space.intersect_ray(q)
		if hit.is_empty():
			hit_x = -1.0
		else:
			var position: Vector3 = hit["position"]
			hit_x = absf(position.x - unit.global_position.x)
		print("[COLL] %-16s root_r=%s move_r=%s obst_r=%s | 视觉=%.2fx%.2f | 射线~%.1fm" % [
			unit_name,
			str(root_radius), str(mv_radius), str(ob_radius),
			aabb.size.x, aabb.size.z, hit_x])
		unit.queue_free()
		await get_tree().process_frame
	get_tree().quit(0)


func _is_ui(node_name: String) -> bool:
	for keyword in ["Highlight", "Selection", "HealthBar", "Targetability", "Anchor", "Marker"]:
		if keyword in node_name:
			return true
	return false
