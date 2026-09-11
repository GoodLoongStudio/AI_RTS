extends Node

## 运输车冒烟测试（2026-09-11 晚，用户指定 SM_Veh_Apc_01 模型 / 载员 10 / 无武器 / 车厂生产）：
## 车厂生产 → 部署可选中、货舱容量 10 → 自动装载附近步兵 → 卸载恢复 → 致死正常清理。

const MatchScene = preload("res://tests/manual/TestAllUnits.tscn")
const TransportTruckScene = preload("res://source/match/units/TransportTruck.tscn")
const InfantryScene = preload("res://source/match/units/Infantry.tscn")

const PRODUCE_TIMEOUT_SECONDS := 40.0
const WAIT_SECONDS := 90.0

var _failures := 0
var _finished := false
var _produced: Array = []


func _ready():
	get_tree().create_timer(WAIT_SECONDS + 30.0).timeout.connect(_on_failsafe)
	MatchSignals.unit_production_finished.connect(_on_unit_production_finished)
	var match_instance = MatchScene.instantiate()
	add_child(match_instance)
	await get_tree().process_frame
	await get_tree().process_frame

	var human = match_instance.get_node("Players/Human")
	var vehicle_factory = human.get_node("VehicleFactory")
	var queue = vehicle_factory.production_queue

	# 权威经济账户异步就绪：轮询注入
	var resources_ready := false
	var waited := 0.0
	while not resources_ready and waited < 10.0:
		if human.get("_economy_runtime") != null:
			resources_ready = human.add_resources({"resource_a": 2000}, "ScriptedAdjustment")
		if not resources_ready:
			await get_tree().create_timer(0.2).timeout
			waited += 0.2
	_check(resources_ready, "权威经济账户应在 10s 内就绪以注入测试资源")

	# 1) 车厂生产运输车
	var item = queue.produce(TransportTruckScene)
	_check(item != null, "车厂应可入队生产运输车")
	var elapsed := 0.0
	while _produced.is_empty() and elapsed < PRODUCE_TIMEOUT_SECONDS:
		await get_tree().create_timer(0.2).timeout
		elapsed += 0.2
	_check(
		_produced.size() == 1,
		"运输车应在 %.0fs 内从车厂部署（实际 %d 个）" % [PRODUCE_TIMEOUT_SECONDS, _produced.size()]
	)
	if _produced.is_empty():
		_finish()
		return
	var truck = _produced[0]

	# 2) 部署后：编组/特性/可选中/货舱容量 10
	_check(truck.is_in_group("controlled_units"), "部署的运输车应编入 controlled_units 组")
	var selection = truck.find_child("Selection", true, false)
	_check(selection != null and selection.has_method("select"), "运输车必须带 Selection 特性")
	_check(truck.find_child("Highlight", true, false) != null, "运输车必须带 Highlight 特性")
	var cargo = truck.find_child("CargoHold", true, false)
	_check(cargo != null, "运输车必须带 CargoHold 特性")
	if selection != null and selection.has_method("select"):
		selection.select()
	if cargo == null:
		_finish()
		return

	# 3) 自动装载：2 名步兵停在车旁 → 装满检测用货舱容量断言
	var infantry_a = InfantryScene.instantiate()
	MatchSignals.setup_and_spawn_unit.emit(
		infantry_a, Transform3D(Basis.IDENTITY, Vector3(10.5, 0, 10.5)), human, false
	)
	var infantry_b = InfantryScene.instantiate()
	MatchSignals.setup_and_spawn_unit.emit(
		infantry_b, Transform3D(Basis.IDENTITY, Vector3(9.6, 0, 10.4)), human, false
	)
	# 运输车部署位与步兵错开，把车挪到步兵旁边（直接瞬移，冻结移动）
	var truck_movement = truck.find_child("Movement", true, false)
	if truck_movement != null:
		truck_movement.set_physics_process(false)
	truck.global_position = Vector3(10, 0, 10)
	var load_waited := 0.0
	while cargo.get_passenger_count() < 2 and load_waited < 12.0:
		await get_tree().create_timer(0.25).timeout
		load_waited += 0.25
	_check(
		cargo.get_passenger_count() == 2,
		"运输车应自动装载 2 名附近步兵（实际 %d）" % cargo.get_passenger_count()
	)
	_check(not infantry_a.visible, "装载后步兵应隐藏")

	# 4) 卸载恢复
	cargo.unload_all()
	await get_tree().process_frame
	_check(cargo.get_passenger_count() == 0, "卸载后货舱应为空")
	_check(is_instance_valid(infantry_a) and infantry_a.visible, "卸载后步兵应恢复可见")

	# 5) 致死伤害正常清理
	truck.hp = 0
	var removal_waited := 0.0
	while is_instance_valid(truck) and removal_waited < 10.0:
		await get_tree().create_timer(0.2).timeout
		removal_waited += 0.2
	_check(not is_instance_valid(truck), "运输车致死伤害后应在 10s 内完成死亡清理")

	_finish()


func _on_unit_production_finished(unit, producer):
	if producer.name == "VehicleFactory" and unit.scene_file_path == TransportTruckScene.resource_path:
		_produced.append(unit)


func _on_failsafe():
	if _finished:
		return
	_finished = true
	print("FAIL: 看门狗超时——测试协程中断未收尾")
	print("Transport truck smoke test completed: %d failure(s)" % _failures)
	SmokeTestExit.request(get_tree(), 1)


func _finish():
	if _finished:
		return
	_finished = true
	print("Transport truck smoke test completed: %d failure(s)" % _failures)
	SmokeTestExit.request(get_tree(), 0 if _failures == 0 else 1)


func _check(condition: bool, message: String):
	if condition:
		return
	_failures += 1
	print("FAIL: %s" % message)
	push_error("Transport truck smoke test assertion failed: %s" % message)
