extends Node

## 临时探针（2026-09-27）：测量坦克/步兵等单位的视觉包围盒（世界米），
## 以及 G4 地图台地/山地的真实视觉高度。窗口化运行，打印后退出。

const UNITS := {
	"Tank": "res://source/match/units/Tank.tscn",
	"HeavyTank": "res://source/match/units/HeavyTank.tscn",
	"Infantry": "res://source/match/units/Infantry.tscn",
	"Sniper": "res://source/match/units/Sniper.tscn",
	"Rocketeer": "res://source/match/units/Rocketeer.tscn",
	"APC": "res://source/match/units/APC.tscn",
	"TransportTruck": "res://source/match/units/TransportTruck.tscn",
	"Scout": "res://source/match/units/Scout.tscn",
	"Worker": "res://source/match/units/Worker.tscn",
	"Drone": "res://source/match/units/Drone.tscn",
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
		add_child(unit)
		await get_tree().create_timer(0.6).timeout
		var aabb := _visual_aabb(unit)
		print("[SIZE] %s  长x宽x高 = %.2f x %.2f x %.2f m" % [
			unit_name, aabb.size.x, aabb.size.z, aabb.size.y])
		unit.free()
	get_tree().quit(0)


func _is_ui(node_name: String) -> bool:
	for keyword in ["Highlight", "Selection", "HealthBar", "Targetability", "UI", "Anchor", "Marker"]:
		if keyword in node_name:
			return true
	return false


func _visual_aabb(root: Node3D) -> AABB:
	var result := AABB()
	var first := true
	var stack: Array = [root]
	while not stack.is_empty():
		var node = stack.pop_back()
		for child in node.get_children():
			stack.push_back(child)
		if node is SpriteBase3D and not _is_ui(node.name):
			# 告板类模型本体（如步兵告板）计入；血条/选中圈等 UI 告板排除。
			var world_aabb: AABB = node.global_transform * AABB(
				Vector3(-0.5, -0.5, -0.05), Vector3(1.0, 1.0, 0.1))
			if first:
				result = world_aabb
				first = false
			else:
				result = result.merge(world_aabb)
		if node is MeshInstance3D and node.mesh != null and not _is_ui(node.name):
			var world_aabb: AABB = node.global_transform * node.mesh.get_aabb()
			if first:
				result = world_aabb
				first = false
			else:
				result = result.merge(world_aabb)
	return result
