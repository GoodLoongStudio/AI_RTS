extends Node

const MatchScene = preload("res://tests/manual/TestOneUnit.tscn")
const TankScene = preload("res://source/match/units/Tank.tscn")
const HelicopterScene = preload("res://source/match/units/Helicopter.tscn")
const Player = preload("res://source/match/players/Player.gd")

var _failures := 0


## 验证炮弹和导弹脱离发射者生命周期，并在视觉命中时只结算一次快照伤害。
func _ready():
	var match_instance = MatchScene.instantiate()
	add_child(match_instance)
	await get_tree().process_frame
	await get_tree().process_frame

	var human = match_instance.get_node("Players/Human")
	var gateway = human.get_node("UnitCommandGateway")
	var runtime = match_instance.get_node("ProjectileRuntime")
	var projectiles = match_instance.get_node("Projectiles")
	var cannon_source = human.get_node("Tank")
	# 在创建敌方目标前先停火，避免自主索敌在测试发射之外额外生成炮弹。
	gateway.SetFirePolicy([cannon_source], "HoldFire", human)
	var enemy_player = _add_enemy_player(match_instance)
	var cannon_target = _add_unit(
		TankScene, enemy_player, "CannonTarget", cannon_source.position + Vector3(3, 0, 0)
	)
	await get_tree().process_frame
	gateway.SetFirePolicy([cannon_target], "HoldFire", enemy_player)
	cannon_target.hp = 100
	var cannon_hp_before: float = cannon_target.hp

	runtime.LaunchEntity(cannon_source, cannon_target)
	_check(cannon_target.hp == cannon_hp_before, "CannonShell 发射时不应提前结算伤害")
	cannon_source.hp = 0
	await get_tree().process_frame
	_check(projectiles.get_child_count() > 0, "发射者阵亡后 CannonShell 视觉应继续存在")
	await _wait_for_hp_below(cannon_target, cannon_hp_before, 3.0)
	_check(
		cannon_target.hp == cannon_hp_before - 2,
		"发射者阵亡后 CannonShell 应使用发射快照完成一次伤害；实际 HP=%s" % cannon_target.hp
	)

	var rocket_source = _add_unit(
		HelicopterScene, human, "RocketSource", cannon_target.position + Vector3(-3, 0, 0)
	)
	var rocket_target = _add_unit(
		TankScene, enemy_player, "RocketTarget", rocket_source.position + Vector3(3, 0, 0)
	)
	await get_tree().process_frame
	gateway.SetFirePolicy([rocket_source], "HoldFire", human)
	gateway.SetFirePolicy([rocket_target], "HoldFire", enemy_player)
	rocket_target.hp = 100
	var rocket_hp_before: float = rocket_target.hp
	runtime.LaunchEntity(rocket_source, rocket_target)
	rocket_source.hp = 0
	await get_tree().process_frame
	_check(projectiles.get_child_count() > 0, "发射者阵亡后 Rocket 视觉应继续存在")
	await _wait_for_hp_below(rocket_target, rocket_hp_before, 2.0)
	_check(
		rocket_target.hp == rocket_hp_before - 1,
		"发射者阵亡后 Rocket 应使用发射快照完成一次伤害"
	)

	var lost_target_source = _add_unit(
		HelicopterScene, human, "LostTargetSource", rocket_target.position + Vector3(-3, 0, 0)
	)
	var lost_target = _add_unit(
		TankScene, enemy_player, "LostRocketTarget", lost_target_source.position + Vector3(3, 0, 0)
	)
	await get_tree().process_frame
	gateway.SetFirePolicy([lost_target_source], "HoldFire", human)
	gateway.SetFirePolicy([lost_target], "HoldFire", enemy_player)
	runtime.LaunchEntity(lost_target_source, lost_target)
	lost_target.hp = 0
	await get_tree().process_frame
	_check(projectiles.get_child_count() > 0, "目标先失效时 Rocket 不应立即消失")
	await get_tree().create_timer(0.7).timeout

	print("Projectile lifecycle smoke test completed: %d failure(s)" % _failures)
	match_instance.queue_free()
	await get_tree().process_frame
	get_tree().quit(0 if _failures == 0 else 1)


func _add_enemy_player(match_instance):
	var enemy_player := Node3D.new()
	enemy_player.name = "ProjectileEnemy"
	enemy_player.set_script(Player)
	enemy_player.color = Color.RED
	enemy_player.add_to_group("players")
	match_instance.get_node("Players").add_child(enemy_player)
	return enemy_player


func _add_unit(scene: PackedScene, player, unit_name: String, position: Vector3):
	var unit = scene.instantiate()
	unit.name = unit_name
	unit.position = position
	unit.add_to_group("units")
	player.add_child(unit)
	return unit


func _check(condition: bool, message: String):
	if condition:
		return
	_failures += 1
	push_error("Projectile lifecycle assertion failed: %s" % message)


## 在超时时间内等待一次视觉命中，兼容首帧初始化和低帧率下的计时偏差。
func _wait_for_hp_below(unit, previous_hp: float, timeout_seconds: float) -> bool:
	var elapsed_seconds := 0.0
	while elapsed_seconds < timeout_seconds:
		if not is_instance_valid(unit) or unit.hp < previous_hp:
			return true
		await get_tree().create_timer(0.1).timeout
		elapsed_seconds += 0.1
	return not is_instance_valid(unit) or unit.hp < previous_hp
