extends Node

## 战略聊天适配层（AdjutantChatService）纯逻辑回归（2026-10-02 阶段 1）。
##
## 覆盖提示词 §8.1：语义契约字段、system prompt 约束、回执解析（200/非200/空输出/
## 非法输出）、会话绑定与换局隔离、单在途防重复、迟到响应丢弃、模型关闭不出命令、
## 安全边界（适配层源码不得引用任何执行入口）。
## 不拉真模型：真模型链路由 UI 探针与可见实例验证（阶段报告引用）。

const ChatService := preload("res://source/ui/AdjutantChatService.gd")

var _failures := 0


func _ready() -> void:
	_test_payload_contract()
	_test_system_prompt_constraints()
	_test_parse_chat_completion()
	_test_error_text_mapping()
	_test_conversation_binding_and_history()
	await _test_single_flight_and_failure_matrix()
	_test_late_response_isolation()
	_test_safety_boundary()
	print("Strategic chat service smoke test completed: %d failure(s)" % _failures)
	get_tree().quit(1 if _failures > 0 else 0)


func _check(condition: bool, label: String) -> void:
	if condition:
		print("PASS ", label)
	else:
		print("FAIL ", label)
		_failures += 1


## ── 语义契约 ──
func _test_payload_contract() -> void:
	var payload := ChatService.build_payload(
		"chat-conv-abcd-0001", "chat-conv-abcd", "match-1", "local_player",
		true, "这局的战略重点应该是什么？",
		[{"role": "user", "content": "上一问"}])
	for key in ["request_id", "conversation_id", "match_id", "player_id", "paused", "message", "history_tail"]:
		_check(payload.has(key), "契约必须包含字段 %s" % key)
	_check(payload["request_id"] == "chat-conv-abcd-0001", "request_id 原样透传")
	_check(payload["paused"] == true, "paused 布尔透传")
	_check(payload["history_tail"].size() == 1, "history_tail 透传")
	var round_trip: Variant = JSON.parse_string(JSON.stringify(payload))
	_check(round_trip is Dictionary and round_trip["message"] == payload["message"],
		"payload 必须 JSON 可往返（中文不丢）")


## ── system prompt 约束（模型职责）──
func _test_system_prompt_constraints() -> void:
	var prompt := ChatService.strategic_system_prompt()
	_check(prompt.contains("战略讨论副官"), "角色必须是战略讨论副官")
	_check(prompt.contains("不得出现“已执行”") or prompt.contains("已执行"),
		"必须显式禁止“已执行/已下令”类表述")
	_check(not prompt.contains("JSON") or prompt.contains("只对话"),
		"阶段 1 不强迫模型返回 JSON 计划")
	_check(prompt.contains("不要编造"), "必须要求不编造未知信息")


## ── 回执解析 ──
func _test_parse_chat_completion() -> void:
	var good := JSON.stringify({
		"choices": [{"finish_reason": "stop",
			"message": {"role": "assistant", "content": " 先稳经济，再补侦察。 "}}],
	})
	var ok := ChatService.parse_chat_completion(200, good)
	_check(bool(ok.get("ok")) and ok.get("assistant_text") == "先稳经济，再补侦察。",
		"200 合法回执 → ok + 去首尾空白文本")

	var empty := ChatService.parse_chat_completion(200, JSON.stringify({
		"choices": [{"finish_reason": "stop", "message": {"role": "assistant", "content": "   "}}]}))
	_check(not bool(empty.get("ok")) and empty.get("error_code") == "empty_output",
		"空输出必须 empty_output")

	var bad_json := ChatService.parse_chat_completion(200, "这不是JSON")
	_check(not bool(bad_json.get("ok")) and bad_json.get("error_code") == "invalid_output",
		"非 JSON 必须 invalid_output")

	var no_choices := ChatService.parse_chat_completion(200, JSON.stringify({"object": "x"}))
	_check(not bool(no_choices.get("ok")) and no_choices.get("error_code") == "invalid_output",
		"缺 choices 必须 invalid_output")

	# 【2026-10-04 复核第 2 项】畸形 JSON 全形态覆盖（静默解析，日志无 Parse JSON failed）
	var malformed_cases := [
		["{bad", "invalid_output", "语法错误（截断的对象）"],
		["{\"choices\":", "invalid_output", "语法错误（截断的数组）"],
		["[]", "invalid_output", "顶层类型错误（数组而非对象）"],
		["null", "invalid_output", "顶层类型错误（null）"],
		["{\"data\": 1}", "invalid_output", "缺 choices"],
		["{\"choices\": [{\"message\": {\"role\": \"assistant\"}}]}", "invalid_output", "缺 content"],
	]
	for mc in malformed_cases:
		var r := ChatService.parse_chat_completion(200, mc[0])
		_check(not bool(r.get("ok")) and r.get("error_code") == mc[1],
			"畸形 JSON %s（%s）必须 %s" % [mc[0].left(30), mc[2], mc[1]])
	# 空 content 单独测（按语义是 empty_output 而非 invalid_output）
	var ws := ChatService.parse_chat_completion(200, JSON.stringify({
		"choices": [{"finish_reason": "stop", "message": {"role": "assistant", "content": "  "}}]}))
	_check(not bool(ws.get("ok")) and ws.get("error_code") == "empty_output",
		"空白 content 必须 empty_output")

	var e502 := ChatService.parse_chat_completion(502, "{}")
	_check(not bool(e502.get("ok")) and e502.get("error_code") == "http_502",
		"非 200 → http_<code>")


