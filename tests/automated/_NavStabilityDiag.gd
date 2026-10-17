extends Node

## 定向探针（2026-09-30 第 3 轮）：Arrived 之后 action 何时清？
## 复刻 NavigationStabilitySmokeTest 的第一个断言（空地短距离移动）。

const SmokeTestWarmup = preload("res://tests/automated/SmokeTestWarmup.gd")
const MatchScene = preload("res://tests/manual/TestHelicopterCommands.tscn")


func _ready():
	var m: Node = MatchScene.instantiate()
	add_child(m)
	await SmokeTestWarmup.wait_for_units(get_tree(), 3)
	var human: Node = m.get_node("Players/Human")
	var tank: Node3D = human.get_node("Tank")
	var gateway: Node = human.get_node("UnitCommandGateway")
	gateway.SetFirePolicy([tank], "HoldFire", human)
	await get_tree().physics_frame
	await get_tree().physics_frame

	var destination: Vector3 = tank.global_position + Vector3(2.0, 0.0, 0.0)
	var result: Dictionary = gateway.MoveUnits([tank], destination, human)
	var order_id := String(result.get("unit_results", [{}])[0].get("order_id", ""))
	print("[NS] 起点=%s 目标=%s" % [str(tank.global_position.snapped(Vector3(0.01, 0.01, 0.01))), str(destination)])
	var state := ""
	var flip_frame := -1
	for i in range(600):
		await get_tree().physics_frame
		state = gateway.GetOrderState(order_id)
		if state in ["Arrived", "Unreachable", "Cancelled", "UnitLost"]:
			flip_frame = i
			break
	print("[NS] 状态在 +%d 帧变为 %s" % [flip_frame, state])
	for j in range(15):
		await get_tree().physics_frame
		var action = tank.get("action")
		var name := "<null>"
		if action != null and action.get_script() != null:
			name = str(action.get_script().resource_path.get_file())
		print("[NS] Arrived 后 +%d 帧: action=%s 距目标=%.3f 帧号=%d" % [
			j + 1, name,
			Vector2(tank.global_position.x - destination.x, tank.global_position.z - destination.z).length(),
			Engine.get_physics_frames()])
	get_tree().quit(0)
