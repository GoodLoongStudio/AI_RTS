extends Node

const MatchScene = preload("res://tests/manual/TestOneUnit.tscn")
const TankScene = preload("res://source/match/units/Tank.tscn")
const Player = preload("res://source/match/players/Player.gd")

var _failures := 0
var _order_events: Array[Dictionary] = []


func _ready():
	var match_instance = MatchScene.instantiate()
	add_child(match_instance)
	await get_tree().process_frame
	await get_tree().process_frame

	var human = match_instance.get_node("Players/Human")
	var attacker = human.get_node("Tank")
	var gateway = human.get_node("UnitCommandGateway")
	match_instance.get_node("CommandRuntime").connect("OrderStateChanged", _on_order_state_changed)
	var controller = human.get_node("UnitActionsController")
	var friendly_target = _add_tank(human, "FriendlyTarget", attacker.position + Vector3(3, 0, 0))
	friendly_target.add_to_group("controlled_units")
	var enemy_player = _add_enemy_player(match_instance)
	var enemy_target = _add_tank(
		enemy_player, "EnemyTarget", attacker.position + Vector3(-3, 0, 0)
	)
	enemy_target.add_to_group("adversary_units")

	gateway.SetFirePolicy([attacker, friendly_target], "HoldFire", human)
	gateway.SetFirePolicy([enemy_target], "HoldFire", enemy_player)
	var friendly_hp_before: float = friendly_target.hp
	var friendly_result = gateway.ForceAttackUnits([attacker], friendly_target, human)
	var friendly_order_id: String = friendly_result["unit_results"][0]["order_id"]
	_check(friendly_result["status"] == "Accepted", "HoldFire 下显式攻击己方目标应被接受")
	await get_tree().create_timer(2.0).timeout
	_check(friendly_target.hp < friendly_hp_before, "显式攻击己方目标应造成完整基础伤害")
	_check(gateway.GetFirePolicy(attacker) == "HoldFire", "临时授权不得修改持久停火策略")

	controller.halt_selected_units()  # 未选择单位时不应影响当前 ForceAttack。
	await get_tree().create_timer(0.1).timeout
	_check(gateway.GetOrderState(friendly_order_id) == "InProgress", "空 Selection 停止移动不应取消攻击")
	attacker.find_child("Selection").select()
	controller.halt_selected_units()
	_check(gateway.GetOrderState(friendly_order_id) == "InProgress", "停止移动不应取消显式 ForceAttack")
	controller.stop_selected_units()
	_check(gateway.GetOrderState(friendly_order_id) == "Cancelled", "完整停止应取消显式 ForceAttack 订单")
	await get_tree().create_timer(1.1).timeout
	var hp_after_in_flight_force_attack: float = friendly_target.hp
	await get_tree().create_timer(0.8).timeout
	_check(
		friendly_target.hp == hp_after_in_flight_force_attack,
		"停止后允许在途弹命中，但不得继续产生新的显式攻击伤害"
	)
	_check(gateway.GetFirePolicy(attacker) == "HoldFire", "停止后应恢复原持久停火策略")

	var enemy_hp_before: float = enemy_target.hp
	MatchSignals.unit_targeted.emit(enemy_target, enemy_target.global_position)
	await get_tree().create_timer(2.0).timeout
	_check(enemy_target.hp == enemy_hp_before, "HoldFire 下普通右键敌人不应绕过停火")

	enemy_target.hp = 2
	var enemy_result = gateway.ForceAttackUnits([attacker], enemy_target, human)
	var enemy_order_id: String = enemy_result["unit_results"][0]["order_id"]
	await get_tree().create_timer(2.0).timeout
	_check(not is_instance_valid(enemy_target) or enemy_target.hp == 0, "显式攻击应能摧毁敌方目标")
	_check(gateway.GetOrderState(enemy_order_id) == "TargetLost", "目标死亡后订单应进入 TargetLost")
	_check(
		_states_for_order(enemy_order_id) == ["Accepted", "InProgress", "TargetLost"],
		"目标死亡应通过统一订单事件发布 TargetLost"
	)

	var ground_target = _add_tank(
		friendly_target.get_parent(),
		"GroundPointTarget",
		attacker.position + Vector3(2, 0, 0)
	)
	ground_target.add_to_group("controlled_units")
	await get_tree().process_frame
	ground_target.find_child("Movement").suspend_motion()
	var ground_hp_before: float = ground_target.hp
	var ground_result = gateway.ForceAttackGround(
		[attacker],
		ground_target.global_position,
		human
	)
	var ground_order_id: String = ground_result["unit_results"][0]["order_id"]
	_check(ground_result["status"] == "Accepted", "Tank 地面强制攻击应被接受")
	_check(gateway.GetFirePolicy(attacker) == "HoldFire", "地面炮击不得修改持久停火策略")
	var ground_damaged: bool = await _wait_for_hp_below(ground_target, ground_hp_before, 4.0)
	_check(ground_damaged, "地面落点覆盖单位 footprint 时应造成完整基础伤害")
	_check(gateway.GetOrderState(ground_order_id) == "InProgress", "地面炮击应持续执行")
	var ground_cancel = gateway.StopUnits([attacker], human)
	_check(ground_cancel["status"] == "Accepted", "地面炮击应可由统一 Stop 取消")
	_check(gateway.GetOrderState(ground_order_id) == "Cancelled", "取消后地面炮击订单应终止")
	await get_tree().create_timer(1.1).timeout
	var hp_after_in_flight_ground_attack: float = ground_target.hp
	await get_tree().create_timer(0.8).timeout
	_check(
		ground_target.hp == hp_after_in_flight_ground_attack,
		"取消后允许在途弹命中，但不得继续产生新的地面炮击伤害"
	)

	var far_ground_result = gateway.ForceAttackGround(
		[attacker],
		attacker.global_position + Vector3(8.0, 0.0, 0.0),
		human
	)
	var far_ground_order_id: String = far_ground_result["unit_results"][0]["order_id"]
	_check(far_ground_result["status"] == "Accepted", "远距离地面炮击应先接近射程")
	await get_tree().create_timer(0.25).timeout
	gateway.StopUnits([attacker], human)
	await get_tree().process_frame
	var position_before_far_stop: Vector3 = attacker.global_position
	await get_tree().create_timer(0.35).timeout
	_check(
		attacker.global_position.distance_to(position_before_far_stop) < 0.02,
		"远距离地面炮击接近途中收到 Stop 后不得继续向落点移动"
	)
	_check(gateway.GetOrderState(far_ground_order_id) == "Cancelled", "远距离地面炮击应可取消")

	print("Tank force attack smoke test completed: %d failure(s)" % _failures)
	match_instance.queue_free()
	await get_tree().process_frame
	SmokeTestExit.request(get_tree(), 0 if _failures == 0 else 1)


