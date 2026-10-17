extends Node

## 主基地不再生产矿车（balance: worker.allowedProducerUnitTypeIds = [vehicle_factory]）。
## 入队必须被权威拒绝。车厂能产出矿车由 VehicleFactoryWorkerProductionSmokeTest 覆盖。

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
	var command_center = human.get_node("CommandCenter")
	var queue = command_center.production_queue

	# 权威经济账户在 Match 就绪后异步配置：轮询注入成功为止
	var resources_ready := false
	var waited := 0.0
	while not resources_ready and waited < 10.0:
		resources_ready = human.add_resources({"resource_a": 1000}, "ScriptedAdjustment")
		if not resources_ready:
			await get_tree().create_timer(0.2).timeout
			waited += 0.2
	_check(resources_ready, "权威经济账户应在 10s 内就绪以注入测试资源")

	var item = queue.produce(WorkerScene)
	_check(item == null, "主基地入队矿车应被拒绝")
	_check(_produced_workers.is_empty(), "主基地不应部署矿车")

	print("Command center worker production smoke test completed: %d failure(s)" % _failures)
	match_instance.queue_free()
	await get_tree().process_frame
	SmokeTestExit.request(get_tree(), 0 if _failures == 0 else 1)


func _on_unit_production_finished(unit, producer):
	if producer.name == "CommandCenter" and unit.scene_file_path == WorkerScene.resource_path:
		_produced_workers.append(unit)


func _check(condition: bool, message: String):
	if condition:
		return
	_failures += 1
	print("FAIL: %s" % message)
	push_error("Command center worker production assertion failed: %s" % message)
