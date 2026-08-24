extends Node

const MatchScene = preload("res://tests/manual/TestAllUnits.tscn")
const WorkerScene = preload("res://source/match/units/Worker.tscn")
const GatherAction = preload(
	"res://source/match/units/actions/CollectingResourcesSequentially.gd"
)

var _failures := 0
var _order_events: Array[Dictionary] = []
var _feedback_events: Array[Dictionary] = []


## 验证 Worker Gather 公共订单、仅交付入账、Stop 暂停和耗尽后待机。
func _ready():
	var match_instance = MatchScene.instantiate()
	add_child(match_instance)
	await get_tree().process_frame
	await get_tree().process_frame

	var human = match_instance.get_node("Players/Human")
	var worker = human.get_node("Worker")
	var resource = match_instance.get_node("Map/Resources/ResourceB5")
	var gateway = human.get_node("UnitCommandGateway")
	var controller = human.get_node("UnitActionsController")
	match_instance.get_node("CommandRuntime").connect("OrderStateChanged", _on_order_state_changed)
	controller.command_feedback.connect(_on_command_feedback)
	var player_resources_before: int = human.resource_b

	MatchSignals.deselect_all_units.emit()
	worker.find_child("Selection").select()
	MatchSignals.unit_targeted.emit(resource, resource.global_position)
	await get_tree().process_frame
	var first_order_id := _latest_order_id(worker, "Gather")
	_check(not first_order_id.is_empty(), "Worker 右键资源点应创建 Gather 订单")
	_check(gateway.GetActiveOrderState(worker) == "InProgress", "Gather 订单应进入 InProgress")
	_check(
		worker.action != null and worker.action.get_script() == GatherAction,
		"Worker 应通过 Legacy 适配执行采集组合 Action"
	)
	_check(_last_feedback_status("Gather") == "Accepted", "Gather 应提供 Accepted 即时反馈")

	_check(await _wait_for_worker_cargo(worker, 1, 5.0), "Worker 应从目标资源点取得第一份载荷")
	_check(human.resource_b == player_resources_before, "未返回 CommandCenter 前玩家资源不得增长")
	controller.stop_selected_units()
	await get_tree().process_frame
	_check(gateway.GetOrderState(first_order_id) == "Suspended", "Stop 应暂停并保留 Gather 订单")
	_check(
		worker.action != null and worker.action.is_task_suspended(),
		"Stop 应暂停整个采集 Action，而不是只清零一帧速度"
	)
	var cargo_while_suspended: int = worker.resource_b
	var resource_while_suspended: int = resource.resource_b
	var position_while_suspended: Vector3 = worker.global_position
	await get_tree().create_timer(2.3).timeout
	_check(worker.resource_b == cargo_while_suspended, "暂停期间 Worker 载荷不得继续增长")
	_check(resource.resource_b == resource_while_suspended, "暂停期间资源节点不得继续减少")
	_check(human.resource_b == player_resources_before, "暂停期间不得发生隐藏交付")
	_check(
		worker.global_position.distance_to(position_while_suspended) < 0.03,
		"暂停期间 Worker 不得自动恢复移动"
	)

	MatchSignals.unit_targeted.emit(resource, resource.global_position)
	await get_tree().process_frame
	var second_order_id := _latest_order_id(worker, "Gather")
	_check(second_order_id != first_order_id, "再次右键资源点应创建新的 Gather 订单")
	_check(gateway.GetOrderState(first_order_id) == "Cancelled", "新 Gather 应取消旧暂停订单")
	_check(gateway.GetOrderState(second_order_id) == "InProgress", "新 Gather 应恢复工作循环")

	_check(
		await _wait_for_player_resource(human, player_resources_before + 2, 10.0),
		"资源耗尽后 Worker 应完成最后一次交付，玩家资源增加两点"
	)
	await get_tree().process_frame
	_check(worker.resource_b == 0, "交付完成后 Worker 携带资源应清零")
	_check(gateway.GetOrderState(second_order_id) == "Completed", "耗尽后的最后交付应完成订单")
	await get_tree().create_timer(0.5).timeout
	_check(worker.action == null, "资源耗尽并交付后 Worker 应待机，不得自动寻找新矿")

	var loss_resource = match_instance.get_node("Map/Resources/ResourceA13")
	var loss_worker = WorkerScene.instantiate()
	loss_worker.name = "CargoLossWorker"
	loss_worker.position = loss_resource.position + Vector3(1.2, 0.0, 0.0)
	loss_worker.add_to_group("units")
	loss_worker.add_to_group("controlled_units")
	loss_worker.add_to_group("revealed_units")
	human.add_child(loss_worker)
	await get_tree().process_frame
	var player_resource_a_before: int = human.resource_a
	var loss_result = gateway.GatherResources([loss_worker], loss_resource, human)
	var loss_order_id: String = loss_result["unit_results"][0]["order_id"]
	_check(loss_result["status"] == "Accepted", "载荷丢失测试 Worker 应接受 Gather")
	_check(
		await _wait_for_worker_resource_a(loss_worker, 1, 4.0),
		"载荷丢失测试 Worker 应先取得未交付资源"
	)
	_check(human.resource_a == player_resource_a_before, "Worker 携带资源时玩家账户不得提前增长")
	loss_worker.hp = 0
	await get_tree().process_frame
	await get_tree().process_frame
	_check(human.resource_a == player_resource_a_before, "Worker 返程前死亡时未交付载荷应丢失")
	_check(gateway.GetOrderState(loss_order_id) == "UnitLost", "携带资源的 Worker 死亡后订单应进入 UnitLost")

	print("Worker Gather smoke test completed: %d failure(s)" % _failures)
	match_instance.queue_free()
	await get_tree().process_frame
	SmokeTestExit.request(get_tree(), 0 if _failures == 0 else 1)