func _add_enemy_player(match_instance):
	var enemy_player := Node3D.new()
	enemy_player.name = "ForceAttackEnemy"
	enemy_player.set_script(Player)
	enemy_player.color = Color.RED
	enemy_player.add_to_group("players")
	match_instance.get_node("Players").add_child(enemy_player)
	return enemy_player


func _add_tank(player, unit_name: String, position: Vector3):
	var tank = TankScene.instantiate()
	tank.name = unit_name
	tank.position = position
	tank.add_to_group("units")
	tank.add_to_group("revealed_units")
	player.add_child(tank)
	return tank


func _check(condition: bool, message: String):
	if condition:
		return
	_failures += 1
	push_error("Tank force attack assertion failed: %s" % message)


## 在超时时间内等待目标生命值降低，避免武器冷却和投射物飞行时间使测试误判。
func _wait_for_hp_below(unit, previous_hp: float, timeout_seconds: float) -> bool:
	var elapsed_seconds := 0.0
	while elapsed_seconds < timeout_seconds:
		if not is_instance_valid(unit) or unit.hp < previous_hp:
			return true
		await get_tree().create_timer(0.1).timeout
		elapsed_seconds += 0.1
	return not is_instance_valid(unit) or unit.hp < previous_hp


## 收集 ForceAttack 测试所需的权威订单状态事件。
func _on_order_state_changed(
	order_id: String,
	command_id: String,
	unit_id: String,
	kind: String,
	previous_state: String,
	current_state: String,
	replaced_by_command_id: String
):
	_order_events.append({
		"order_id": order_id,
		"command_id": command_id,
		"unit_id": unit_id,
		"kind": kind,
		"previous_state": previous_state,
		"current_state": current_state,
		"replaced_by_command_id": replaced_by_command_id,
	})


## 按订单 ID 提取状态序列，忽略同场景其他订单事件。
func _states_for_order(order_id: String) -> Array[String]:
	var states: Array[String] = []
	for event in _order_events:
		if event["order_id"] == order_id:
			states.append(event["current_state"])
	return states
