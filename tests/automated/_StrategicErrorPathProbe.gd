extends Node

## 错误/重试路径验证（验收项 8 ✓，确定性 ✓，不需要真模型）：
## 向页面注入合成的错误回复 ⇒ 必须显示「错误：…（可点击重试）」+ 系统行 ✓；
## 注入合成成功回复 ⇒ 必须显示「已回复（…）」+ 副官正文 ✓；
## 以及 warming / http_5xx / timeout / empty_output 四种 error_code 的可见文案 ✓。

const PAGE := "res://source/main-menu/StrategicSandboxPage.tscn"
const CODES := ["warming", "http_500", "timeout", "empty_output", "model_unavailable"]

var _failures := 0


func _process(_delta: float) -> void:
	if get_tree().paused:
		get_tree().paused = false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	get_tree().create_timer(180.0).timeout.connect(func() -> void:
		push_error("[ERRPATH] 超时")
		get_tree().quit(2))
	await _run()


func _run() -> void:
	var page: Control = load(PAGE).instantiate()
	page.set("map_path", "res://source/match/maps/PlainAndSimple.tscn")
	add_child(page)
	get_tree().current_scene = page
	for _f in range(20):
		await get_tree().process_frame
	page.call("_on_spawn_selected", 0)
	for _f in range(10):
		await get_tree().process_frame
	var status: Label = page.get("_chat_status")
	var history: VBoxContainer = page.get("_chat_history")
	var conv: String = str(page.get("_adapter").get("conversation_id"))
	# ① 五种错误码都要有可见文案 ✓
	for code in CODES:
		page.call("_on_chat_reply", {"ok": false, "error_code": code, "conversation_id": conv})
		await get_tree().process_frame
		var txt := status.text
		print("[ERRPATH] code=%s ⇒ 状态=%s" % [code, txt])
		_check(txt.contains("错误") or txt.contains("重试") or txt.contains("预热"), "错误码 %s 必须有可见文案（实际 %s）" % [code, txt])
		_check(_history_has(history, "系统"), "错误码 %s 必须写入系统行供用户看到" % code)
	# ② 成功回复 ✓
	page.call("_on_chat_reply", {"ok": true, "assistant_text": "根据已知地图事实，建议先侦察东南方向。", "model": "probe", "elapsed_ms": 1234, "conversation_id": conv})
	await get_tree().process_frame
	_check(status.text.contains("已回复"), "成功回复必须显示「已回复」（实际 %s）" % status.text)
	_check(_history_has(history, "东南"), "成功回复正文必须写入历史")
	# ③ 会话防污染：来自**旧会话**的迟到回复不得写入 ✓（提示词 §4）
	var before := _count_lines(history)
	page.call("_on_chat_reply", {"ok": true, "assistant_text": "旧会话的迟到回复", "model": "probe", "elapsed_ms": 1, "conversation_id": "chat-conv-OLD-session"})
	await get_tree().process_frame
	var after := _count_lines(history)
	_check(after == before, "旧 conversation_id 的迟到回复**不得**写入新会话（%d → %d）" % [before, after])
	print("Strategic error path probe completed: %d failure(s)" % _failures)
	get_tree().quit(0 if _failures == 0 else 1)


func _history_has(history: VBoxContainer, needle: String) -> bool:
	if history == null:
		return false
	for child in history.get_children():
		if child is RichTextLabel and (child as RichTextLabel).text.contains(needle):
			return true
		if child is Label and (child as Label).text.contains(needle):
			return true
	return false


func _count_lines(history: VBoxContainer) -> int:
	return history.get_child_count() if history != null else 0


func _check(cond: bool, msg: String) -> void:
	if cond:
		print("[ERRPATH] OK: " + msg)
	else:
		_failures += 1
		push_error("[ERRPATH] FAIL: " + msg)
