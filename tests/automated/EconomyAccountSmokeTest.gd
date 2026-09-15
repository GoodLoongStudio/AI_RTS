extends Node

const MatchScene = preload("res://tests/manual/TestAllUnits.tscn")
const TankScene = preload("res://source/match/units/Tank.tscn")

var _failures := 0
var _balance_events: Array[Dictionary] = []


## 验证 C# 权威账户、Legacy 镜像、原子扣款及生产退款链路。
##
## 统一货币（2026-09-14）：B 已从玩法与配置移除，资源账户只登记 A
## （见 EconomyRuntime.RegisterPlayer）。因此：
## · 不再注入/断言 resource_b（账户无 B，快照字典也不再保证含 resource_b 键，
##   直接索引会 KeyError 崩断 _ready、把测试挂到超时）；
## · 原子性断言保留在同一处（额度不足 → 整体拒绝、不得部分扣除）。
func _ready():
	var match_instance = MatchScene.instantiate()
	add_child(match_instance)
	var human = match_instance.get_node_or_null("Players/Human")
	var economy_runtime = match_instance.get_node_or_null("EconomyRuntime")
	if human == null or economy_runtime == null:
		print("Economy account smoke test completed: %d failure(s)" % (_failures + 1))
		push_error("Match 场景缺少 Players/Human 或 EconomyRuntime")
		SmokeTestExit.request(get_tree(), 1)
		return
	# 不能假设固定帧数就绪：Match._ready 的首个 await 是导航烘焙（Match.gd:80
	# `await _setup_subsystems_dependent_on_map()`），玩家创建与 C# 资源账户
	# 都排在它之后。这里等到账户真正建立（快照非空）再继续。
	await _await_account_ready(economy_runtime, human)

	var vehicle_factory = human.get_node("VehicleFactory")
	economy_runtime.connect("BalanceChanged", _on_balance_changed)

	var initial = economy_runtime.GetSnapshot(human)
	_check(not initial.is_empty(), "Player 应在 Match 初始化时建立 C# 资源账户")
	if not initial.is_empty():
		_check(initial["resource_a"] == human.resource_a, "初始 A 镜像应与权威快照一致")

	_check(
		human.add_resources(
			{"resource_a": 600},
			"ScriptedAdjustment"
		),
		"显式调试交易应成功注入测试资源"
	)
	_check(human.resource_a == 600, "成功交易应同步 Legacy 镜像")

	var events_before_rejection := _balance_events.size()
	var rejected = human.subtract_resources(
		{"resource_a": 99999},
		"ConstructionCost"
	)
	_check(not rejected, "资源不足时扣款应整体拒绝")
	_check(human.resource_a == 600, "拒绝交易不得部分扣除 A")
	_check(
		_balance_events.size() == events_before_rejection,
		"拒绝交易不得发布权威余额变化事件"
	)

	var production_cost = match_instance.get_node("BalanceConfigRuntime").GetProductionCost(
		TankScene
	)
	var before_production_a: int = human.resource_a
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
	vehicle_factory.production_queue.cancel(queue_element)
	_check(
		human.resource_a == before_production_a,
		"取消生产应通过 ProductionRefund 全额恢复余额"
	)
	_check(_has_reason("ProductionCost"), "应发布 ProductionCost 权威事件")
	_check(_has_reason("ProductionRefund"), "应发布 ProductionRefund 权威事件")

	var final_snapshot = economy_runtime.GetSnapshot(human)
	_check(final_snapshot["resource_a"] == human.resource_a, "最终 A 镜像不得与账户分叉")

	print("Economy account smoke test completed: %d failure(s)" % _failures)
	match_instance.queue_free()
	await get_tree().process_frame
	SmokeTestExit.request(get_tree(), 0 if _failures == 0 else 1)


## 等待 Match 完成异步初始化并建立 Human 的 C# 资源账户（超时即报错返回，不无限等待）。
func _await_account_ready(economy_runtime, human, timeout_s := 30.0) -> void:
	var waited := 0.0
	while waited < timeout_s:
		if not economy_runtime.GetSnapshot(human).is_empty():
			return
		await get_tree().create_timer(0.1).timeout
		waited += 0.1
	push_error("Match 未在 %.0fs 内为本地玩家建立 C# 资源账户" % timeout_s)


## 收集 Match 范围的权威余额变化事件（resource_b 为信号既有字段，统一货币后恒 0）。
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
