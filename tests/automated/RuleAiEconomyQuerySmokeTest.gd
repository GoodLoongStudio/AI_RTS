extends Node

const MatchScene = preload("res://tests/manual/TestPlayerVsAI.tscn")
const FIELD_TYPE := 1 << 1
const FIELD_CONSTRUCTION := 1 << 4
const FIELD_PRODUCTION := 1 << 5
const FIELD_ORDER := 1 << 6

var _failures := 0


## 验证 Match 为传统规则 AI 绑定自己的标准会话，且资源准入通过公共查询完成。
func _ready():
	var match_instance = MatchScene.instantiate()
	add_child(match_instance)
	await get_tree().process_frame
	await get_tree().physics_frame
	await get_tree().process_frame
	await get_tree().process_frame

	var rule_ai = match_instance.get_node("Players/SimpleClairvoyantAI")
	_check(rule_ai.get("_world_query_runtime") != null,
		"Match 应向传统规则 AI 注入公共查询 Runtime")
	_check(not String(rule_ai.get("_query_session_id")).is_empty(),
		"传统规则 AI 应持有绑定自身身份的标准会话")
	var exact_balance := {"resource_a": rule_ai.resource_a}
	_check(rule_ai.call("_has_resources", exact_balance),
		"公共己方经济查询应允许等于当前余额的请求")
	_check(not rule_ai.call("_has_resources", {"resource_a": rule_ai.resource_a + 1}),
		"公共己方经济查询应拒绝超过当前余额的请求")
	_check(rule_ai.has_node("RuleAiCommandGateway"),
		"Match 应为传统规则 AI 注入固定身份的稳定 ID 命令适配器")
	var forces: Dictionary = rule_ai.get("_world_query_runtime").GetOwnForces(
		rule_ai.get("_query_session_id"),
		FIELD_TYPE | FIELD_CONSTRUCTION | FIELD_PRODUCTION | FIELD_ORDER
	)
	var workers: Array = forces["entities"].filter(
		func(entity): return entity.get("type_id", "") == "worker"
	)
	var completed_structures: Array = forces["entities"].filter(
		func(entity):
			var construction = entity.get("construction", null)
			return construction != null and construction.get("state", "") == "Completed"
	)
	var producers: Array = forces["entities"].filter(
		func(entity): return entity.get("production", null) != null
	)
	_check(not workers.is_empty(), "己方查询应返回规则 AI 的稳定 Worker ID")
	var gathering_workers: Array = workers.filter(
		func(worker):
			var order = worker.get("order", null)
			return order != null and order.get("kind", "") == "Gather"
	)
	_check(not gathering_workers.is_empty(),
		"EconomyController 应通过稳定 ID Gather 为无订单 Worker 分配可见资源")
	if not gathering_workers.is_empty():
		var target = gathering_workers[0]["order"].get("target", null)
		_check(
			target != null
			and target.get("entity_kind", "") == "ResourceNode"
			and target.get("type_id", "") == "resource_a",
			"Gather 活动订单应返回下令时确认的资源 ID 与稳定类型"
		)
		var invalid_gather: Dictionary = rule_ai.get_node("RuleAiCommandGateway").Gather(
			[gathering_workers[0]["id"]],
			"00000000-0000-0000-0000-000000000001"
		)
		_check(
			invalid_gather.get("status", "") == "Rejected"
			and invalid_gather["unit_results"][0].get("error_code", "")
			== "ResourceTargetNotFound",
			"固定身份 Gather 应拒绝不存在的稳定资源 ID"
		)
		var gathering_worker_id: String = gathering_workers[0]["id"]
		var gathering_worker_node = null
		for unit in get_tree().get_nodes_in_group("units"):
			var reference: Dictionary = (
			rule_ai
				. get("_world_query_runtime")
				. GetOwnEntityReferenceForTests(unit, rule_ai)
			)
			if reference.get("id", "") == gathering_worker_id:
				gathering_worker_node = unit
				break
		_check(gathering_worker_node != null,
			"测试应能用稳定 ID 定位正在 Gather 的 AI Worker")
		if gathering_worker_node != null:
			var stop_result: Dictionary = (
				match_instance
				. get_node("Players/Human/UnitCommandGateway")
				. StopUnits([gathering_worker_node], rule_ai)
			)
			_check(stop_result.get("status", "") == "Accepted",
				"测试 Stop 应把规则 AI 的 Gather 订单暂停")
			await get_tree().create_timer(0.6).timeout
			var after_stop: Dictionary = rule_ai.get("_world_query_runtime").GetOwnForces(
				rule_ai.get("_query_session_id"),
				FIELD_TYPE | FIELD_ORDER
			)
			var stopped_worker: Dictionary = after_stop["entities"].filter(
				func(entity): return entity.get("id", "") == gathering_worker_id
			)[0]
			_check(
				stopped_worker.get("order", null) != null
				and stopped_worker["order"].get("state", "") == "Suspended",
				"EconomyController 刷新后仍应保留暂停的 Gather，不得自动恢复"
			)
	_check(not completed_structures.is_empty(),
		"己方查询应把初始完成建筑标记为 Completed")
	_check(not producers.is_empty(), "己方查询应返回生产建筑的生产观察")
	if not producers.is_empty():
		var production: Dictionary = producers[0]["production"]
		_check(production.has("queue_limit") and production.has("items"),
			"生产观察应显式返回队列容量与 Items，空队列也不能省略")
		var invalid_production: Dictionary = (
			rule_ai
			. get_node("RuleAiCommandGateway")
			. EnqueueProduction(producers[0]["id"], "unknown_product_for_test")
		)
		_check(
			not invalid_production.get("accepted", false)
			and invalid_production.get("status", "") == "DefinitionNotFound",
			"固定身份生产适配器应按稳定类型拒绝未知产品"
		)
	if not workers.is_empty() and not completed_structures.is_empty():
		var invalid_construct: Dictionary = rule_ai.get_node("RuleAiCommandGateway").Construct(
			[workers[0]["id"]],
			completed_structures[0]["id"]
		)
		_check(invalid_construct["status"] == "Rejected",
			"稳定 ID 施工命令应拒绝已经完成的建筑")
	var invalid_placement: Dictionary = rule_ai.get_node("RuleAiCommandGateway").PlaceStructure(
		"unknown_structure_for_test",
		Transform3D.IDENTITY
	)
	_check(
		invalid_placement["status"] == "Rejected"
		and invalid_placement["primary_issue"] == "UnknownDefinition",
		"固定身份放置适配器应按稳定类型拒绝未知建筑"
	)

	print("Rule AI economy query smoke test completed: %d failure(s)" % _failures)
	match_instance.queue_free()
	await get_tree().process_frame
	SmokeTestExit.request(get_tree(), 0 if _failures == 0 else 1)


## 累计断言失败并输出可定位原因。
func _check(condition: bool, message: String):
	if condition:
		return
	_failures += 1
	print("FAIL: %s" % message)
	push_error(message)
