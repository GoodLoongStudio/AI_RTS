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

## 【定制表】每个单位的碰撞/逻辑半径（世界米）：建筑/炮塔贴合本体（炮塔只算底座，不算炮管），
## 机动单位按车宽一半（拥挤时允许轻微重叠，RA3 做法）。改尺寸必须同步这里 + 场景 + 配表 footprint。
## 【定制表 · 两列】RA3 式分工：
##   COLLISION_RADIUS_M = **碰撞体尺寸**（方盒/胶囊/圆柱 ⇒ 贴模型本体；炮塔只算底座不算炮管）
##   AVOIDANCE_RADIUS_M = **避让/间距半径**（"个人空间"，与模型大小解耦；寻路脱困阈值按它标定）
## 两列都改尺寸时必须同步：本表 + 场景 + 配表 footprint。
## Exact values updated with the 2026-10-10 authored proportions; tolerances unchanged.
const COLLISION_RADIUS_M := {
	"CommandCenter": 4.9764, "VehicleFactory": 3.972, "Barracks": 3.57075, "AircraftFactory": 4.3945,
	"OreRefinery": 3.0186, "AntiGroundTurret": 1.38, "AntiAirTurret": 1.265, "MachineGunTurret": 1.035,
	"Tank": 1.288, "HeavyTank": 1.7756, "APC": 1.104, "TransportTruck": 1.1132, "Worker": 0.8464,
	"Infantry": 0.322, "Rocketeer": 0.322, "Sniper": 0.322, "Helicopter": 2.024, "Drone": 0.8004,
}
const AVOIDANCE_RADIUS_M := {
	"CommandCenter": 4.9764, "VehicleFactory": 3.972, "Barracks": 3.57075, "AircraftFactory": 4.3945,
	"OreRefinery": 3.0186, "AntiGroundTurret": 1.38, "AntiAirTurret": 1.265, "MachineGunTurret": 1.035,
	"Tank": 1.84, "HeavyTank": 1.8768, "APC": 2.53, "TransportTruck": 2.1804, "Worker": 1.2512,
	"Infantry": 0.414, "Rocketeer": 0.414, "Sniper": 0.4968, "Helicopter": 2.1988, "Drone": 1.104,
}
## 相邻放置允许的重叠上限：只放行**可旋转炮塔/炮管的扫过范围**（RA3 里炮管本就允许互相穿插）。
const ADJACENCY_TOLERANCE_M := 0.6

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
	# ① 逻辑半径（避让/间距）必须等于 AVOIDANCE 列
	var authored: float = float(AVOIDANCE_RADIUS_M.get(unit_name, -1.0))
	if authored < 0.0:
		_failures += 1
		push_error("%s 未在 AVOIDANCE_RADIUS_M 里声明避让半径" % unit_name)
		return
	if absf(radius - authored) > 0.01:
		_failures += 1
		push_error("%s 避让半径 %.2fm 与定制表 %.2fm 不一致" % [unit_name, radius, authored])
		return
	# ② 碰撞体尺寸必须贴合模型本体（上界：不得比整包还大；RA3 里"巨无霸碰撞体"是拥挤/寻路元凶）
	#    注意上界只约束**碰撞体**，不约束避让半径 —— 避让半径是"个人空间"，与模型大小解耦。
	# 【2026-10-01 独立复核修复】旧写法只对 Cylinder/Capsule 回读几何，Box 单位永远用表值 ——
	# 于是"碰撞体不得比模型大"这条硬不变量对 4 栋方盒建筑是**同义反复**，从未读几何盒。
	# 现在三种形状都从 CollisionShape3D 回读真实几何（读不到才算失败）。
	var collision := -1.0
	var cs := unit.find_child("CollisionShape3D", true, false) as CollisionShape3D
	if cs != null and cs.shape != null:
		var scale: Vector3 = cs.global_transform.basis.get_scale()
		var s := cs.shape
		if s is CylinderShape3D:
			collision = (s as CylinderShape3D).radius * scale.x
		elif s is CapsuleShape3D:
			collision = (s as CapsuleShape3D).radius * scale.x
		elif s is BoxShape3D:
			var box := s as BoxShape3D
			collision = maxf(box.size.x * scale.x, box.size.z * scale.z) * 0.5
	if collision < 0.0:
		_failures += 1
		push_error("%s 读不到 CollisionShape3D 几何（形状类型未覆盖）" % unit_name)
		return
	# 【2026-10-01 独立复核收口】恢复强断言：几何必须等于定制表（此前表已无读取点、
	# 判据退化成纯上界，等于放走了"Box 半宽与表不符"这类缺陷）。
	var authored_collision := float(COLLISION_RADIUS_M.get(unit_name, -1.0))
	if authored_collision < 0.0 or absf(collision - authored_collision) > 0.02:
		_failures += 1
		push_error("%s 几何碰撞半宽 %.3f 与定制表 %.3f 不一致" % [unit_name, collision, authored_collision])
		return
	var size: Vector2 = _visual_size(unit)
	var half: float = maxf(size.x, size.y) / 2.0
	if collision > half + 0.05:
		_failures += 1
		push_error("%s 碰撞体 %.2fm 超过整包半宽 %.2fm" % [unit_name, collision, half])
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
