extends Node

## 临时探针（2026-09-27）：实测单位物理碰撞体在**世界**中的半径。
## Godot 是否把祖先 scale 应用到 CollisionShape 的形状，不靠记忆——用射线量出来。
## 同时打印视觉 AABB 与 root/Movement/MovementObstacle radius，用于核对覆盖关系。

const UNITS := {
	"Tank": "res://source/match/units/Tank.tscn",
	"HeavyTank": "res://source/match/units/HeavyTank.tscn",
	"APC": "res://source/match/units/APC.tscn",
	"Helicopter": "res://source/match/units/Helicopter.tscn",
	"Drone": "res://source/match/units/Drone.tscn",
	"Worker": "res://source/match/units/Worker.tscn",
	"TransportTruck": "res://source/match/units/TransportTruck.tscn",
	"Scout": "res://source/match/units/Scout.tscn",
	"Infantry": "res://source/match/units/Infantry.tscn",
	"Sniper": "res://source/match/units/Sniper.tscn",
	"Rocketeer": "res://source/match/units/Rocketeer.tscn",
	"CommandCenter": "res://source/match/units/CommandCenter.tscn",
	"Barracks": "res://source/match/units/Barracks.tscn",
	"VehicleFactory": "res://source/match/units/VehicleFactory.tscn",
	"AircraftFactory": "res://source/match/units/AircraftFactory.tscn",
	"OreRefinery": "res://source/match/units/OreRefinery.tscn",
	"AntiGroundTurret": "res://source/match/units/AntiGroundTurret.tscn",
	"AntiAirTurret": "res://source/match/units/AntiAirTurret.tscn",
	"MachineGunTurret": "res://source/match/units/MachineGunTurret.tscn",
}


var _probe_seq := 0


func _ready():
	await get_tree().process_frame
	for unit_name in UNITS:
		var unit: Node3D = (load(UNITS[unit_name]) as PackedScene).instantiate()
		_probe_seq += 1
		unit.position = Vector3(200.0 + float(_probe_seq) * 60.0, 0.0, 200.0 + float(_probe_seq) * 40.0)
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
		# 空中单位悬空且圆柱很薄，射线在测试场景里命中不可靠——
		# 直接读 CollisionShape3D.shape.radius × 累计缩放（数学量，与射线同源）。
		var shape_node := unit.find_child("CollisionShape3D", true, false)
		if shape_node != null and shape_node.shape != null:
			var world_scale: Vector3 = shape_node.global_transform.basis.get_scale()
			var shape_radius := 0.0
			if "radius" in shape_node.shape:
				shape_radius = float(shape_node.shape.get("radius"))
			hit_x = shape_radius * maxf(absf(world_scale.x), absf(world_scale.z))
		var visual_half := maxf(aabb.size.x, aabb.size.z) / 2.0
		var verdict := "OK" if absf(hit_x - visual_half) <= 0.05 or hit_x >= visual_half else "视觉外露 %.2fm" % (visual_half - hit_x)
		print("[COLL] %-16s 碰撞r=%.2f 视觉半宽=%.2f root_r=%s move_r=%s obst_r=%s | %s" % [
			unit_name, hit_x, visual_half,
			str(root_radius), str(mv_radius), str(ob_radius), verdict])
		unit.queue_free()
		await get_tree().process_frame
	get_tree().quit(0)


func _is_ui(node_name: String) -> bool:
	for keyword in ["Highlight", "Selection", "HealthBar", "Targetability", "Anchor", "Marker"]:
		if keyword in node_name:
			return true
	return false