## ── error_code → 中文说明（稳定映射）──
func _test_error_text_mapping() -> void:
	for code in ["timeout", "empty_output", "invalid_output", "sending_in_progress",
			"empty_message", "model_unavailable"]:
		_check(not ChatService.error_text(code).is_empty(), "%s 必须有玩家可读说明" % code)
	_check(ChatService.error_text("http_500").contains("500"), "http 类错误要带状态码")


## ── 会话绑定 / 换局隔离 / 历史 ──
func _test_conversation_binding_and_history() -> void:
	var a := ChatService.new()
	add_child(a)
	a.setup("match-1", "player-A")
	var conv_a: String = a.conversation_id
	_check(conv_a.begins_with("chat-conv-match-1"), "conversation_id 必须绑定 match 标识")
	_check(a.match_id == "match-1" and a.player_id == "player-A", "match/player 绑定透传")

	a.history.append({"role": "user", "content": "q1"})
	a.history.append({"role": "assistant", "content": "a1"})
	var tail: Array = a.history_tail()
	_check(tail.size() == 2 and tail[0]["role"] == "user", "history_tail 保留问答对")

	a.setup("match-2", "player-A")
	_check(a.conversation_id != conv_a and a.conversation_id.contains("match-2"),
		"换局必须换 conversation_id（上局历史不得串用）")
	_check(a.history.is_empty(), "换局必须清空历史")
	a.queue_free()


## ── 单在途 + 桩模型故障矩阵（模型关闭/异常的确定性替代）──
## OS 层"连接拒绝"在本机防火墙下不可靠（SYN 被静默丢弃），
## 改用本地桩模型服务器注入确定性故障（503 / 空输出 / 非法输出 / 挂起）。
var _stub_port_seq := 0

## 桩模型基础端口（每个矩阵 +偏移，独立生命周期互不串扰）。
const STUB_PORT := 18230

## 每个矩阵独立端口（避免 stop/start 生命周期竞争串扰）。
func _start_stub(mode: String) -> int:
	_stub_port_seq += 1
	return await _start_stub_at(STUB_PORT + _stub_port_seq, mode)


func _start_stub_at(port: int, mode: String) -> int:
	var pid: int = OS.create_process("python", PackedStringArray([
		"tests/automated/_stub_strategic_model.py", str(port), mode]), false)
	var waited := 0.0
	while waited < 5.0:
		await get_tree().create_timer(0.2).timeout
		waited += 0.2
		var peer := StreamPeerTCP.new()
		if peer.connect_to_host("127.0.0.1", port) == OK:
			peer.poll()
			var ok: bool = peer.get_status() == StreamPeerTCP.STATUS_CONNECTED
			peer.disconnect_from_host()
			if ok:
				return pid
	return pid


