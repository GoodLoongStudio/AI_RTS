extends Node

const MatchScene = preload("res://tests/manual/TestOneUnit.tscn")
const TankScene = preload("res://source/match/units/Tank.tscn")
const Player = preload("res://source/match/players/Player.gd")
const OrdinaryAttacking = preload(
	"res://source/match/units/actions/OrdinaryAttacking.gd"
)

var _failures := 0


func _ready():
	var match_instance = MatchScene.instantiate()
	add_child(match_instance)
	await get_tree().process_frame
	await get_tree().process_frame

	var human = match_instance.get_node("Players/Human")
	var attacker = human.get_node("Tank")
	var gateway = human.get_node("UnitCommandGateway")
	var enemy_player = _add_enemy_player(match_instance)
	var enemy = _add_tank(enemy_player, "OrdinaryAttackTarget", attacker.position + Vector3(3, 0, 0))
	var friendly = _add_tank(human, "FriendlyTarget", attacker.position + Vector3(-3, 0, 0))
	gateway.SetFirePolicy([enemy], "HoldFire", enemy_player)

	gateway.SetFirePolicy([attacker], "HoldFire", human)
	var rejected = gateway.AttackUnits([attacker], enemy, human)
	_check(rejected["status"] == "Rejected", "HoldFire 下普通攻击应拒绝")
	_check(
		rejected["unit_results"][0]["error_code"] == "FirePolicyPreventsAttack",
		"HoldFire 应返回稳定拒绝原因"
	)
	var friendly_result = gateway.AttackUnits([attacker], friendly, human)
	_check(friendly_result["status"] == "Rejected", "普通攻击不应接受己方目标")

	gateway.SetFirePolicy([attacker], "FireAtWill", human)
	var hp_before: float = enemy.hp
	var accepted = gateway.AttackUnits([attacker], enemy, human)
	var order_id: String = accepted["unit_results"][0]["order_id"]
	_check(accepted["status"] == "Accepted", "普通敌方攻击应被接受")
	_check(
		attacker.action != null and attacker.action.get_script() == OrdinaryAttacking,
		"普通攻击应进入独立 OrdinaryAttacking 行为"
	)
	var stop_result = gateway.StopUnits([attacker], human)
	_check(stop_result["status"] == "Accepted", "普通 Attack 期间统一 Stop 应作为幂等意图接收")
	_check(gateway.GetOrderState(order_id) == "InProgress", "统一 Stop 不应停止普通 Attack 订单")
	_check(
		attacker.action != null and attacker.action.get_script() == OrdinaryAttacking,
		"统一 Stop 不应清除普通 Attack 执行动作"
	)
	await get_tree().create_timer(0.8).timeout
	_check(enemy.hp < hp_before, "普通攻击应对敌方目标造成伤害")
	enemy.hp = 0
	await get_tree().create_timer(0.15).timeout
	_check(gateway.GetOrderState(order_id) == "TargetLost", "目标死亡后订单应进入 TargetLost")

	print("Tank ordinary attack smoke test completed: %d failure(s)" % _failures)
	match_instance.queue_free()
	await get_tree().process_frame
	get_tree().quit(0 if _failures == 0 else 1)


func _add_enemy_player(match_instance):
	var enemy_player := Node3D.new()
	enemy_player.name = "OrdinaryAttackEnemy"
	enemy_player.set_script(Player)
	enemy_player.color = Color.RED
	enemy_player.add_to_group("players")
	match_instance.get_node("Players").add_child(enemy_player)
	return enemy_player


func _add_tank(player, unit_name: String, position: Vector3):
	var unit = TankScene.instantiate()
	unit.name = unit_name
	unit.position = position
	unit.add_to_group("units")
	player.add_child(unit)
	return unit


func _check(condition: bool, message: String):
	if condition:
		return
	_failures += 1
	push_error("Tank ordinary attack assertion failed: %s" % message)
