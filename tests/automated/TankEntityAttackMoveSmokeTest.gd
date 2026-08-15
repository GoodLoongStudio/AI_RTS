extends Node

const MatchScene = preload("res://tests/manual/TestOneUnit.tscn")
const CommandCenterScene = preload("res://source/match/units/CommandCenter.tscn")
const Player = preload("res://source/match/players/Player.gd")
const AttackMoving = preload("res://source/match/units/actions/GroundAttackMoving.gd")

var _failures := 0


func _ready():
	var match_instance = MatchScene.instantiate()
	add_child(match_instance)
	await get_tree().process_frame
	await get_tree().process_frame

	var human = match_instance.get_node("Players/Human")
	var tank = human.get_node("Tank")
	var gateway = human.get_node("UnitCommandGateway")
	var enemy_player = _add_enemy_player(match_instance)
	var final_target = _add_enemy_structure(
		enemy_player, tank.global_position + Vector3(0.0, 0.0, -6.0)
	)

	# 停火不拒绝实体移动攻击：单位仍应追踪移动目标，但不能开火。
	gateway.SetFirePolicy([tank], "HoldFire", human)
	var target_hp: float = final_target.hp
	var start_position: Vector3 = tank.global_position
	var result = gateway.EntityAttackMoveUnits([tank], final_target, human)
	_check(result["status"] == "Accepted", "停火实体移动并攻击应作为推进命令被接收")
	_check(
		tank.action != null and tank.action.get_script() == AttackMoving,
		"Tank 应进入共享 AttackMove 执行 Action"
	)
	await get_tree().create_timer(0.35).timeout
	final_target.global_position += Vector3(2.0, 0.0, -1.0)
	await get_tree().create_timer(0.45).timeout
	_check(tank.global_position.distance_to(start_position) > 0.05, "Tank 应朝实体最终目标推进")
	_check(final_target.hp == target_hp, "停火期间不应攻击实体最终目标")

	# 恢复开火后应攻击最终目标；目标退出运行时后订单必须进入 TargetLost。
	final_target.global_position = tank.global_position + Vector3(0.0, 0.0, -2.0)
	gateway.SetFirePolicy([tank], "FireAtWill", human)
	var final_target_hit: bool = await _wait_for_hp_below(final_target, target_hp, 3.0)
	_check(final_target_hit, "恢复开火后应攻击实体最终目标")
	var order_id: String = result["unit_results"][0]["order_id"]
	final_target.hp = 0
	await get_tree().process_frame
	await get_tree().process_frame
	_check(gateway.GetOrderState(order_id) == "TargetLost", "最终目标死亡后订单应为 TargetLost")

	print("Tank entity attack move smoke test completed: %d failure(s)" % _failures)
	match_instance.queue_free()
	await get_tree().process_frame
	SmokeTestExit.request(get_tree(), 0 if _failures == 0 else 1)


func _add_enemy_player(match_instance):
	var enemy_player := Node3D.new()
	enemy_player.name = "EntityAttackMoveEnemy"
	enemy_player.set_script(Player)
	enemy_player.color = Color.RED
	enemy_player.add_to_group("players")
	match_instance.get_node("Players").add_child(enemy_player)
	return enemy_player


func _add_enemy_structure(enemy_player, position: Vector3):
	var enemy = CommandCenterScene.instantiate()
	enemy.name = "FinalTarget"
	enemy.position = position
	enemy.add_to_group("units")
	enemy.add_to_group("adversary_units")
	enemy_player.add_child(enemy)
	return enemy


func _check(condition: bool, message: String):
	if condition:
		return
	_failures += 1
	push_error("Tank entity attack move assertion failed: %s" % message)


## 等待实体目标被飞行中的投射物命中。
func _wait_for_hp_below(unit, previous_hp: float, timeout_seconds: float) -> bool:
	var elapsed_seconds := 0.0
	while elapsed_seconds < timeout_seconds:
		if not is_instance_valid(unit) or unit.hp < previous_hp:
			return true
		await get_tree().create_timer(0.1).timeout
		elapsed_seconds += 0.1
	return not is_instance_valid(unit) or unit.hp < previous_hp
