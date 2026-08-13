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
	await get_tree().create_timer(0.2).timeout
	_check(friendly_target.hp < friendly_hp_before, "显式攻击己方目标应造成完整基础伤害")
	_check(gateway.GetFirePolicy(attacker) == "HoldFire", "临时授权不得修改持久停火策略")

	var hp_before_stop: float = friendly_target.hp
	controller.halt_selected_units()  # 未选择单位时不应影响当前 ForceAttack。
	await get_tree().create_timer(0.1).timeout
	_check(gateway.GetOrderState(friendly_order_id) == "InProgress", "空 Selection 停止不应取消攻击")
	attacker.find_child("Selection").select()
	controller.halt_selected_units()
	await get_tree().create_timer(0.9).timeout
	_check(gateway.GetOrderState(friendly_order_id) == "Cancelled", "停止应取消显式 ForceAttack 订单")
	_check(friendly_target.hp == hp_before_stop, "停止后不应继续对显式目标造成伤害")
	_check(gateway.GetFirePolicy(attacker) == "HoldFire", "停止后应恢复原持久停火策略")

	var enemy_hp_before: float = enemy_target.hp
	MatchSignals.unit_targeted.emit(enemy_target)
	await get_tree().create_timer(0.3).timeout
	_check(enemy_target.hp == enemy_hp_before, "HoldFire 下普通右键敌人不应绕过停火")

	enemy_target.hp = 2
	var enemy_result = gateway.ForceAttackUnits([attacker], enemy_target, human)
	var enemy_order_id: String = enemy_result["unit_results"][0]["order_id"]
	await get_tree().create_timer(0.3).timeout
	_check(not is_instance_valid(enemy_target) or enemy_target.hp == 0, "显式攻击应能摧毁敌方目标")
	_check(gateway.GetOrderState(enemy_order_id) == "TargetLost", "目标死亡后订单应进入 TargetLost")
	_check(
		_states_for_order(enemy_order_id) == ["Accepted", "InProgress", "TargetLost"],
		"目标死亡应通过统一订单事件发布 TargetLost"
	)

	var ground_result = gateway.ForceAttackGround([attacker], attacker.global_position, human)
	_check(ground_result["status"] == "Rejected", "当前 Tank 地面强制攻击应稳定拒绝")
	_check(
		ground_result["unit_results"][0]["error_code"] == "WeaponCannotForceFire",
		"地面强制攻击应返回 WeaponCannotForceFire"
	)

	print("Tank force attack smoke test completed: %d failure(s)" % _failures)
	match_instance.queue_free()
	await get_tree().process_frame
	get_tree().quit(0 if _failures == 0 else 1)


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
