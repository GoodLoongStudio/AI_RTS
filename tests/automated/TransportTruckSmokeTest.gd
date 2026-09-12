extends Node

## 运输车冒烟测试（2026-09-11 深夜，用户指定交互）：
## 车厂生产 → 选中士兵右键运输车（标记登车）→ 步兵 3 米内上车（容量 10 上限）
## → 侧栏卸货按钮卸载 → 致死正常清理。未标记登车的步兵不得自动装载。

const MatchScene = preload("res://tests/manual/TestAllUnits.tscn")
const TransportTruckScene = preload("res://source/match/units/TransportTruck.tscn")
const InfantryScene = preload("res://source/match/units/Infantry.tscn")

const PRODUCE_TIMEOUT_SECONDS := 40.0
const WAIT_SECONDS := 120.0

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

	# 2) 部署后：编组/特性/可选中/货舱
	_check(truck.is_in_group("controlled_units"), "部署的运输车应编入 controlled_units 组")
	var selection = truck.find_child("Selection", true, false)
	_check(selection != null and selection.has_method("select"), "运输车必须带 Selection 特性")
	var cargo = truck.find_child("CargoHold", true, false)
	_check(cargo != null, "运输车必须带 CargoHold 特性")
	if selection != null and selection.has_method("select"):
		selection.select()
	if cargo == null:
		_finish()
		return

	# 冻结运输车移动并挪到测试位（装载阶段车必须原地待命）
	var truck_movement = truck.find_child("Movement", true, false)
	if truck_movement != null:
		truck_movement.set_physics_process(false)
	truck.global_position = Vector3(12, 0, 10)

	# 3) 未标记登车的步兵不得自动装载（用户明确要求非自动）
	var bystander = InfantryScene.instantiate()
	MatchSignals.setup_and_spawn_unit.emit(
		bystander, Transform3D(Basis.IDENTITY, Vector3(10.5, 0, 10.5)), human, false
	)
	await get_tree().create_timer(1.5).timeout
	_check(cargo.get_passenger_count() == 0, "未标记登车的步兵不应被自动装载")
	_check(bystander.visible, "未登车步兵应保持可见")

	# 4) 模拟"选中士兵右键运输车"：标记登车（与 UnitActionsController 登车令同路径）+ 士兵在 3 米内
	var soldiers: Array = []
	for i in range(12):
		var soldier = InfantryScene.instantiate()
		var angle = i * 0.6
		var offset = Vector3(sin(angle) * 0.3, 0, cos(angle) * 0.3)
		MatchSignals.setup_and_spawn_unit.emit(
			soldier, Transform3D(Basis.IDENTITY, Vector3(12, 0, 10) + offset), human, false
		)
		soldiers.append(soldier)
	await get_tree().process_frame
	await get_tree().create_timer(0.5).timeout
	for soldier in soldiers:
		if is_instance_valid(soldier):
			cargo.mark_boarding(soldier)
	var load_waited := 0.0
	while cargo.get_passenger_count() < 10 and load_waited < 25.0:
		await get_tree().create_timer(0.25).timeout
		load_waited += 0.25
	_check(
		cargo.get_passenger_count() == 10,
		"登车步兵应在 25s 内上车且不超过容量 10（实际 %d）" % cargo.get_passenger_count()
	)
	var hidden_count := 0
	for soldier in soldiers:
		if is_instance_valid(soldier):
			# 注意：不能写 get_meta(key, null)（Godot 4.7 视为"未给默认值"→ 每次调用报错）
			var meta = (
				soldier.get_meta("boarding_transport")
				if soldier.has_meta("boarding_transport")
				else null
			)
			print("[TT-DBG] %s visible=%s meta=%s pos=%s" % [soldier.name, soldier.visible, "有" if meta != null else "无", str(soldier.global_position)])
			if soldier.global_position.y < -10 or not soldier.visible:
				hidden_count += 1
	_check(hidden_count == 10, "上车的 10 名步兵应全部隐藏（实际 %d）" % hidden_count)
	_check(bystander.visible, "未登车的旁观步兵不应被装载")

	# 5) 卸货：全部恢复可见并散开落位
	cargo.unload_all()
	await get_tree().process_frame
	_check(cargo.get_passenger_count() == 0, "卸货后货舱应为空")
	var restored := 0
	for soldier in soldiers:
		if is_instance_valid(soldier) and soldier.visible and soldier.global_position.y > -10:
			restored += 1
	_check(restored == 12, "卸货后场上步兵应全部在场可见（实际 %d/12）" % restored)

	# 6) 致死伤害正常清理
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
