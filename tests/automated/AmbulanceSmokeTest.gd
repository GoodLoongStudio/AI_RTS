extends Node

## 救护车冒烟测试（2026-09-11）：
## 受伤单位停在救护车 3 米内 → 自动回血并扣资金；远离后停止治疗。

const MatchScene = preload("res://tests/manual/TestAllUnits.tscn")
const AmbulanceScene = preload("res://source/match/units/Ambulance.tscn")
const TankScene = preload("res://source/match/units/Tank.tscn")

var _failures := 0


func _ready():
	get_tree().create_timer(60.0).timeout.connect(_on_failsafe)
	var match_instance = MatchScene.instantiate()
	add_child(match_instance)
	await get_tree().process_frame
	await get_tree().create_timer(0.5).timeout

	var human = match_instance.get_node("Players/Human")
	# 经济账户异步就绪后再注入测试资金
	var waited := 0.0
	while waited < 10.0 and human.get("_economy_runtime") == null:
		await get_tree().create_timer(0.2).timeout
		waited += 0.2
	human.add_resources({"resource_a": 5000}, "ScriptedAdjustment")

	var ambulance = AmbulanceScene.instantiate()
	MatchSignals.setup_and_spawn_unit.emit(
		ambulance, Transform3D(Basis.IDENTITY, Vector3(10, 0, 10)), human, false
	)
	var wounded_tank = TankScene.instantiate()
	MatchSignals.setup_and_spawn_unit.emit(
		wounded_tank, Transform3D(Basis.IDENTITY, Vector3(11, 0, 10)), human, false
	)
	await get_tree().process_frame
	await get_tree().create_timer(0.5).timeout

	wounded_tank.set_hp_without_damage(wounded_tank.hp_max * 0.5)
	var damaged_hp: float = wounded_tank.hp
	var funds_before: int = human.resource_a

	var heal_waited := 0.0
	while wounded_tank.hp < wounded_tank.hp_max and heal_waited < 10.0:
		await get_tree().create_timer(0.25).timeout
		heal_waited += 0.25
	_check(wounded_tank.hp > damaged_hp, "救护车应治疗 3 米内受伤友军（%s → %s）" % [damaged_hp, wounded_tank.hp])
	_check(human.resource_a < funds_before, "治疗应扣资金（%s → %s）" % [funds_before, human.resource_a])

	# 拉开距离后应停止治疗
	wounded_tank.set_hp_without_damage(wounded_tank.hp_max * 0.5)
	wounded_tank.global_position = Vector3(20, 0, 20)
	await get_tree().create_timer(2.0).timeout
	_check(
		abs(wounded_tank.hp - wounded_tank.hp_max * 0.5) < 0.01,
		"远离救护车后应停止治疗（hp=%s）" % wounded_tank.hp
	)

	print("Ambulance smoke test completed: %d failure(s)" % _failures)
	SmokeTestExit.request(get_tree(), 0 if _failures == 0 else 1)


func _on_failsafe():
	print("FAIL: 看门狗超时——测试协程中断未收尾")
	print("Ambulance smoke test completed: %d failure(s)" % _failures)
	SmokeTestExit.request(get_tree(), 1)

func _check(condition: bool, message: String):
	if condition:
		return
	_failures += 1
	print("FAIL: %s" % message)
	push_error("Ambulance smoke test assertion failed: %s" % message)
