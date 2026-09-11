extends Node

## 重型坦克 / 悬浮摩托战斗冒烟测试（2026-09-11）：
## 重坦（坦克炮）与悬浮摩托（机炮）生成后应能自主命中敌方步兵。

const MatchScene = preload("res://tests/manual/TestAllUnits.tscn")
const HeavyTankScene = preload("res://source/match/units/HeavyTank.tscn")
const HoverBikeScene = preload("res://source/match/units/HoverBike.tscn")
const InfantryScene = preload("res://source/match/units/Infantry.tscn")
const Player = preload("res://source/match/players/Player.gd")

const WAIT_SECONDS := 20.0

var _failures := 0


func _ready():
	get_tree().create_timer(60.0).timeout.connect(_on_failsafe)
	var match_instance = MatchScene.instantiate()
	add_child(match_instance)
	await get_tree().process_frame
	await get_tree().create_timer(0.5).timeout

	var human = match_instance.get_node("Players/Human")
	var enemy_player = Player.new()
	enemy_player.name = "VehicleBatchEnemy"
	enemy_player.color = Color.RED
	enemy_player.add_to_group("players")
	match_instance.get_node("Players").add_child(enemy_player)

	var heavy_tank = HeavyTankScene.instantiate()
	MatchSignals.setup_and_spawn_unit.emit(
		heavy_tank, Transform3D(Basis.IDENTITY, Vector3(6, 0, 4)), human, false
	)
	var hover_bike = HoverBikeScene.instantiate()
	MatchSignals.setup_and_spawn_unit.emit(
		hover_bike, Transform3D(Basis.IDENTITY, Vector3(6, 0, 6)), human, false
	)
	var target_a = InfantryScene.instantiate()
	MatchSignals.setup_and_spawn_unit.emit(
		target_a, Transform3D(Basis.IDENTITY, Vector3(7, 0, 4)), enemy_player, false
	)
	var target_b = InfantryScene.instantiate()
	MatchSignals.setup_and_spawn_unit.emit(
		target_b, Transform3D(Basis.IDENTITY, Vector3(7, 0, 6)), enemy_player, false
	)
	await get_tree().process_frame
	await get_tree().create_timer(0.5).timeout
	_check(heavy_tank.hp != null and hover_bike.hp != null, "重坦/摩托应接入权威生命值配置")

	var hp_a: float = target_a.hp
	var hp_b: float = target_b.hp
	var waited := 0.0
	while waited < WAIT_SECONDS:
		var a_hit = not is_instance_valid(target_a) or target_a.hp < hp_a
		var b_hit = not is_instance_valid(target_b) or target_b.hp < hp_b
		if a_hit and b_hit:
			break
		await get_tree().create_timer(0.25).timeout
		waited += 0.25

	var a_hit = not is_instance_valid(target_a) or (is_instance_valid(target_a) and target_a.hp < hp_a)
	var b_hit = not is_instance_valid(target_b) or (is_instance_valid(target_b) and target_b.hp < hp_b)
	_check(a_hit, "重型坦克坦克炮应命中敌方步兵")
	_check(b_hit, "悬浮摩托机炮应命中敌方步兵")

	print("Vehicle batch smoke test completed: %d failure(s)" % _failures)
	SmokeTestExit.request(get_tree(), 0 if _failures == 0 else 1)


func _on_failsafe():
	print("FAIL: 看门狗超时——测试协程中断未收尾")
	print("Vehicle batch smoke test completed: %d failure(s)" % _failures)
	SmokeTestExit.request(get_tree(), 1)

func _check(condition: bool, message: String):
	if condition:
		return
	_failures += 1
	print("FAIL: %s" % message)
	push_error("Vehicle batch smoke test assertion failed: %s" % message)
