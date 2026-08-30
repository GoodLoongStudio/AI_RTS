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
	await get_tree().process_frame
	await get_tree().physics_frame
	await get_tree().process_frame

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
	economy.set("_number_of_pending_cc_resource_requests", 1)
	var balance = match_instance.get_node("BalanceConfigRuntime")
	var cc_scene = load("res://source/match/units/CommandCenter.tscn")
	economy.call("provision", balance.GetConstructionCost(cc_scene), "cc")
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