## 等待 Worker 携带量达到指定值。
func _wait_for_worker_cargo(worker, expected: int, timeout_seconds: float) -> bool:
	var elapsed_seconds := 0.0
	while elapsed_seconds < timeout_seconds:
		if worker.resource_b >= expected:
			return true
		await get_tree().create_timer(0.1).timeout
		elapsed_seconds += 0.1
	return worker.resource_b >= expected


## 等待载荷丢失测试 Worker 取得指定数量的 A 类资源。
func _wait_for_worker_resource_a(worker, expected: int, timeout_seconds: float) -> bool:
	var elapsed_seconds := 0.0
	while elapsed_seconds < timeout_seconds:
		if worker.resource_a >= expected:
			return true
		await get_tree().create_timer(0.1).timeout
		elapsed_seconds += 0.1
	return worker.resource_a >= expected


## 等待玩家账户在实际交付后达到指定值。
func _wait_for_player_resource(player, expected: int, timeout_seconds: float) -> bool:
	var elapsed_seconds := 0.0
	while elapsed_seconds < timeout_seconds:
		if player.resource_b >= expected:
			return true
		await get_tree().create_timer(0.1).timeout
		elapsed_seconds += 0.1
	return player.resource_b >= expected


## 收集 Match 级订单状态事件。
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


## 收集传统输入控制器的即时命令反馈。
func _on_command_feedback(command_name, accepted_count, rejected_count, status):
	_feedback_events.append({
		"command_name": command_name,
		"accepted_count": accepted_count,
		"rejected_count": rejected_count,
		"status": status,
	})


## 返回指定 Worker 最近创建的目标种类订单 ID。
func _latest_order_id(worker: Node, kind: String) -> String:
	if not worker.has_meta("ai_rts_unit_id"):
		return ""
	var unit_id := str(worker.get_meta("ai_rts_unit_id"))
	for index in range(_order_events.size() - 1, -1, -1):
		var event = _order_events[index]
		if event["unit_id"] == unit_id and event["kind"] == kind:
			return event["order_id"]
	return ""


## 返回指定命令最近一次即时反馈状态。
func _last_feedback_status(command_name: String) -> String:
	for index in range(_feedback_events.size() - 1, -1, -1):
		if _feedback_events[index]["command_name"] == command_name:
			return _feedback_events[index]["status"]
	return ""


## 累计断言失败并写入 Godot 错误日志。
func _check(condition: bool, message: String):
	if condition:
		return
	_failures += 1
	push_error("Worker Gather assertion failed: %s" % message)
