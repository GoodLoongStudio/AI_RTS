extends Node

## 运输货舱冒烟测试（2026-09-11）：
## 运输卡车空闲时自动装载 1.4 米内停稳的己方步兵；
## 卸载后步兵恢复可见/可选中并散开落位。

const MatchScene = preload("res://tests/manual/TestAllUnits.tscn")
const ArmyTruckScene = preload("res://source/match/units/ArmyTruck.tscn")
const InfantryScene = preload("res://source/match/units/Infantry.tscn")

var _failures := 0
var _finished := false


func _ready():
	get_tree().create_timer(60.0).timeout.connect(_on_failsafe)
	var match_instance = MatchScene.instantiate()
	add_child(match_instance)
	await get_tree().process_frame
	await get_tree().create_timer(0.5).timeout

	var human = match_instance.get_node("Players/Human")
	var truck = ArmyTruckScene.instantiate()
	MatchSignals.setup_and_spawn_unit.emit(
		truck, Transform3D(Basis.IDENTITY, Vector3(10, 0, 10)), human, false
	)
	var infantry_a = InfantryScene.instantiate()
	MatchSignals.setup_and_spawn_unit.emit(
		infantry_a, Transform3D(Basis.IDENTITY, Vector3(10.5, 0, 10.5)), human, false
	)
	var infantry_b = InfantryScene.instantiate()
	MatchSignals.setup_and_spawn_unit.emit(
		infantry_b, Transform3D(Basis.IDENTITY, Vector3(9.6, 0, 10.4)), human, false
	)
	await get_tree().process_frame
	await get_tree().create_timer(1.0).timeout

	var cargo = truck.find_child("CargoHold", true, false)
	_check(cargo != null, "运输卡车必须带 CargoHold 特性")
	if cargo == null:
		_finish()
		return

	# 自动装载（步兵生成后静止在 1.4 米内 → 应被自动收编）
	var waited := 0.0

	while cargo.get_passenger_count() < 2 and waited < 10.0:
		await get_tree().create_timer(0.25).timeout
		waited += 0.25
	_check(
		cargo.get_passenger_count() == 2,
		"运输卡车应自动装载 2 名附近步兵（实际 %d）" % cargo.get_passenger_count()
	)
	_check(not infantry_a.visible, "装载后乘客应隐藏（infantry_a）")
	_check(not infantry_b.visible, "装载后乘客应隐藏（infantry_b）")

	# 卸载：恢复可见并散开落位
	cargo.unload_all()
	await get_tree().process_frame
	_check(cargo.get_passenger_count() == 0, "卸载后货舱应为空")
	_check(is_instance_valid(infantry_a) and infantry_a.visible, "卸载后 infantry_a 应恢复可见")
	_check(is_instance_valid(infantry_b) and infantry_b.visible, "卸载后 infantry_b 应恢复可见")
	if is_instance_valid(infantry_a):
		_check(infantry_a.global_position.distance_to(truck.global_position) < 3.0, "卸载步兵应落在卡车附近")
		_check(infantry_a.get("_action_locked") == false, "卸载步兵应解除动作锁定")

	print("Transport cargo smoke test completed: %d failure(s)" % _failures)
	SmokeTestExit.request(get_tree(), 0 if _failures == 0 else 1)


func _on_failsafe():
	if _finished:
		return
	_finished = true
	print("FAIL: 看门狗超时——测试协程中断未收尾")
	print("Transport cargo smoke test completed: %d failure(s)" % _failures)
	SmokeTestExit.request(get_tree(), 1)

func _finish():
	if _finished:
		return
	_finished = true
	print("Transport cargo smoke test completed: %d failure(s)" % _failures)
	SmokeTestExit.request(get_tree(), 0 if _failures == 0 else 1)


func _check(condition: bool, message: String):
	if condition:
		return
	_failures += 1
	print("FAIL: %s" % message)
	push_error("Transport cargo smoke test assertion failed: %s" % message)
