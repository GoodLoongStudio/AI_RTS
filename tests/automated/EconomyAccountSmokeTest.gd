extends Node

const MatchScene = preload("res://tests/manual/TestAllUnits.tscn")
const TankScene = preload("res://source/match/units/Tank.tscn")

var _failures := 0
var _balance_events: Array[Dictionary] = []


## 验证 C# 权威账户、Legacy 镜像、原子扣款及生产退款链路。
func _ready():
	var match_instance = MatchScene.instantiate()
	add_child(match_instance)
	await get_tree().process_frame
	await get_tree().process_frame

	var human = match_instance.get_node("Players/Human")
	var economy_runtime = match_instance.get_node("EconomyRuntime")
	var vehicle_factory = human.get_node("VehicleFactory")
	economy_runtime.connect("BalanceChanged", _on_balance_changed)

	var initial = economy_runtime.GetSnapshot(human)
	_check(not initial.is_empty(), "Player 应在 Match 初始化时建立 C# 资源账户")
	_check(initial["resource_a"] == human.resource_a, "初始 A 镜像应与权威快照一致")
	_check(initial["resource_b"] == human.resource_b, "初始 B 镜像应与权威快照一致")

	_check(
		human.add_resources(
			{"resource_a": 600, "resource_b": 600},
			"ScriptedAdjustment"
		),
		"显式调试交易应成功注入测试资源"
	)
	_check(human.resource_a == 600 and human.resource_b == 600, "成功交易应同步 Legacy 镜像")

	var events_before_rejection := _balance_events.size()
	var rejected = human.subtract_resources(
		{"resource_a": 99999, "resource_b": 21},
		"ConstructionCost"
	)
	_check(not rejected, "任一资源不足时多资源扣款应整体拒绝")
	_check(human.resource_a == 600 and human.resource_b == 600, "拒绝交易不得部分扣除 A")
	_check(
		_balance_events.size() == events_before_rejection,
		"拒绝交易不得发布权威余额变化事件"
	)

	var production_cost = match_instance.get_node("BalanceConfigRuntime").GetProductionCost(
		TankScene
	)
	var before_production_a: int = human.resource_a
	var before_production_b: int = human.resource_b
	var queue_size_before: int = vehicle_factory.production_queue.size()
	vehicle_factory.production_queue.produce(TankScene)
	_check(
		vehicle_factory.production_queue.size() == queue_size_before + 1,
		"余额足够时 Tank 应进入生产队列"
	)
	var queue_element = vehicle_factory.production_queue.get_elements().back()
	_check(
		human.resource_a == before_production_a - production_cost["resource_a"],
		"生产入队应通过 ProductionCost 扣除 A"
	)
	_check(
		human.resource_b == before_production_b - production_cost["resource_b"],
		"生产入队应通过 ProductionCost 扣除 B"
	)
	vehicle_factory.production_queue.cancel(queue_element)
	_check(
		human.resource_a == before_production_a and human.resource_b == before_production_b,
		"取消生产应通过 ProductionRefund 全额恢复余额"
	)
	_check(_has_reason("ProductionCost"), "应发布 ProductionCost 权威事件")
	_check(_has_reason("ProductionRefund"), "应发布 ProductionRefund 权威事件")

	var final_snapshot = economy_runtime.GetSnapshot(human)
	_check(final_snapshot["resource_a"] == human.resource_a, "最终 A 镜像不得与账户分叉")
	_check(final_snapshot["resource_b"] == human.resource_b, "最终 B 镜像不得与账户分叉")

	print("Economy account smoke test completed: %d failure(s)" % _failures)
	match_instance.queue_free()
	await get_tree().process_frame
	SmokeTestExit.request(get_tree(), 0 if _failures == 0 else 1)


## 收集 Match 范围的权威余额变化事件。
func _on_balance_changed(
	player_id: String,
	transaction_id: String,
	reason: String,
	resource_a: int,
	resource_b: int,
	version: int
):
	_balance_events.append({
		"player_id": player_id,
		"transaction_id": transaction_id,
		"reason": reason,
		"resource_a": resource_a,
		"resource_b": resource_b,
		"version": version,
	})


## 返回是否观察到指定原因的权威余额变化事件。
func _has_reason(reason: String) -> bool:
	return _balance_events.any(func(event): return event["reason"] == reason)


## 累计断言失败并输出可定位原因。
func _check(condition: bool, message: String):
	if condition:
		return
	_failures += 1
	push_error(message)
