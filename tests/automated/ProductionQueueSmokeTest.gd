extends Node

const MatchScene = preload("res://tests/manual/TestAllUnits.tscn")
const TankScene = preload("res://source/match/units/Tank.tscn")
const HelicopterScene = preload("res://source/match/units/Helicopter.tscn")

var _failures := 0
var _produced_units := []


## 验证统一容量、资格、稳定项目、取消退款、顺序推进与实际部署。
func _ready():
	MatchSignals.unit_production_finished.connect(_on_unit_production_finished)
	var match_instance = MatchScene.instantiate()
	add_child(match_instance)
	await get_tree().process_frame
	await get_tree().process_frame

	var human = match_instance.get_node("Players/Human")
	var factory = human.get_node("VehicleFactory")
	var queue = factory.production_queue
	var runtime = match_instance.get_node("ProductionRuntime")
	_check(
		human.add_resources({"resource_a": 3000, "resource_b": 3000}, "ScriptedAdjustment"),
		"测试资源注入应成功"
	)
	var full_balance_a: int = human.resource_a
	var full_balance_b: int = human.resource_b
	var tank_cost = match_instance.get_node("BalanceConfigRuntime").GetProductionCost(TankScene)

	for _index in range(5):
		_check(queue.produce(TankScene) != null, "容量内的生产项目应入队")
	_check(queue.size() == 5, "统一生产队列容量应为 5")
	_check(queue.produce(TankScene) == null, "第六项不得绕过统一队列容量")
	_check(
		human.resource_a == full_balance_a - tank_cost["resource_a"] * 5
		and human.resource_b == full_balance_b - tank_cost["resource_b"] * 5,
		"被 QueueFull 拒绝的项目不得额外扣款"
	)
	queue.cancel_all()
	_check(queue.size() == 0, "CancelAll 应同步清空当前活动队列")
	_check(
		human.resource_a == full_balance_a and human.resource_b == full_balance_b,
		"取消全部未完成项目应全额退款"
	)

	var disallowed = runtime.Enqueue(
		factory,
		HelicopterScene,
		human
	)
	_check(disallowed["status"] == "ProductNotAllowed", "VehicleFactory 不得生产 Helicopter")

	var first = queue.produce(TankScene)
	var second = queue.produce(TankScene)
	_check(first != null and second != null, "两项顺序生产应成功入队")
	_check(not first.item_id.is_empty() and not second.item_id.is_empty(), "HUD 项目应持有稳定 ItemId")
	_check(first.state == "Producing" and second.state == "Queued", "只有队首应进入 Producing")

	var elapsed_seconds := 0.0
	while _produced_units.is_empty() and elapsed_seconds < 22.0:
		await get_tree().create_timer(0.1).timeout
		elapsed_seconds += 0.1
	if _produced_units.is_empty():
		print("Production deployment diagnostic: ", runtime.GetQueue(factory))
	_check(_produced_units.size() == 1, "首个 Tank 应在有限时间内只部署一次")
	_check(queue.size() == 1, "首项完成后应从活动队列移除")
	_check(second.state == "Producing", "首项部署后第二项应取得生产线")
	_check(runtime.GetQueue(factory).size() == 1, "C# 权威队列应与 Legacy HUD 视图一致")

	queue.cancel(second)
	_check(queue.size() == 0, "取消第二项后队列应为空")
	_check(
		human.resource_a == full_balance_a - tank_cost["resource_a"]
		and human.resource_b == full_balance_b - tank_cost["resource_b"],
		"最终只应保留已完成首项的成本"
	)

	print("Production queue smoke test completed: %d failure(s)" % _failures)
	match_instance.queue_free()
	await get_tree().process_frame
	SmokeTestExit.request(get_tree(), 0 if _failures == 0 else 1)


## 收集目标工厂实际生成的 Tank。
func _on_unit_production_finished(unit, producer):
	if producer.name == "VehicleFactory":
		_produced_units.append(unit)


## 累计断言失败并继续执行其余检查。
func _check(condition: bool, message: String):
	if condition:
		return
	_failures += 1
	push_error("Production queue assertion failed: %s" % message)
