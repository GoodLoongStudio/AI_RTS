extends Node

const SmokeTestWarmup = preload("res://tests/automated/SmokeTestWarmup.gd")

const MatchScene = preload("res://tests/manual/TestMultiUnitCommands.tscn")
const CommandCenterScene = preload("res://source/match/units/CommandCenter.tscn")
const Player = preload("res://source/match/players/Player.gd")
const GroundAttackMoving = preload(
	"res://source/match/units/actions/GroundAttackMoving.gd"
)

var _failures := 0


func _ready():
	var match_instance = MatchScene.instantiate()
	add_child(match_instance)
	await SmokeTestWarmup.wait_for_units(get_tree(), 4)

	var human = match_instance.get_node("Players/Human")
	var tank = human.get_node("Tank")
	var gateway = human.get_node("UnitCommandGateway")
	var enemy_player = _add_enemy_player(match_instance)

	# 敌人在起点与终点之间（偏离 3m）：攻击移动应"途中交战 → 敌人消失 → 继续推进 → 抵达结束"。
	var start: Vector3 = tank.global_position
	var destination: Vector3 = start + Vector3(0.0, 0.0, -10.0)
	var enemy = _add_enemy_structure(
		enemy_player, start + Vector3(3.0, 0.0, -5.0)
	)
	var result = gateway.GroundAttackMoveUnits([tank], destination, human)
	_check(result["status"] == "Accepted", "地面移动并攻击应被接受")
	_check(
		tank.action != null and tank.action.get_script() == GroundAttackMoving,
		"Tank 应进入 GroundAttackMoving"
	)

	# ① 途中交战：敌人应掉血。
	var hp_before: float = enemy.hp
	var engaged: bool = await _wait_for_hp_below(enemy, hp_before, 5.0)
	_check(engaged, "攻击移动途中应交战射程内敌人")

	# ② 敌人消失后应恢复推进并抵达终点，订单结束（回到待机索敌）。
	enemy.hp = 0
	var arrived: bool = await _wait_for_arrival(tank, destination, 10.0)
	_check(arrived, "途中敌人清除后应抵达攻击移动终点（恢复推进竞态回归）")
	await get_tree().create_timer(0.6).timeout
	_check(
		tank.action == null or tank.action.get_script() != GroundAttackMoving,
		"抵达终点后攻击移动订单应结束（回到待机/自动攻击）"
	)

	# ③ 抵达后恢复默认自动攻击：再放一个射程内敌人应被打。
	var second = _add_enemy_structure(
		enemy_player, tank.global_position + Vector3(0.0, 0.0, -2.5)
	)
	var hp_second: float = second.hp
	var auto_fired: bool = await _wait_for_hp_below(second, hp_second, 4.0)
	_check(auto_fired, "订单结束后单位应恢复默认自动攻击（射程内敌人）")

	print("Ground attack move arrival smoke test completed: %d failure(s)" % _failures)
	match_instance.queue_free()
	await get_tree().process_frame
	SmokeTestExit.request(get_tree(), 0 if _failures == 0 else 1)


func _add_enemy_player(match_instance):
	var enemy_player := Node3D.new()
	enemy_player.name = "ArrivalEnemy"
	enemy_player.set_script(Player)
	enemy_player.color = Color.RED
	enemy_player.add_to_group("players")
	match_instance.get_node("Players").add_child(enemy_player)
	return enemy_player


func _add_enemy_structure(enemy_player, position: Vector3):
	var enemy = CommandCenterScene.instantiate()
	enemy.name = "ArrivalTarget"
	enemy.position = position
	enemy.add_to_group("units")
	enemy.add_to_group("adversary_units")
	enemy_player.add_child(enemy)
	return enemy


func _check(condition: bool, message: String):
	if condition:
		return
	_failures += 1
	push_error("Ground attack move arrival assertion failed: %s" % message)


func _wait_for_hp_below(unit, previous_hp: float, timeout_seconds: float) -> bool:
	var elapsed_seconds := 0.0
	while elapsed_seconds < timeout_seconds:
		if not is_instance_valid(unit) or unit.hp < previous_hp:
			return true
		await get_tree().create_timer(0.1).timeout
		elapsed_seconds += 0.1
	return not is_instance_valid(unit) or unit.hp < previous_hp


func _wait_for_arrival(unit, destination: Vector3, timeout_seconds: float) -> bool:
	var elapsed_seconds := 0.0
	while elapsed_seconds < timeout_seconds:
		if not is_instance_valid(unit):
			return false
		if unit.global_position.distance_to(destination) < 1.2:
			return true
		await get_tree().create_timer(0.1).timeout
		elapsed_seconds += 0.1
	return (
		is_instance_valid(unit)
		and unit.global_position.distance_to(destination) < 1.2
	)
