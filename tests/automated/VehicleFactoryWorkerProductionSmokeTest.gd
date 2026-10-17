extends Node

## 车厂生产矿车冒烟测试（2026-09-28 红警2 口径，原「主基地生产工人」用例改写）：
## balance: worker.allowedProducerUnitTypeIds = [vehicle_factory]——
## ① 车厂能入队并真的产出矿车（开局零矿车后的唯一稳定产能入口）；
## ② 主基地入队矿车被权威拒绝（旧口径回收，ProductionService 校验 allowedProducer）。

const MatchScene = preload("res://tests/manual/TestAllUnits.tscn")
const WorkerScene = preload("res://source/match/units/Worker.tscn")

const PRODUCE_TIMEOUT_SECONDS := 30.0

var _failures := 0
var _produced_workers := []


func _ready():
	MatchSignals.unit_production_finished.connect(_on_unit_production_finished)
	var match_instance = MatchScene.instantiate()
	add_child(match_instance)
	await get_tree().process_frame
	await get_tree().process_frame

	var human = match_instance.get_node("Players/Human")
	var vehicle_factory = human.get_node("VehicleFactory")
	var command_center = human.get_node("CommandCenter")

	# 权威经济账户在 Match 就绪后异步配置：轮询注入成功为止
	# 等权威账户挂好再一次性注资：直接轮询 add_resources 会在就绪前反复触发
	# "resource account must be configured" 断言（属可避免的日志噪声）。
	var waited := 0.0
	while human.get("_economy_runtime") == null and waited < 10.0:
		await get_tree().create_timer(0.2).timeout
		waited += 0.2
	var resources_ready: bool = waited < 10.0 and human.add_resources(
		{"resource_a": 1000}, "ScriptedAdjustment"
	)
	_check(resources_ready, "权威经济账户应在 10s 内就绪以注入测试资源")

	# ② 旧口径回收：主基地不再是矿车的合法生产者（入队被权威拒绝 → produce 返回 null）。
	var cc_rejected = command_center.production_queue.produce(WorkerScene) == null
	_check(cc_rejected, "主基地入队矿车应被权威拒绝（生产者已改为车厂）")

	# ① 车厂生产矿车。
	var item = vehicle_factory.production_queue.produce(WorkerScene)
	_check(item != null, "车厂应可入队生产矿车")

	var elapsed := 0.0
	while _produced_workers.is_empty() and elapsed < PRODUCE_TIMEOUT_SECONDS:
		await get_tree().create_timer(0.2).timeout
		elapsed += 0.2
	_check(
		_produced_workers.size() == 1,
		"矿车应在 %.0fs 内从车厂部署（实际 %d 个）" % [PRODUCE_TIMEOUT_SECONDS, _produced_workers.size()]
	)
	if _produced_workers.size() == 1:
		_check(
			_produced_workers[0].scene_file_path == WorkerScene.resource_path,
			"部署的单位应是矿车（Worker）"
		)

	print("Vehicle factory worker production smoke test completed: %d failure(s)" % _failures)
	match_instance.queue_free()
	await get_tree().process_frame
	SmokeTestExit.request(get_tree(), 0 if _failures == 0 else 1)


func _on_unit_production_finished(unit, producer):
	if producer.name == "VehicleFactory" and unit.scene_file_path == WorkerScene.resource_path:
		_produced_workers.append(unit)


func _check(condition: bool, message: String):
	if condition:
		return
	_failures += 1
	print("FAIL: %s" % message)
	push_error("Vehicle factory worker production assertion failed: %s" % message)
