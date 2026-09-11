extends Node

## APC 稳定性冒烟测试（2026-09-11）：
## 车厂生产 APC → 部署单位可选中、特性齐全 → 受致命伤害正常死亡释放。
## 目标：新单位与既有单位（工人/坦克）达到同等稳定性。

const MatchScene = preload("res://tests/manual/TestAllUnits.tscn")
const APCScene = preload("res://source/match/units/APC.tscn")

const PRODUCE_TIMEOUT_SECONDS := 40.0
const WAIT_SECONDS := 90.0

var _failures := 0
var _finished := false
var _produced_apcs: Array = []


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

	# 1) 车厂生产 APC
	var item = queue.produce(APCScene)
	_check(item != null, "车厂应可入队生产装甲车")

	var elapsed := 0.0
	while _produced_apcs.is_empty() and elapsed < PRODUCE_TIMEOUT_SECONDS:
		await get_tree().create_timer(0.2).timeout
		elapsed += 0.2
	_check(
		_produced_apcs.size() == 1,
		"APC 应在 %.0fs 内从车厂部署（实际 %d 个）" % [PRODUCE_TIMEOUT_SECONDS, _produced_apcs.size()]
	)
	if _produced_apcs.is_empty():
		_finish()
		return
	var apc = _produced_apcs[0]

	# 2) 部署后的单位：编入受控组、特性齐全、可选中
	_check(apc.is_in_group("controlled_units"), "部署的 APC 应编入 controlled_units 组")
	var selection = apc.find_child("Selection", true, false)
	_check(selection != null and selection.has_method("select"), "APC 必须带 Selection 特性")
	_check(apc.find_child("Highlight", true, false) != null, "APC 必须带 Highlight 特性")
	_check(apc.find_child("Movement", true, false) != null, "APC 必须带 Movement 特性")
	if selection != null and selection.has_method("select"):
		selection.select()

	# 3) 受致命伤害正常死亡并释放
	apc.hp = 0
	var removal_waited := 0.0
	while is_instance_valid(apc) and removal_waited < 10.0:
		await get_tree().create_timer(0.2).timeout
		removal_waited += 0.2
	_check(
		not is_instance_valid(apc),
		"APC 致死伤害后应在 10s 内完成死亡清理（实际 %s）"
		% ("仍存活" if is_instance_valid(apc) else "已释放")
	)

	# 4) 连续生产不破坏队列（第二辆）
	var item2 = vehicle_factory.production_queue.produce(APCScene)
	_check(item2 != null, "出售/死亡后车厂应能继续生产装甲车")
	await get_tree().create_timer(1.0).timeout

	_finish()


func _on_unit_production_finished(unit, producer):
	if producer.name == "VehicleFactory" and unit.scene_file_path == APCScene.resource_path:
		_produced_apcs.append(unit)


func _on_failsafe():
	if _finished:
		return
	print("FAIL: 看门狗超时——测试协程中断未收尾")
	_finish()


func _finish():
	if _finished:
		return
	_finished = true
	print("APC stability smoke test completed: %d failure(s)" % _failures)
	SmokeTestExit.request(get_tree(), 0 if _failures == 0 else 1)


func _check(condition: bool, message: String):
	if condition:
		return
	_failures += 1
	print("FAIL: %s" % message)
	push_error("APC stability smoke test assertion failed: %s" % message)
