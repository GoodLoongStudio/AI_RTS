extends Node

const SmokeTestWarmup = preload("res://tests/automated/SmokeTestWarmup.gd")

## 狙击兵/炮兵冒烟测试（2026-09-13）：与步兵同骨架逻辑——对射程内敌人开火并造成伤害。
## 狙击兵射程 11 米应能打到 10 米外目标；炮兵火箭溅射命中。

const MatchScene = preload("res://tests/manual/TestOneUnit.tscn")
const SniperScene = preload("res://source/match/units/Sniper.tscn")
const RocketeerScene = preload("res://source/match/units/Rocketeer.tscn")
const InfantryScene = preload("res://source/match/units/Infantry.tscn")
const Player = preload("res://source/match/players/Player.gd")

const FIRE_TIMEOUT_SECONDS := 15.0

var _failures := 0


func _ready():
	var match_instance = MatchScene.instantiate()
	add_child(match_instance)
	await SmokeTestWarmup.wait_for_units(get_tree(), 1)
	await get_tree().create_timer(0.5).timeout

	var human = match_instance.get_node("Players/Human")
	var enemy_player = Player.new()
	enemy_player.name = "SrEnemy"
	enemy_player.color = Color.RED
	enemy_player.add_to_group("players")
	match_instance.get_node("Players").add_child(enemy_player)

	# 狙击兵：敌人放在 9.5 米外（超出步兵 6 米视野/射程，狙击兵 11 米可及）
	var sniper = SniperScene.instantiate()
	sniper.name = "SniperTestUnit"
	MatchSignals.setup_and_spawn_unit.emit(
		sniper, Transform3D(Basis.IDENTITY, Vector3.ZERO), human, false
	)
	var far_target = InfantryScene.instantiate()
	far_target.name = "FarTarget"
	far_target.position = Vector3(9.5, 0, 0)
	far_target.add_to_group("units")
	far_target.add_to_group("revealed_units")
	far_target.hp = 20
	enemy_player.add_child(far_target)

	# 炮兵：敌人放在 5 米外（7 米射程内，溅射覆盖）
	var rocketeer = RocketeerScene.instantiate()
	rocketeer.name = "RocketeerTestUnit"
	MatchSignals.setup_and_spawn_unit.emit(
		rocketeer, Transform3D(Basis.IDENTITY, Vector3(0, 0, 5)), human, false
	)
	var near_target = InfantryScene.instantiate()
	near_target.name = "NearTarget"
	near_target.position = Vector3(5, 0, 5)
	near_target.add_to_group("units")
	near_target.add_to_group("revealed_units")
	near_target.hp = 20
	enemy_player.add_child(near_target)
	await get_tree().physics_frame
	await get_tree().create_timer(0.5).timeout

	var gateway = human.get_node("UnitCommandGateway")
	gateway.SetFirePolicy([far_target, near_target], "HoldFire", enemy_player)

	var far_before: float = far_target.hp
	var near_before: float = near_target.hp
	var far_hit := false
	var near_hit := false
	var elapsed := 0.0
	while elapsed < FIRE_TIMEOUT_SECONDS and not (far_hit and near_hit):
		await get_tree().create_timer(0.2).timeout
		elapsed += 0.2
		# 目标被打死会被释放，视作命中成功（血 20 早被两人火力打穿）
		if not is_instance_valid(far_target) or far_target.hp < far_before:
			far_hit = true
		if not is_instance_valid(near_target) or near_target.hp < near_before:
			near_hit = true

	_check(far_hit, "狙击兵应在 %.0fs 内命中 9.5 米外目标（超步兵射程，验证狙击特性）" % FIRE_TIMEOUT_SECONDS)
	_check(near_hit, "炮兵应命中 5 米内目标并造成溅射伤害")
	# 武器烘焙验证：新 GLB 的枪械网格（Rifle 节点）应存在且可见
	var baked_gun = sniper.find_child("Rifle", true, false)
	_check(baked_gun != null and baked_gun.visible, "狙击兵的烘焙武器网格应存在且可见")

	print("Sniper/Rocketeer smoke test completed: %d failure(s)" % _failures)
	match_instance.queue_free()
	await get_tree().process_frame
	SmokeTestExit.request(get_tree(), 0 if _failures == 0 else 1)


func _check(condition: bool, message: String):
	if condition:
		return
	_failures += 1
	print("FAIL: %s" % message)
	push_error("Sniper/Rocketeer assertion failed: %s" % message)
