extends Node

## 定向探针（2026-09-30 第 3 轮）：绕墙场景为什么停在"目标正侧方 6.78m"？
## 复刻 MovementRecoverySmokeTest 场景 1，跑满预算后 dump：
##   订单状态 / 单位位置 / 目标点 / 目标点的**最近导航点**与其距离 / 当前导航路径全部航点 /
##   is_navigation_finished / 当前 action / 地图边界。

const SmokeTestWarmup = preload("res://tests/automated/SmokeTestWarmup.gd")
const MatchScene = preload("res://tests/manual/TestOneUnit.tscn")
const CommandCenterScene = preload("res://source/match/units/CommandCenter.tscn")

const BUDGET_FRAMES := 2400


func _ready():
	var m: Node = MatchScene.instantiate()
	add_child(m)
	await SmokeTestWarmup.wait_for_units(get_tree(), 1)
	var human: Node = m.get_node("Players/Human")
	var gateway: Node = human.get_node("UnitCommandGateway")
	var tank: Node3D = human.get_node("Tank")
	var movement: Node = tank.find_child("Movement")
	await SmokeTestWarmup.wait_for_navigation(get_tree(), movement, tank.global_position)

	var nav_band := 2.8
	var region = m.get_node_or_null("Navigation/Terrain/NavigationRegion3D")
	if region == null:
		for sub in m.find_children("*", "NavigationRegion3D", true, false):
			region = sub
			break
	if region != null and region.get("navigation_mesh") != null:
		nav_band = float(region.get("navigation_mesh").get("agent_radius"))
	var block_r := 7.0
	var standoff: float = block_r + nav_band + float(tank.call("body_radius")) + 1.0
	var start: Vector3 = tank.global_position
	var wall_x: float = start.x + standoff
	print("[WD] agent_radius=%.2f standoff=%.2f start=%s wall_x=%.2f" % [nav_band, standoff, str(start), wall_x])
	for index in range(3):
		var block: Node3D = CommandCenterScene.instantiate()
		m.call("_setup_and_spawn_unit", block,
			Transform3D(Basis.IDENTITY, Vector3(wall_x, 0.0, start.z - block_r + float(index) * block_r * 2.0)),
			human, false)
	for _f in range(45):
		await get_tree().physics_frame
	for block in human.get_children():
		if block is Node3D and block != tank and block.has_method("body_radius"):
			print("[WD] 砖 %s pos=%s r=%.2f" % [block.name, str(block.global_position), float(block.call("body_radius"))])

	var target := Vector3(wall_x + standoff, 0.0, start.z)
	var nav_map: RID = movement.call("get_navigation_map")
	var closest: Vector3 = NavigationServer3D.map_get_closest_point(nav_map, target)
	var target_offset := Vector2(closest.x - target.x, closest.z - target.z).length()
	print("[WD] 目标=%s  最近导航点=%s  偏差=%.2f（>0.35 说明目标本身不在导航面上）" % [
		str(target), str(closest), target_offset])

	var result: Dictionary = gateway.MoveUnits([tank], target, human)
	var order_id := String(result.get("unit_results", [{}])[0].get("order_id", ""))
	print("[WD] order_id=", order_id)
	for i in range(BUDGET_FRAMES):
		await get_tree().physics_frame
		if i % 600 == 599:
			var state: String = gateway.GetOrderState(order_id)
			var path: PackedVector3Array = movement.call("get_current_navigation_path")
			print("[WD] t=%.0fs state=%s pos=%s 距目标=%.2f 航点数=%d is_finished=%s action=%s" % [
				float(i + 1) / 60.0, state, str(tank.global_position.snapped(Vector3(0.01, 0.01, 0.01))),
				Vector2(tank.global_position.x - target.x, tank.global_position.z - target.z).length(),
				path.size(), str(movement.call("is_navigation_finished")),
				str(tank.get("action").get_script().resource_path.get_file()) if tank.get("action") != null and tank.get("action").get_script() != null else "<null>"])
			if state in ["Arrived", "Unreachable", "Cancelled", "TargetLost", "UnitLost"]:
				break

	var state_final: String = gateway.GetOrderState(order_id)
	var path_final: PackedVector3Array = movement.call("get_current_navigation_path") if movement.has_method("get_current_navigation_path") else PackedVector3Array()
	print("[WD] 最终 state=%s pos=%s 距目标=%.2f" % [
		state_final, str(tank.global_position.snapped(Vector3(0.01, 0.01, 0.01))),
		Vector2(tank.global_position.x - target.x, tank.global_position.z - target.z).length()])
	print("[WD] 路径航点(%d):" % path_final.size())
	for p in path_final:
		print("[WD]    ", str(p.snapped(Vector3(0.01, 0.01, 0.01))))
	var mp = movement.get("target_position")
	print("[WD] Movement.target_position=%s" % str(mp))
	var closest_unit: Vector3 = NavigationServer3D.map_get_closest_point(nav_map, tank.global_position)
	print("[WD] 单位位置到导航面偏差=%.3f" % Vector2(closest_unit.x - tank.global_position.x, closest_unit.z - tank.global_position.z).length())
	get_tree().quit(0)
