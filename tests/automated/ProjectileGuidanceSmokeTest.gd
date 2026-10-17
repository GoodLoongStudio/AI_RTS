extends Node

const SmokeTestWarmup = preload("res://tests/automated/SmokeTestWarmup.gd")
const MatchScene = preload("res://tests/manual/TestOneUnit.tscn")
const TankScene = preload("res://source/match/units/Tank.tscn")
const AntiAirScene = preload("res://source/match/units/AntiAirTurret.tscn")
const HelicopterScene = preload("res://source/match/units/Helicopter.tscn")
const Player = preload("res://source/match/players/Player.gd")

var _failures := 0


func _ready():
	var match_instance = MatchScene.instantiate()
	add_child(match_instance)
	await SmokeTestWarmup.wait_for_units(get_tree(), 1)

	var human = match_instance.get_node("Players/Human")
	var runtime = match_instance.get_node("ProjectileRuntime")
	var gateway = human.get_node("UnitCommandGateway")
	var source = human.get_node("Tank")
	gateway.SetFirePolicy([source], "HoldFire", human)
	var enemy_player = _add_enemy_player(match_instance)
	var target = _add_unit(TankScene, enemy_player, "MovedTank", source.global_position + Vector3(3, 0, 0))
	var blast_neighbor = _add_unit(
		TankScene, enemy_player, "BlastNeighbor", target.global_position + Vector3(0, 0, 4.5)
	)
	await get_tree().process_frame
	gateway.SetFirePolicy([target, blast_neighbor], "HoldFire", enemy_player)
	target.hp = 100
	blast_neighbor.hp = 100
	var tank_start = target.global_position
	var neighbor_hp := float(blast_neighbor.hp)
	runtime.LaunchEntity(source, target, false)
	await get_tree().create_timer(0.08).timeout
	target.global_position = tank_start + Vector3(0, 0, 12)
	await _wait_for_projectiles_to_finish(match_instance.get_node("Projectiles"), 2.0)
	_check(float(target.hp) == 100.0, "坦克炮弹应锁定发射落点，移出爆炸范围的目标不能被追中")
	_check(
		float(blast_neighbor.hp) < neighbor_hp,
		"坦克炮弹冻结落点 4.5m 内的邻近目标应受扩大后溅射伤害"
	)

	var aa_source = _add_unit(
		AntiAirScene, human, "GuidingAntiAir", source.global_position + Vector3(0, 0, 15)
	)
	var air_target = _add_unit(
		HelicopterScene, enemy_player, "MovingAircraft", aa_source.global_position + Vector3(6, 0, 0)
	)
	await get_tree().process_frame
	gateway.SetFirePolicy([aa_source], "HoldFire", human)
	air_target.hp = 100
	var air_start = air_target.global_position
	var air_hp := float(air_target.hp)
	runtime.LaunchEntity(aa_source, air_target, false)
	await get_tree().create_timer(0.12).timeout
	air_target.global_position = air_start + Vector3(0, 0, 5)
	await _wait_for_projectiles_to_finish(match_instance.get_node("Projectiles"), 2.0)
	_check(float(air_target.hp) < air_hp, "防空炮弹应继续追踪飞行中的移动目标")

	print("Projectile guidance smoke test completed: %d failure(s)" % _failures)
	match_instance.queue_free()
	await get_tree().process_frame
	SmokeTestExit.request(get_tree(), 0 if _failures == 0 else 1)


func _add_enemy_player(match_instance):
	var enemy := Node3D.new()
	enemy.name = "ProjectileGuidanceEnemy"
	enemy.set_script(Player)
	enemy.color = Color.RED
	enemy.add_to_group("players")
	match_instance.get_node("Players").add_child(enemy)
	return enemy


func _add_unit(scene: PackedScene, player: Node, unit_name: String, at: Vector3) -> Node3D:
	var unit: Node3D = scene.instantiate()
	unit.name = unit_name
	unit.global_position = at
	unit.add_to_group("units")
	player.add_child(unit)
	return unit


func _wait_for_projectiles_to_finish(projectiles: Node, timeout: float) -> void:
	var deadline := Time.get_ticks_msec() + int(timeout * 1000.0)
	while projectiles.get_child_count() > 0 and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame


func _check(condition: bool, message: String) -> void:
	if condition:
		print("[PASS] " + message)
	else:
		_failures += 1
		push_error("Projectile guidance assertion failed: " + message)
