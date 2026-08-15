extends Node

const MatchScene = preload("res://tests/manual/TestCombatPolicies.tscn")

var _failures := 0


func _ready():
	var match_instance = MatchScene.instantiate()
	add_child(match_instance)
	var tank = match_instance.get_node("Players/Human/Tank")
	var enemy = match_instance.get_node("Players/PolicyTestEnemy/TargetCommandCenter")
	var expected_tank_position: Vector3 = tank.global_position
	var expected_enemy_position: Vector3 = enemy.global_position
	for _frame_index in range(4):
		await get_tree().process_frame
	_check(
		tank.global_position.distance_to(expected_tank_position) < 0.01,
		"可移动单位不应被无效导航查询吸附到原点"
	)
	_check(
		enemy.global_position.distance_to(expected_enemy_position) < 0.01,
		"建筑不应被无效导航查询吸附到原点"
	)
	_check(tank.global_position.distance_to(enemy.global_position) > 1.0, "双方单位应保持场景间距")
	print("Runtime placement smoke test completed: %d failure(s)" % _failures)
	match_instance.queue_free()
	await get_tree().process_frame
	SmokeTestExit.request(get_tree(), 0 if _failures == 0 else 1)


func _check(condition: bool, message: String):
	if condition:
		return
	_failures += 1
	push_error("Runtime placement assertion failed: %s" % message)
