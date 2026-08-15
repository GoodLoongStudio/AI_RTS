extends Node

const MatchScene = preload("res://tests/manual/TestPlayerVsAI.tscn")

var _failures := 0


## 验证 Match 为传统规则 AI 绑定自己的标准会话，且资源准入通过公共查询完成。
func _ready():
	var match_instance = MatchScene.instantiate()
	add_child(match_instance)
	await get_tree().process_frame
	await get_tree().physics_frame

	var rule_ai = match_instance.get_node("Players/SimpleClairvoyantAI")
	_check(rule_ai.get("_world_query_runtime") != null,
		"Match 应向传统规则 AI 注入公共查询 Runtime")
	_check(not String(rule_ai.get("_query_session_id")).is_empty(),
		"传统规则 AI 应持有绑定自身身份的标准会话")
	var exact_balance := {"resource_a": rule_ai.resource_a, "resource_b": rule_ai.resource_b}
	_check(rule_ai.call("_has_resources", exact_balance),
		"公共己方经济查询应允许等于当前余额的请求")
	_check(not rule_ai.call("_has_resources", {"resource_a": rule_ai.resource_a + 1}),
		"公共己方经济查询应拒绝超过当前余额的请求")

	print("Rule AI economy query smoke test completed: %d failure(s)" % _failures)
	match_instance.queue_free()
	await get_tree().process_frame
	get_tree().quit(0 if _failures == 0 else 1)


## 累计断言失败并输出可定位原因。
func _check(condition: bool, message: String):
	if condition:
		return
	_failures += 1
	print("FAIL: %s" % message)
	push_error(message)
