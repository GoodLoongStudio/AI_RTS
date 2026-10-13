extends Node

## 单位/建筑碰撞半径覆盖视觉尺寸的回归测试（2026-09-27）。
## 背景：2026-09-27 单位/建筑整体放大（载具×2/人形×1.35/建筑×3）时，场景里的
## 硬编码 `radius` 没跟着放大——避让半径（NavigationAgent3D）、建筑禁行半径
## （MovementObstacle，逻辑图上 set_structure_blocker 的禁行圈）、放置重叠判定
## （C# Overlaps 读根 radius）全部停留在旧尺寸 → 单位互相穿模、单位/敌人卡进建筑
## 内部（"边缘穿模"）。本测试把"物理半径必须覆盖视觉外接 AABB"固化为断言。

const UNIT_SCENES := {
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

## 允许的视觉外扩余量（米）：半径<视觉半宽时最坏视觉重叠量；只允许贴边 0.05m 级误差。
const COVERAGE_TOLERANCE_M := 0.05
## 相邻判据：两对象放在"半径和"的最小间距上，视觉包围盒投影不得互相侵入。
const ADJACENCY_TOLERANCE_M := 0.06
const ADJACENCY_PAIRS := [
	["res://source/match/units/Tank.tscn", "res://source/match/units/Tank.tscn"],
	["res://source/match/units/HeavyTank.tscn", "res://source/match/units/Tank.tscn"],
	["res://source/match/units/Infantry.tscn", "res://source/match/units/Infantry.tscn"],
	["res://source/match/units/CommandCenter.tscn", "res://source/match/units/CommandCenter.tscn"],
	["res://source/match/units/Barracks.tscn", "res://source/match/units/VehicleFactory.tscn"],
	["res://source/match/units/Tank.tscn", "res://source/match/units/CommandCenter.tscn"],
]

var _failures := 0


func _ready():
	await get_tree().process_frame
	for unit_name in UNIT_SCENES:
		var unit: Node3D = (load(UNIT_SCENES[unit_name]) as PackedScene).instantiate()
		add_child(unit)
		await get_tree().process_frame
		_check_unit(unit_name, unit)
		unit.queue_free()
		await get_tree().process_frame
	await _check_adjacency()
	print("Unit radius coverage smoke test completed: %d failure(s)" % _failures)
	SmokeTestExit.request(get_tree(), 0 if _failures == 0 else 1)


func _check_unit(unit_name: String, unit: Node3D) -> void:
	var radius_value = unit.get("radius")
	if radius_value == null:
		_failures += 1
		push_error("%s 缺少 root radius" % unit_name)
		return
	var radius := float(radius_value)
	if radius <= 0.0:
		_failures += 1
		push_error("%s root radius 非法: %.3f" % [unit_name, radius])
		return
	var size: Vector2 = _visual_size(unit)
	var half := maxf(size.x, size.y) / 2.0
	if radius < half - COVERAGE_TOLERANCE_M:
		_failures += 1
		push_error("%s 半径 %.2fm 小于视觉半宽 %.2fm（视觉 %.2fx%.2fm）→ 会边缘穿模" % [
			unit_name, radius, half, size.x, size.y])
		return
	# 避让/禁行半径与根半径必须同源：不同步会让"以为占了 2m 实际占了 4m"。
	for child in [unit.find_child("Movement", false, false),
			unit.find_child("MovementObstacle", false, false)]:
		if child == null:
			continue
		var child_radius = child.get("radius")
		if child_radius == null:
			continue
		if absf(float(child_radius) - radius) > 0.001:
			_failures += 1
			push_error("%s 的 %s.radius=%.2f 与 root radius=%.2f 不一致" % [
				unit_name, child.name, float(child_radius), radius])
		break


func _visual_size(root: Node3D):
	var result := AABB()
	var first := true
	var stack: Array = [root]
	while not stack.is_empty():
		var node = stack.pop_back()
		for child in node.get_children():
			stack.push_back(child)
		if not (node is MeshInstance3D):
			continue
		if _is_ui_gizmo(node.name):
			continue
		var mesh: Mesh = node.mesh
		if mesh == null:
			continue
		var world_aabb: AABB = node.global_transform * mesh.get_aabb()
		if first:
			result = world_aabb
			first = false
		else:
			result = result.merge(world_aabb)
	if first:
		return Vector2.ZERO
	return Vector2(float(result.size.x), float(result.size.z))


## 血条/选中圈/目标圈等 UI 告板不算模型本体。
func _is_ui_gizmo(node_name: String) -> bool:
	for keyword in ["Highlight", "Selection", "HealthBar", "Targetability", "Anchor", "Marker"]:
		if keyword in node_name:
			return true
	return false


## 相邻不穿模：按"半径和"的最小间距摆放两个对象，视觉 AABB 投影不得互相侵入。
## 这是 2026-09-27"边缘穿模"用户反馈的直接判据（原先 radius 未随 scale 放大 →
## 2×半径之和远小于视觉尺寸之和，相邻摆放必穿模）。
func _check_adjacency() -> void:
	for pair in ADJACENCY_PAIRS:
		var a: Node3D = (load(pair[0]) as PackedScene).instantiate()
		var b: Node3D = (load(pair[1]) as PackedScene).instantiate()
		a.position = Vector3(120, 0, 120)
		add_child(a)
		await get_tree().process_frame
		var radius_a: float = maxf(float(a.get("radius")), COVERAGE_TOLERANCE_M)
		b.position = a.position + Vector3(radius_a + maxf(float(b.get("radius")), COVERAGE_TOLERANCE_M), 0, 0)
		b.position.y = 0.0
		add_child(b)
		await get_tree().process_frame
		a.position.y = 0.0
		await get_tree().process_frame
		var box_a: AABB = _model_aabb(a)
		var box_b: AABB = _model_aabb(b)
		var gap := box_b.position.x - (box_a.position.x + box_a.size.x)
		var names := "%s + %s" % [pair[0].get_file(), pair[1].get_file()]
		if gap < -ADJACENCY_TOLERANCE_M:
			_failures += 1
			push_error("%s 相邻放置时视觉投影重叠 %.3fm（半径 %.2f+%.2f）→ 边缘穿模" % [
				names, gap, float(a.get("radius")), float(b.get("radius"))])
		else:
			print("[PASS] %s 相邻不穿模（间隙 %.3fm）" % [names, gap])
		a.queue_free()
		b.queue_free()
		await get_tree().process_frame


func _model_aabb(root: Node3D) -> AABB:
	var result := AABB()
	var first := true
	var stack: Array = [root]
	while not stack.is_empty():
		var node = stack.pop_back()
		for child in node.get_children():
			stack.push_back(child)
		if node is MeshInstance3D and node.mesh != null and not _is_ui_gizmo(node.name):
			var world_aabb: AABB = node.global_transform * node.mesh.get_aabb()
			result = world_aabb if first else result.merge(world_aabb)
			first = false
	return result
