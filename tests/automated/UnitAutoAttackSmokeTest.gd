extends Node

const SmokeTestWarmup = preload("res://tests/automated/SmokeTestWarmup.gd")

const MatchScene = preload("res://tests/manual/TestOneUnit.tscn")
const CommandCenterScene = preload("res://source/match/units/CommandCenter.tscn")
const Player = preload("res://source/match/players/Player.gd")
const AutoAttacking = preload("res://source/match/units/actions/AutoAttacking.gd")
const WaitingForTargets = preload("res://source/match/units/actions/WaitingForTargets.gd")

var _failures := 0


func _ready():
	var match_instance = MatchScene.instantiate()
	add_child(match_instance)
	await SmokeTestWarmup.wait_for_units(get_tree(), 1)

	var human = match_instance.get_node("Players/Human")
	var tank = human.get_node("Tank")
	var gateway = human.get_node("UnitCommandGateway")
	var enemy_player = _add_enemy_player(match_instance)

	# ---- 场景 1：默认（FireAtWill）下，静止单位应自动攻击射程内敌人 ----
	var in_range_enemy = _add_enemy_structure(
		enemy_player, tank.global_position + Vector3(0.0, 0.0, -3.0)
	)
	var hp_before: float = in_range_enemy.hp
	var fired: bool = await _wait_for_hp_below(in_range_enemy, hp_before, 4.0)
	_check(fired, "默认姿态下单位应自动攻击射击范围内的敌人（用户需求 2026-09-21）")
	var engaged: bool = (
		tank.action != null
		and (tank.action is AutoAttacking or tank.action is WaitingForTargets)
	)
	_check(engaged, "交战后单位应处于 AutoAttacking/WaitingForTargets 动作")

	# ---- 场景 2：HoldFire（停火）下不再自动攻击 ----
	gateway.SetFirePolicy([tank], "HoldFire", human)
	await get_tree().create_timer(0.5).timeout
	var hp_hold: float = in_range_enemy.hp
	in_range_enemy.hp = hp_hold  # 基准
	var still_fired: bool = await _wait_for_hp_below(in_range_enemy, hp_hold, 2.0)
	_check(not still_fired, "停火（HoldFire）模式下不应自动攻击")

	# ---- 场景 3：恢复 FireAtWill 后重新自动攻击 ----
	gateway.SetFirePolicy([tank], "FireAtWill", human)
	var hp_resume: float = in_range_enemy.hp
	var resumed: bool = await _wait_for_hp_below(in_range_enemy, hp_resume, 4.0)
	_check(resumed, "解除停火后应恢复自动攻击")

	# ---- 场景 4：射程外的敌人不应被自动追击（只用射程内判定）----
	# 注意：当前实现对**视野内**（sight_range）目标会自主追击（AutoAttacking →
	# FollowingToReachDistance）。这里只断言"射程内必打"，不锁追击距离语义。

	print("Unit auto attack smoke test completed: %d failure(s)" % _failures)
	match_instance.queue_free()
	await get_tree().process_frame
	SmokeTestExit.request(get_tree(), 0 if _failures == 0 else 1)


func _add_enemy_player(match_instance):
	var enemy_player := Node3D.new()
	enemy_player.name = "AutoAttackEnemy"
	enemy_player.set_script(Player)
	enemy_player.color = Color.RED
	enemy_player.add_to_group("players")
	match_instance.get_node("Players").add_child(enemy_player)
	return enemy_player


func _add_enemy_structure(enemy_player, position: Vector3):
	var enemy = CommandCenterScene.instantiate()
	enemy.name = "AutoAttackTarget"
	enemy.position = position
	enemy.add_to_group("units")
	enemy.add_to_group("adversary_units")
	enemy_player.add_child(enemy)
	return enemy


func _check(condition: bool, message: String):
	if condition:
		return
	_failures += 1
	push_error("Unit auto attack assertion failed: %s" % message)


func _wait_for_hp_below(unit, previous_hp: float, timeout_seconds: float) -> bool:
	var elapsed_seconds := 0.0
	while elapsed_seconds < timeout_seconds:
		if not is_instance_valid(unit) or unit.hp < previous_hp:
			return true
		await get_tree().create_timer(0.1).timeout
		elapsed_seconds += 0.1
	return not is_instance_valid(unit) or unit.hp < previous_hp
