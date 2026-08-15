extends Node

const MatchScene = preload("res://tests/manual/TestOneUnit.tscn")
const CommandCenterScene = preload("res://source/match/units/CommandCenter.tscn")
const Player = preload("res://source/match/players/Player.gd")
const GroundAttackMoving = preload(
	"res://source/match/units/actions/GroundAttackMoving.gd"
)

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
	var enemy = _add_enemy_structure(
		enemy_player, tank.global_position + Vector3(0.0, 0.0, -3.0)
	)
	var destination: Vector3 = tank.global_position + Vector3(0.0, 0.0, -8.0)

	# HoldFire 下 AttackMove 应退化为普通推进。
	gateway.SetFirePolicy([tank], "HoldFire", human)
	var hold_fire_start: Vector3 = tank.global_position
	var hold_fire_hp: float = enemy.hp
	var result = gateway.GroundAttackMoveUnits([tank], destination, human)
	_check(result["status"] == "Accepted", "地面移动并攻击应被接受")
	_check(
		tank.action != null and tank.action.get_script() == GroundAttackMoving,
		"Tank 应进入 GroundAttackMoving"
	)
	var hold_fire_advanced := await _wait_for_distance_from(tank, hold_fire_start, 0.05, 2.0)
	_check(hold_fire_advanced, "停火时应继续推进")
	_check(enemy.hp == hold_fire_hp, "停火时不应攻击途中敌人")

	# 固守只攻击射程内目标，命中后继续原推进目标。
	gateway.SetEngagementStance([tank], "HoldGround", human)
	enemy.global_position = tank.global_position + Vector3(0.0, 0.0, -2.0)
	var hp_before_hold_ground: float = enemy.hp
	var position_before_engagement: Vector3 = tank.global_position
	gateway.SetFirePolicy([tank], "FireAtWill", human)
	var encounter_hit: bool = await _wait_for_hp_below(enemy, hp_before_hold_ground, 3.0)
	_check(encounter_hit, "固守 AttackMove 应处理射程内敌人")
	_check(
		tank.global_position.distance_to(position_before_engagement) < 0.6,
		"固守 AttackMove 交战时不应主动离路追击"
	)
	enemy.hp = 0
	await get_tree().create_timer(0.45).timeout
	_check(
		tank.global_position.distance_to(position_before_engagement) > 0.35,
		"途中敌人清除后应恢复原推进订单"
	)

	print("Tank ground attack move smoke test completed: %d failure(s)" % _failures)
	match_instance.queue_free()
	await get_tree().process_frame
	SmokeTestExit.request(get_tree(), 0 if _failures == 0 else 1)


func _add_enemy_player(match_instance):
	var enemy_player := Node3D.new()
	enemy_player.name = "GroundAttackMoveEnemy"
	enemy_player.set_script(Player)
	enemy_player.color = Color.RED
	enemy_player.add_to_group("players")
	match_instance.get_node("Players").add_child(enemy_player)
	return enemy_player


func _add_enemy_structure(enemy_player, position: Vector3):
	var enemy = CommandCenterScene.instantiate()
	enemy.name = "EncounterTarget"
	enemy.position = position
	enemy.add_to_group("units")
	enemy.add_to_group("adversary_units")
	enemy_player.add_child(enemy)
	return enemy


func _check(condition: bool, message: String):
	if condition:
		return
	_failures += 1
	push_error("Tank ground attack move assertion failed: %s" % message)


## 等待途中目标被飞行中的投射物命中。
func _wait_for_hp_below(unit, previous_hp: float, timeout_seconds: float) -> bool:
	var elapsed_seconds := 0.0
	while elapsed_seconds < timeout_seconds:
		if not is_instance_valid(unit) or unit.hp < previous_hp:
			return true
		await get_tree().create_timer(0.1).timeout
		elapsed_seconds += 0.1
	return not is_instance_valid(unit) or unit.hp < previous_hp


## 在导航时序允许的上限内等待单位离开起点，避免用固定帧时间制造假失败。
func _wait_for_distance_from(
	unit, starting_position: Vector3, minimum_distance: float, timeout_seconds: float
) -> bool:
	var elapsed_seconds := 0.0
	while elapsed_seconds < timeout_seconds:
		if not is_instance_valid(unit):
			return false
		if unit.global_position.distance_to(starting_position) > minimum_distance:
			return true
		await get_tree().create_timer(0.1).timeout
		elapsed_seconds += 0.1
	return (
		is_instance_valid(unit)
		and unit.global_position.distance_to(starting_position) > minimum_distance
	)
