extends Node

## APC 装甲车冒烟测试（2026-09-11）：
## 载具页签新单位——生成 APC 与敌方步兵，APC 自主开火应在限时内造成伤害。

const MatchScene = preload("res://tests/manual/TestAllUnits.tscn")
const APCScene = preload("res://source/match/units/APC.tscn")
const InfantryScene = preload("res://source/match/units/Infantry.tscn")
const Player = preload("res://source/match/players/Player.gd")

const WAIT_SECONDS := 20.0

var _failures := 0
var _finished := false


func _ready():
	get_tree().create_timer(45.0).timeout.connect(_on_failsafe)
	var match_instance = MatchScene.instantiate()
	add_child(match_instance)
	await get_tree().process_frame
	await get_tree().create_timer(0.5).timeout

	var human = match_instance.get_node("Players/Human")
	var enemy_player = Player.new()
	enemy_player.name = "ApcEnemy"
	enemy_player.color = Color.RED
	enemy_player.add_to_group("players")
	match_instance.get_node("Players").add_child(enemy_player)

	var apc = APCScene.instantiate()
	MatchSignals.setup_and_spawn_unit.emit(
		apc, Transform3D(Basis.IDENTITY, Vector3(6, 0, 2)), human, false
	)
	var enemy_soldier = InfantryScene.instantiate()
	MatchSignals.setup_and_spawn_unit.emit(
		enemy_soldier, Transform3D(Basis.IDENTITY, Vector3(7, 0, 2)), enemy_player, false
	)
	await get_tree().process_frame
	await get_tree().create_timer(0.5).timeout
	_check(apc.hp != null and apc.hp_max != null, "APC 应接入权威生命值配置")
	var hp_before: float = enemy_soldier.hp

	var waited := 0.0
	while waited < WAIT_SECONDS:
		if enemy_soldier.hp < hp_before:
			break
		await get_tree().create_timer(0.25).timeout
		waited += 0.25

	_check(
		is_instance_valid(enemy_soldier) and enemy_soldier.hp < hp_before,
		"APC 机炮应在 %s 秒内命中敌方步兵（%s → %s）" % [WAIT_SECONDS, hp_before, enemy_soldier.hp if is_instance_valid(enemy_soldier) else "已阵亡"]
	)

	print("APC smoke test completed: %d failure(s)" % _failures)
	SmokeTestExit.request(get_tree(), 0 if _failures == 0 else 1)


func _on_failsafe():
	if _finished:
		return
	print("FAIL: 看门狗超时——测试协程中断未收尾")
	_finish()


func _finish():
	if _finished:
		return
	_finished = true
	print("APC smoke test completed: %d failure(s)" % _failures)
	SmokeTestExit.request(get_tree(), 0 if _failures == 0 else 1)


func _check(condition: bool, message: String):
	if condition:
		return
	_failures += 1
	print("FAIL: %s" % message)
	push_error("APC smoke test assertion failed: %s" % message)
