extends Node

const MatchScene = preload("res://tests/manual/TestHelicopterCommands.tscn")
const TankScene = preload("res://source/match/units/Tank.tscn")
const Player = preload("res://source/match/players/Player.gd")
const Moving = preload("res://source/match/units/actions/Moving.gd")
const GroundAttackMoving = preload("res://source/match/units/actions/GroundAttackMoving.gd")

var _failures := 0


## 验证 Helicopter 通过公共命令链路执行移动、战斗和无倒车撤退回退。
func _ready():
	var match_instance = MatchScene.instantiate()
	add_child(match_instance)
	await get_tree().process_frame
	await get_tree().process_frame

	var human = match_instance.get_node("Players/Human")
	var helicopter = human.get_node("Helicopter")
	var tank = human.get_node("Tank")
	var gateway = human.get_node("UnitCommandGateway")
	var controller = human.get_node("UnitActionsController")
	gateway.SetFirePolicy([tank, helicopter], "HoldFire", human)
	var enemy_player = _add_enemy_player(match_instance)
	var enemy = _add_enemy_tank(
		enemy_player, helicopter.global_position + Vector3(3.0, 0.0, 0.0)
	)
	gateway.SetFirePolicy([enemy], "HoldFire", enemy_player)
	await get_tree().process_frame
	_check(
		await _wait_for_navigation_map(helicopter.find_child("Movement").get_navigation_map(), 3.0),
		"空中导航图应在命令测试前完成同步"
	)

	helicopter.find_child("Selection").select()
	_check(controller.get_selected_command_unit_count() == 1, "传统 HUD 应识别 Helicopter")
	var move_start: Vector3 = helicopter.global_position
	MatchSignals.terrain_targeted.emit(move_start + Vector3(0.0, 0.0, 4.0))
	var helicopter_moved: bool = await _wait_for_displacement(helicopter, move_start, 2.0)
	_check(gateway.GetActiveOrderState(helicopter) == "InProgress", "普通右键移动应进入公共订单")
	var movement = helicopter.find_child("Movement")
	_check(
		helicopter_moved,
		"Helicopter 应执行公共移动；位置=%s，目标=%s，下一路径点=%s" % [
			helicopter.global_position,
			movement.target_position,
			movement.get_next_path_position(),
		]
	)
	controller.halt_selected_units()
	await get_tree().process_frame
	var stopped_position: Vector3 = helicopter.global_position
	await get_tree().create_timer(0.3).timeout
	_check(
		helicopter.global_position.distance_to(stopped_position) < 0.03,
		"传统 HUD Stop 应停止 Helicopter；停止后位移=%s" % helicopter.global_position.distance_to(
			stopped_position
		)
	)

	var withdraw_result = gateway.TacticalWithdrawUnits(
		[helicopter], helicopter.global_position + Vector3(3.0, 0.0, 0.0), human
	)
	_check(withdraw_result["status"] == "Accepted", "无倒车能力的 Helicopter 撤退应被接受")
	_check(
		helicopter.action != null and helicopter.action.get_script() == Moving,
		"Helicopter 撤退应退化为普通移动"
	)
	gateway.StopUnits([helicopter], human)

	var attack_move_result = gateway.GroundAttackMoveUnits(
		[helicopter], helicopter.global_position + Vector3(0.0, 0.0, 5.0), human
	)
	_check(attack_move_result["status"] == "Accepted", "Helicopter 移动并攻击应被接受")
	_check(
		helicopter.action != null and helicopter.action.get_script() == GroundAttackMoving,
		"Helicopter 应复用公共 GroundAttackMoving 执行边界"
	)
	gateway.StopUnits([helicopter], human)

	var ordinary_attack = gateway.AttackUnits([helicopter], enemy, human)
	_check(ordinary_attack["status"] == "Rejected", "HoldFire 应拒绝 Helicopter 普通攻击")
	_check(
		ordinary_attack["unit_results"][0]["error_code"] == "FirePolicyPreventsAttack",
		"Helicopter 停火拒绝应返回稳定错误码"
	)
	var enemy_hp_before: float = enemy.hp
	var force_attack = gateway.ForceAttackUnits([helicopter], enemy, human)
	_check(force_attack["status"] == "Accepted", "Helicopter ForceAttack 应临时覆盖停火")
	var rocket_hit: bool = await _wait_for_hp_below(enemy, enemy_hp_before, 3.0)
	_check(rocket_hit, "Helicopter Rocket 应在视觉命中时造成伤害")
	gateway.StopUnits([helicopter], human)
	_check(gateway.GetFirePolicy(helicopter) == "HoldFire", "停止后 Helicopter 应保持停火")

	var ground_force = gateway.ForceAttackGround(
		[helicopter], helicopter.global_position + Vector3(2.0, 0.0, 0.0), human
	)
	_check(ground_force["status"] == "Rejected", "Helicopter 不支持对地强制攻击时应稳定拒绝")
	_check(
		ground_force["unit_results"][0]["error_code"] == "WeaponCannotForceFire",
		"缺少地面强制攻击能力应返回 WeaponCannotForceFire"
	)

	print("Helicopter command smoke test completed: %d failure(s)" % _failures)
	match_instance.queue_free()
	await get_tree().process_frame
	get_tree().quit(0 if _failures == 0 else 1)


## 创建测试使用的敌方玩家。
func _add_enemy_player(match_instance):
	var enemy_player := Node3D.new()
	enemy_player.name = "HelicopterCommandEnemy"
	enemy_player.set_script(Player)
	enemy_player.color = Color.RED
	enemy_player.add_to_group("players")
	match_instance.get_node("Players").add_child(enemy_player)
	return enemy_player


## 创建可由 Helicopter 攻击的敌方地面单位。
func _add_enemy_tank(enemy_player, position: Vector3):
	var enemy = TankScene.instantiate()
	enemy.name = "HelicopterGroundTarget"
	enemy.position = position
	enemy.add_to_group("units")
	enemy.add_to_group("adversary_units")
	enemy.add_to_group("revealed_units")
	enemy_player.add_child(enemy)
	return enemy


func _check(condition: bool, message: String):
	if condition:
		return
	_failures += 1
	push_error("Helicopter command assertion failed: %s" % message)


## 在超时时间内等待 Rocket 完成视觉命中。
func _wait_for_hp_below(unit, previous_hp: float, timeout_seconds: float) -> bool:
	var elapsed_seconds := 0.0
	while elapsed_seconds < timeout_seconds:
		if not is_instance_valid(unit) or unit.hp < previous_hp:
			return true
		await get_tree().create_timer(0.1).timeout
		elapsed_seconds += 0.1
	return not is_instance_valid(unit) or unit.hp < previous_hp


## 在超时时间内等待空中导航产生可测位移。
func _wait_for_displacement(unit, origin: Vector3, timeout_seconds: float) -> bool:
	var elapsed_seconds := 0.0
	while elapsed_seconds < timeout_seconds:
		if unit.global_position.distance_to(origin) > 0.05:
			return true
		await get_tree().create_timer(0.1).timeout
		elapsed_seconds += 0.1
	return unit.global_position.distance_to(origin) > 0.05


## 等待运行时烘焙的空中导航图完成至少一次同步迭代。
func _wait_for_navigation_map(navigation_map: RID, timeout_seconds: float) -> bool:
	var elapsed_seconds := 0.0
	while elapsed_seconds < timeout_seconds:
		if NavigationServer3D.map_get_iteration_id(navigation_map) > 0:
			return true
		await get_tree().create_timer(0.1).timeout
		elapsed_seconds += 0.1
	return NavigationServer3D.map_get_iteration_id(navigation_map) > 0
