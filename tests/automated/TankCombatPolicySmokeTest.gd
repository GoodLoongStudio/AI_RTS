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

	var human = match_instance.get_node("Players/Human")
	var tank = human.get_node("Tank")
	var gateway = human.get_node("UnitCommandGateway")
	var enemy_player := Node3D.new()
	enemy_player.name = "PolicyTestEnemy"
	enemy_player.set_script(Player)
	enemy_player.color = Color.RED
	enemy_player.add_to_group("players")
	match_instance.get_node("Players").add_child(enemy_player)
	var enemy_tank = TankScene.instantiate()
	enemy_tank.name = "EnemyTank"
	enemy_tank.position = tank.position + Vector3(3.0, 0.0, 0.0)
	enemy_tank.add_to_group("units")
	enemy_tank.add_to_group("adversary_units")
	enemy_tank.add_to_group("revealed_units")
	enemy_player.add_child(enemy_tank)

	gateway.SetFirePolicy([tank], "HoldFire", human)
	gateway.SetFirePolicy([enemy_tank], "HoldFire", enemy_player)
	await get_tree().create_timer(0.5).timeout
	var enemy_hp_before: float = enemy_tank.hp
	_check(enemy_tank.hp == enemy_hp_before, "HoldFire 下 Tank 不应自主开火")

	gateway.SetFirePolicy([tank], "FireAtWill", human)
	var autonomous_hit: bool = await _wait_for_hp_below(enemy_tank, enemy_hp_before, 3.0)
	_check(autonomous_hit, "恢复自由开火后 Tank 应攻击射程内敌人")

	gateway.SetFirePolicy([tank], "HoldFire", human)
	var position_when_hold_fire_set: Vector3 = tank.global_position
	await get_tree().create_timer(0.3).timeout
	_check(
		tank.global_position.distance_to(position_when_hold_fire_set) < 0.2,
		"战斗中切换停火后应立即停止自主追击"
	)
	# 已经发射的炮弹仍应命中；等待其结算后再验证停火不会产生新攻击。
	await get_tree().create_timer(1.1).timeout
	var hp_after_in_flight_attack: float = enemy_tank.hp
	await get_tree().create_timer(0.8).timeout
	_check(enemy_tank.hp == hp_after_in_flight_attack, "战斗中切换停火后不应继续产生新的伤害")
	# 留出比射程边界更大的余量，避免 NavigationAgent 初始对齐/RVO 位移让目标偶然进入射程。
	enemy_tank.global_position = tank.global_position + Vector3(7.5, 0.0, 0.0)
	var tank_position_before: Vector3 = tank.global_position
	enemy_hp_before = enemy_tank.hp
	gateway.SetEngagementStance([tank], "HoldGround", human)
	gateway.SetFirePolicy([tank], "FireAtWill", human)
	await get_tree().create_timer(0.6).timeout
	_check(enemy_tank.hp == enemy_hp_before, "固守 Tank 不应攻击武器射程外目标")
	_check(tank.global_position.distance_to(tank_position_before) < 0.2, "固守 Tank 不应主动追击")

	gateway.SetEngagementStance([tank], "Aggressive", human)
	await get_tree().create_timer(1.0).timeout
	_check(
		enemy_tank.hp < enemy_hp_before or tank.global_position.distance_to(tank_position_before) > 0.2,
		"侵略 Tank 应追击或攻击视野内敌人"
	)

	print("Tank combat policy smoke test completed: %d failure(s)" % _failures)
	match_instance.queue_free()
	await get_tree().process_frame
	get_tree().quit(0 if _failures == 0 else 1)


func _check(condition: bool, message: String):
	if condition:
		return
	_failures += 1
	push_error("Tank combat policy assertion failed: %s" % message)


## 在超时时间内等待投射物完成视觉命中，避免把飞行时间误判为未开火。
func _wait_for_hp_below(unit, previous_hp: float, timeout_seconds: float) -> bool:
	var elapsed_seconds := 0.0
	while elapsed_seconds < timeout_seconds:
		if not is_instance_valid(unit) or unit.hp < previous_hp:
			return true
		await get_tree().create_timer(0.1).timeout
		elapsed_seconds += 0.1
	return not is_instance_valid(unit) or unit.hp < previous_hp