func _stop_stub(pid: int) -> void:
	if pid > 0 and OS.is_process_running(pid):
		OS.kill(pid)


func _test_single_flight_and_failure_matrix() -> void:
	# 矩阵 A：hang 模式 + 1.5s 超时 → 单在途抑制 + timeout 错误
	var hang_pid := await _start_stub("hang")
	var svc: Node = ChatService.new()
	add_child(svc)
	svc.request_timeout_s = 1.5
	svc.endpoint_override = "http://127.0.0.1:%d/v1" % (STUB_PORT + 1)
	svc.setup("match-9", "player-X")
	var first: Dictionary = svc.send("这局的战略重点应该是什么？")
	_check(bool(first.get("queued")), "第一次发送应入队")
	var second: Dictionary = svc.send("再来一条")
	_check(not bool(second.get("queued")) and second.get("error_code") == "sending_in_progress",
		"在途期间重复发送必须被抑制")
	var empty: Dictionary = svc.send("   ")
	_check(not bool(empty.get("queued")) and empty.get("error_code") == "empty_message",
		"空消息必须拒绝（即便在途）")
	var waited := 0.0
	while svc.is_busy() and waited < 8.0:
		await get_tree().create_timer(0.2).timeout
		waited += 0.2
	_check(not svc.is_busy(), "超时请求必须以失败收场（不悬挂）")
	_check(svc.history.is_empty() or str(svc.history[-1].get("role")) != "assistant",
		"失败请求不得伪造副官回复")
	svc.queue_free()
	await _stop_stub(hang_pid)
	await get_tree().process_frame

	# 矩阵 B：503 / 空输出 / 非法输出 → 对应稳定 error_code
	var case_index := 0
	for case in [["error503", "http_503"], ["empty", "empty_output"], ["invalid", "invalid_output"]]:
		case_index += 1
		var matrix_port: int = STUB_PORT + 10 + case_index
		var pid := await _start_stub_at(matrix_port, case[0])
		var svc2: Node = ChatService.new()
		add_child(svc2)
		svc2.request_timeout_s = 5.0
		svc2.endpoint_override = "http://127.0.0.1:%d/v1" % matrix_port
		svc2.setup("match-%s" % case[0], "player-X")
		var sent: Dictionary = svc2.send("测试故障注入")
		_check(bool(sent.get("queued")), "矩阵 %s：发送应入队" % case[0])
		waited = 0.0
		while svc2.is_busy() and waited < 10.0:
			await get_tree().create_timer(0.2).timeout
			waited += 0.2
		var code: String = svc2._last_error_code
		_check(code == case[1], "矩阵 %s：应报 %s（实际 %s）" % [case[0], case[1], code])
		svc2.queue_free()
		await _stop_stub(pid)
		await get_tree().process_frame


## ── 迟到响应隔离 ──
func _test_late_response_isolation() -> void:
	var svc: Node = ChatService.new()
	add_child(svc)
	svc.endpoint_override = "http://127.0.0.1:9/v1"
	svc.setup("match-8", "player-X")
	var late_body := JSON.stringify({"choices": [{"finish_reason": "stop",
		"message": {"role": "assistant", "content": "迟到的旧回复"}}]})
	# 当前没有在途请求（_inflight_request_id 为空）⇒ 任何回包都算迟到，必须丢弃。
	var before_size: int = svc.history.size()
	svc._on_request_completed(0, 200, PackedStringArray(), late_body.to_utf8_buffer())
	_check(svc.history.size() == before_size, "迟到/孤儿响应不得进入历史")
	svc.queue_free()
	await get_tree().process_frame


## ── 安全边界：适配层不得引用任何执行入口 ──
func _test_safety_boundary() -> void:
	var text: String = FileAccess.open("res://source/ui/AdjutantChatService.gd", FileAccess.READ).get_as_text()
	for forbidden in ["adjutant_command", "adjutant_batch", "adjutant_intent",
			"augment_pick", "UnitCommandGateway", "task_patch", "ForceAttack",
			"RequestGroundForceAttack", "Laya"]:
		_check(not text.contains(forbidden),
			"适配层源码不得引用执行入口 %s" % forbidden)
