extends Node

const MatchScene = preload("res://tests/manual/TestOneUnit.tscn")
const TankScene = preload("res://source/match/units/Tank.tscn")
const Player = preload("res://source/match/players/Player.gd")
const Moving = preload("res://source/match/units/actions/Moving.gd")

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
	var enemy = _add_enemy_tank(enemy_player, tank.global_position + Vector3(0.0, 0.0, -2.0))
	gateway.SetFirePolicy([enemy], "HoldFire", enemy_player)

	var start_position: Vector3 = tank.global_position
	var enemy_hp_before: float = enemy.hp
	var result = gateway.MoveUnits(
		[tank], tank.global_position + Vector3(0.0, 0.0, -5.0), human
	)
	_check(result["status"] == "Accepted", "普通 Move 应被接受")
	_check(tank.action != null and tank.action.get_script() == Moving, "普通 Move 应使用移动行为")
	await get_tree().create_timer(0.45).timeout
	_check(tank.global_position.distance_to(start_position) > 0.05, "Tank 开火时仍应持续推进")
	_check(enemy.hp < enemy_hp_before, "射界内敌人应受到移动伴随射击")

	var hp_after_hold_fire: float = enemy.hp
	gateway.SetFirePolicy([tank], "HoldFire", human)
	await get_tree().create_timer(0.8).timeout
	_check(enemy.hp == hp_after_hold_fire, "移动中切换 HoldFire 应立即停止伴随射击")

	print("Tank move fire smoke test completed: %d failure(s)" % _failures)
	match_instance.queue_free()
	await get_tree().process_frame
	get_tree().quit(0 if _failures == 0 else 1)


func _add_enemy_player(match_instance):
	var enemy_player := Node3D.new()
	enemy_player.name = "MoveFireEnemy"
	enemy_player.set_script(Player)
	enemy_player.color = Color.RED
	enemy_player.add_to_group("players")
	match_instance.get_node("Players").add_child(enemy_player)
	return enemy_player


func _add_enemy_tank(enemy_player, position: Vector3):
	var enemy = TankScene.instantiate()
	enemy.name = "MoveFireTarget"
	enemy.position = position
	enemy.add_to_group("units")
	enemy.add_to_group("adversary_units")
	enemy_player.add_child(enemy)
	return enemy


func _check(condition: bool, message: String):
	if condition:
		return
	_failures += 1
	push_error("Tank move fire assertion failed: %s" % message)
