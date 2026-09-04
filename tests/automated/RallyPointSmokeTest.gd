extends Node

const MatchScene = preload("res://tests/manual/TestAllUnits.tscn")
const WorkerScene = preload("res://source/match/units/Worker.tscn")
const DroneScene = preload("res://source/match/units/Drone.tscn")

var _failures := 0
var _produced_worker = null
var _produced_drone = null
var _order_events: Array[Dictionary] = []


## 验证每 Producer 独立集结、策略继承、事件驱动分派、Clear 和目标失效回门口。
func _ready():
	MatchSignals.unit_production_finished.connect(_on_unit_production_finished)
	var match_instance = MatchScene.instantiate()
	add_child(match_instance)
	await get_tree().process_frame
	await get_tree().process_frame

	var human = match_instance.get_node("Players/Human")
	var command_center = human.get_node("CommandCenter")
	var aircraft_factory = human.get_node("AircraftFactory")
	var vehicle_factory = human.get_node("VehicleFactory")
	var rally = match_instance.get_node("RallyPointRuntime")
	var gateway = human.get_node("UnitCommandGateway")
	var first_position := Vector3(12, 0, 15)
	var second_position := Vector3(18, 0, 17)
	match_instance.get_node("CommandRuntime").connect("OrderStateChanged", _on_order_state_changed)

	_check(
		rally.SetPosition([command_center], first_position, human)["status"] == "Accepted",
		"CommandCenter 位置集结命令应被接受"
	)
	_check(
		rally.SetPosition([vehicle_factory], second_position, human)["status"] == "Accepted",
		"VehicleFactory 位置集结命令应被接受"
	)
	_check(
		rally.GetSnapshot(command_center)["position"].is_equal_approx(first_position),
		"CommandCenter 应保存自己的集结位置"
	)
	_check(
		rally.GetSnapshot(vehicle_factory)["position"].is_equal_approx(second_position),
		"不同建筑的集结状态不得相互覆盖"
	)

	_check(
		gateway.SetEngagementStance([command_center], "HoldGround", human)["status"] == "Accepted",
		"无武器生产建筑应能保存出厂默认姿态"
	)
	_check(
		gateway.SetFirePolicy([command_center], "HoldFire", human)["status"] == "Accepted",
		"无武器生产建筑应能保存出厂默认开火策略"
	)
	human.add_resources({"resource_a": 10}, "ScriptedAdjustment")
	_check(command_center.production_queue.produce(WorkerScene) != null, "Worker 应成功入队")

	var elapsed_seconds := 0.0
	while _produced_worker == null and elapsed_seconds < 12.0:
		await get_tree().create_timer(0.1).timeout
		elapsed_seconds += 0.1
	_check(_produced_worker != null, "Worker 应在有限时间内完成部署")
	if _produced_worker != null:
		_check(
			gateway.GetEngagementStance(_produced_worker) == "HoldGround",
			"出厂单位应继承 Producer 最新交战姿态"
		)
		_check(
			gateway.GetFirePolicy(_produced_worker) == "HoldFire",
			"出厂单位应继承 Producer 最新开火策略"
		)
		_check(_produced_worker.action != null, "位置集结应为新单位分派一次移动任务")

	_check(rally.Clear([command_center], human)["status"] == "Accepted", "显式 Clear 应接受")
	_check(rally.GetSnapshot(command_center).is_empty(), "Clear 后应回归默认门口")
	_check(
		not rally.GetSnapshot(vehicle_factory).is_empty(),
		"清除一座建筑不得影响另一座建筑"
	)

	var resource = match_instance.get_node("Map/Resources/ResourceA15")
	_check(
		rally.SetTarget([command_center], resource, human)["status"] == "Accepted",
		"可观察资源节点应能成为集结目标"
	)
	_check(rally.GetSnapshot(command_center)["kind"] == "Resource", "资源目标应保持强类型")
	_check(
		rally.SetTarget([aircraft_factory], resource, human)["status"] == "Accepted",
		"AircraftFactory 应能保存资源实体集结目标"
	)
	human.add_resources({"resource_a": 10}, "ScriptedAdjustment")
	_check(aircraft_factory.production_queue.produce(DroneScene) != null, "Drone 应成功入队")
	elapsed_seconds = 0.0
	while _produced_drone == null and elapsed_seconds < 12.0:
		await get_tree().create_timer(0.1).timeout
		elapsed_seconds += 0.1
	_check(_produced_drone != null, "Drone 应在有限时间内完成部署")
	if _produced_drone != null:
		elapsed_seconds = 0.0
		while not _has_order_kind(_produced_drone, "ApproachEntity") and elapsed_seconds < 1.0:
			await get_tree().process_frame
			elapsed_seconds += get_process_delta_time()
		_check(
			_has_order_kind(_produced_drone, "ApproachEntity"),
			"非 Worker 资源集结应提交公共 ApproachEntity，而非由 Rally 直接写 Action"
		)
	resource.queue_free()
	await get_tree().process_frame
	await get_tree().process_frame
	_check(rally.GetSnapshot(command_center).is_empty(), "目标失效后应回归默认门口")

	print("Rally point smoke test completed: %d failure(s)" % _failures)
	match_instance.queue_free()
	await get_tree().process_frame
	SmokeTestExit.request(get_tree(), 0 if _failures == 0 else 1)


## 捕获 CommandCenter 实际完成部署的 Worker。
func _on_unit_production_finished(unit, producer):
	if producer.name == "CommandCenter":
		_produced_worker = unit
	elif producer.name == "AircraftFactory":
		_produced_drone = unit


## 收集 Match 级权威订单事件，验证 Rally 分派没有绕过公共命令。
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


## 判断指定单位是否发布过目标种类的权威订单。
func _has_order_kind(unit: Node, kind: String) -> bool:
	if not unit.has_meta("ai_rts_unit_id"):
		return false
	var unit_id := str(unit.get_meta("ai_rts_unit_id"))
	for event in _order_events:
		if event["unit_id"] == unit_id and event["kind"] == kind:
			return true
	return false


## 累计断言失败并继续执行其余检查。
func _check(condition: bool, message: String):
	if condition:
		return
	_failures += 1
	push_error("Rally point assertion failed: %s" % message)
