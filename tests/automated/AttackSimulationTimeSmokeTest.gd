extends Node

const MatchScene = preload("res://tests/manual/TestOneUnit.tscn")
const TankScene = preload("res://source/match/units/Tank.tscn")
const Player = preload("res://source/match/players/Player.gd")

var _failures := 0


func _ready():
	var match_instance = MatchScene.instantiate()
	add_child(match_instance)
	await get_tree().process_frame
	await get_tree().process_frame
	await get_tree().physics_frame
	await get_tree().physics_frame

	var clock_before: int = match_instance.get_simulation_msec()
	_check(clock_before >= 0, "对局应提供战局模拟时钟")
	get_tree().paused = true
	await get_tree().create_timer(0.4, true, true).timeout
	_check(
		match_instance.get_simulation_msec() == clock_before,
		"暂停期间战局模拟时间不得继续增加"
	)
	_check(match_instance.is_simulation_paused(), "paused 时 is_simulation_paused 应为真")
	get_tree().paused = false
	await get_tree().physics_frame
	await get_tree().physics_frame
	_check(
		match_instance.get_simulation_msec() > clock_before,
		"恢复后战局模拟时间应继续推进"
	)
	_check(not match_instance.is_simulation_paused(), "恢复后 is_simulation_paused 应为假")

	var units_before := {}
	for unit in get_tree().get_nodes_in_group("units"):
		if match_instance.is_ancestor_of(unit) and unit is Node3D:
			units_before[unit] = (unit as Node3D).global_position
	get_tree().paused = true
	await get_tree().create_timer(0.35, true, true).timeout
	for unit in units_before:
		if not is_instance_valid(unit):
			continue
		_check(
			(unit as Node3D).global_position.is_equal_approx(units_before[unit]),
			"暂停期间单位位置不得继续推进"
		)
	get_tree().paused = false

	var human = match_instance.get_node("Players/Human")
	var attacker = human.get_node("Tank")
	var gateway = human.get_node("UnitCommandGateway")
	var enemy_player = Player.new()
	enemy_player.name = "AttackTimeEnemy"
	enemy_player.color = Color.RED
	enemy_player.add_to_group("players")
	match_instance.get_node("Players").add_child(enemy_player)
	var enemy = TankScene.instantiate()
	enemy.name = "AttackTimeTarget"
	enemy.position = attacker.position + Vector3(3, 0, 0)
	enemy.add_to_group("units")
	enemy.add_to_group("revealed_units")
	enemy_player.add_child(enemy)
	enemy.hp = 200
	gateway.SetFirePolicy([enemy], "HoldFire", enemy_player)
	gateway.SetFirePolicy([attacker], "FireAtWill", human)
	gateway.AttackUnits([attacker], enemy, human)
	await get_tree().create_timer(0.2).timeout
	_check(attacker.has_meta("next_attack_availability_time"), "开火后应记录下一次攻击可用的模拟时间")
	var available_at: int = attacker.get_meta("next_attack_availability_time")
	var remaining_before: int = available_at - match_instance.get_simulation_msec()
	_check(remaining_before > 0, "攻击间隔剩余时间应记在模拟时钟上")
	get_tree().paused = true
	await get_tree().create_timer(0.5, true, true).timeout
	var remaining_during_pause: int = available_at - match_instance.get_simulation_msec()
	_check(
		absi(remaining_during_pause - remaining_before) <= 20,
		"暂停不得消耗攻击间隔剩余时间"
	)
	get_tree().paused = false

	print("Attack simulation time smoke test completed: %d failure(s)" % _failures)
	match_instance.queue_free()
	await get_tree().process_frame
	SmokeTestExit.request(get_tree(), 0 if _failures == 0 else 1)


func _check(condition: bool, message: String):
	if condition:
		return
	_failures += 1
	push_error("Attack simulation time assertion failed: %s" % message)
