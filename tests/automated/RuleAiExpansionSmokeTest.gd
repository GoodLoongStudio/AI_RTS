extends Node

const MatchScene = preload("res://tests/manual/TestPlayerVsAI.tscn")

var _failures := 0


## AI-plan Part A Phase 1：扩张门控矩阵 + 扩张管线（请求→provision→蓝图出现）。
func _ready():
	var match_instance = MatchScene.instantiate()
	var rule_ai = match_instance.get_node("Players/SimpleClairvoyantAI")
	rule_ai.expected_number_of_ag_turrets = 0
	rule_ai.expected_number_of_aa_turrets = 0
	rule_ai.expected_number_of_battlegroups = 1
	rule_ai.expected_number_of_units_in_battlegroup = 1
	rule_ai.max_command_centers = 3
	rule_ai.expansion_resource_threshold = 0
	rule_ai.workers_per_command_center = 2
	add_child(match_instance)
	# 不能假设固定帧数就绪：`Match._ready` 的首个 await 是导航烘焙（Match.gd:80），
	# 玩家创建、查询运行时注入与 C# 资源账户都排在它之后；固定等 3 帧时 AI 还没拿到
	# 这些依赖，门控断言会全部打反（current_count == 0 走"无条件重建"分支）。
	rule_ai = await _await_rule_ai_ready(match_instance, rule_ai)
	if rule_ai.get("_world_query_runtime") == null or rule_ai.get("_economy_runtime") == null:
		print("Rule AI expansion smoke test completed: %d failure(s)" % (_failures + 1))
		push_error("Match 未在超时内完成规则 AI 注入（查询运行时/资源账户）")
		SmokeTestExit.request(get_tree(), 1)
		return
	# 还要等 AI 的初始单位生成完成，否则 `_enforce_number_of_ccs` 会走"无条件重建"分支
	# （EconomyController.gd:91），把两个门控断言的期望值打反。
	await _await_ai_has_command_center(rule_ai)

	var economy = rule_ai.get_node("EconomyController")

	# 门控 1：有 idle worker 时不得扩张（直接驱动被测函数，免长模拟）。
	economy.set("_number_of_pending_cc_resource_requests", 0)
	economy.call("_enforce_number_of_ccs", economy.call("_get_own_entities"), 1)
	_check(int(economy.get("_number_of_pending_cc_resource_requests")) == 0,
		"Phase1: 有 idle worker 时不得触发扩张")

	# 门控 2：工人饱和（idle=0）→ 触发扩张请求。
	economy.call("_enforce_number_of_ccs", economy.call("_get_own_entities"), 0)
	_check(int(economy.get("_number_of_pending_cc_resource_requests")) == 1,
		"Phase1: 工人饱和且余额过门槛应触发一次扩张请求")

	# 门控 3：达到 CC 上限时不得再扩张。
	rule_ai.max_command_centers = 1
	economy.set("_number_of_pending_cc_resource_requests", 0)
	economy.call("_enforce_number_of_ccs", economy.call("_get_own_entities"), 0)
	_check(int(economy.get("_number_of_pending_cc_resource_requests")) == 0,
		"Phase1: 达到 CC 上限时不得触发扩张")
	rule_ai.max_command_centers = 3

	# 管线：视为资源已获准，provision 后应在限定时间内出现第二座 CC 蓝图。
	# 走游戏自身资源通道注入（PlaceStructure 有权威余额校验，绕不过它）。
	# 统一货币（2026-09-14）：B 已移除，资源账户只注册了 A；只注入 A（带 resource_b
	# 会触发 C# 的 "resource account must be configured before use" 断言）。
	# 注入额必须覆盖 CC 真实建造成本：`_try_construct_cc` 在 InsufficientResources
	# 时会直接 break（EconomyController.gd:283），原先固定注入 100 与成本 2400 不匹配，
	# 会让"第二座 CC 蓝图"断言必然失败（与统一货币无关的测试期望错误）。
	var balance = match_instance.get_node("BalanceConfigRuntime")
	var cc_scene = load("res://source/match/units/CommandCenter.tscn")
	var cc_cost: Dictionary = balance.GetConstructionCost(cc_scene)
	var granted: bool = rule_ai.add_resources({"resource_a": int(cc_cost["resource_a"]) * 2})
	_check(granted, "Phase1: 资源通道应能向规则 AI 注入余额")
	economy.set("_number_of_pending_cc_resource_requests", 1)
	economy.call("provision", cc_cost, "cc")
	var second_cc := false
	var waited := 0.0
	while waited < 12.0:
		await get_tree().create_timer(0.5).timeout
		waited += 0.5
		if _count_own_cc(rule_ai) >= 2:
			second_cc = true
			break
	_check(second_cc, "Phase1: 扩张请求获准后应放置第二座 CommandCenter 蓝图")

	print("Rule AI expansion smoke test completed: %d failure(s)" % _failures)
	match_instance.queue_free()
	await get_tree().process_frame
	SmokeTestExit.request(get_tree(), 0 if _failures == 0 else 1)


func _count_own_cc(rule_ai) -> int:
	var result: Dictionary = rule_ai.get("_world_query_runtime").GetOwnForces(
		rule_ai.get("_query_session_id"), 1 << 0 | 1 << 1 | 1 << 4
	)
	if result.get("status", "") != "Accepted":
		return 0
	return result.get("entities", []).filter(
		func(entity): return entity.get("type_id", "") == "command_center"
	).size()


func _check(condition: bool, message: String):
	if condition:
		return
	_failures += 1
	print("FAIL: %s" % message)
	push_error(message)


## 等待 Match 完成异步初始化（玩家创建 + 查询运行时注入 + C# 资源账户）。
## 判定取注入链路的两个终态；超时返回当前节点并报错，不会无限等待（不掩盖真实失败）。
func _await_rule_ai_ready(match_instance: Node, rule_ai = null, timeout_s := 30.0):
	var waited := 0.0
	while waited < timeout_s:
		if rule_ai == null:
			rule_ai = match_instance.get_node_or_null("Players/SimpleClairvoyantAI")
		if rule_ai != null \
				and rule_ai.get("_world_query_runtime") != null \
				and rule_ai.get("_economy_runtime") != null:
			return rule_ai
		await get_tree().create_timer(0.1).timeout
		waited += 0.1
	push_error("Match 未在 %.0fs 内完成规则 AI 注入（查询运行时/资源账户）" % timeout_s)
	return rule_ai


## 等待 AI 生成第一座 CommandCenter（扩张门控断言的前提）。
func _await_ai_has_command_center(rule_ai, timeout_s := 30.0) -> void:
	var waited := 0.0
	while waited < timeout_s:
		if _count_own_cc(rule_ai) >= 1:
			return
		await get_tree().create_timer(0.2).timeout
		waited += 0.2
	push_error("AI 未在 %.0fs 内生成 CommandCenter" % timeout_s)
