extends Node

## 5 轮真实模型回复取证（提示词 §6-6 ✓）：真实页面 + 真实 Ollama（端口 11436 ✓）。
## 逐轮发送、轮询等待回复、记录正文，最后落 JSON ✓。不做任何对局链路 ✓。

const PAGE := "res://source/main-menu/StrategicSandboxPage.tscn"
## 显式 preload：class_name 全局缓存在文件刚改过时可能未刷新（本会话已踩两次）✗
const ModelSvc = preload("res://source/ui/AdjutantModelService.gd")
const OUT := "res://agent/runs/2026-10-06-strategic-prebattle-ui-map/model-rounds.json"
const QUESTIONS := [
	"根据地图上我的出生点位置，开局应该先做什么？",
	"这个出生点附近有什么已知资源或地形风险？",
	"请引用已知地图事实，说明我的侦察顺序。",
	"如果对手从我出生点的对面进攻，我应该守哪个方向？",
	"总结一下：哪些信息你现在不知道？",
]

var _failures := 0
var _replies: Array = []
var _page: Control = null


func _process(_delta: float) -> void:
	if get_tree().paused:
		get_tree().paused = false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	get_tree().create_timer(1500.0).timeout.connect(func() -> void:
		push_error("[MODEL] 超时兜底")
		_finish(2))
	await _run()


func _run() -> void:
	_page = load(PAGE).instantiate()
	_page.set("map_path", "res://source/match/maps/PlainAndSimple.tscn")
	add_child(_page)
	get_tree().current_scene = _page
	_page.set_anchors_preset(Control.PRESET_FULL_RECT)
	_page.size = Vector2(1600, 900)
	for _f in range(30):
		await get_tree().process_frame
	_page.call("_on_spawn_selected", 0)
	for _f in range(10):
		await get_tree().process_frame
	var input: LineEdit = _page.get("_chat_input")
	var history: VBoxContainer = _page.get("_chat_history")
	var baseline := _history_text(history)
	# 【关键修正】模型预热中 send() 只会返回 warming ⇒ 页面**不会真的发送** ✗
	# （上一轮 5 轮全部空回复就是这个原因）⇒ 必须先等模型就绪 ✓。
	var t0 := Time.get_ticks_msec()
	while (ModelSvc.is_warming() or not ModelSvc.is_listening()) and float(Time.get_ticks_msec() - t0) / 1000.0 < 300.0:
		await get_tree().process_frame
	print("[MODEL] 模型就绪：listening=%s warming=%s（等待 %.0fs）" % [
		str(ModelSvc.is_listening()), str(ModelSvc.is_warming()), float(Time.get_ticks_msec() - t0) / 1000.0])
	for i in range(QUESTIONS.size()):
		input.text = str(QUESTIONS[i])
		# 未排队成功（warming / 在途）⇒ 等一下就重发 ✓
		var sent := false
		for _try in range(60):
			_page.call("_on_send")
			var st: Label = _page.get("_chat_status")
			await get_tree().process_frame
			if st != null and not st.text.contains("预热"):
				sent = true
				break
			await get_tree().create_timer(2.0).timeout
		print("[MODEL] round=%d sent=%s" % [i + 1, str(sent)])
		# 【按状态判定 ✓】等待状态离开「等待战略层…」：已回复(=成功) 或 以『错误』开头(=失败)
		var st_wait: int = await _wait_settled(300.0)
		var got := _history_text(history)
		baseline = got
		var line := _last_assistant_line(history)
		# 失败 ⇒ 重问（最多 3 次 ✓，因为 invalid_output/empty_output 约占一半 ✗）
		var tries := 0
		while st_wait != 0 and tries < 3:
			tries += 1
			print("[MODEL] round=%d 第 %d 次失败，重问…" % [i + 1, tries])
			input.text = str(QUESTIONS[i])
			_page.call("_on_send")
			st_wait = await _wait_settled(300.0)
			got = _history_text(history)
			baseline = got
			line = _last_assistant_line(history)
		var st2: Label = _page.get("_chat_status")
		_replies.append({"round": i + 1, "question": QUESTIONS[i], "reply": line, "len": line.length(),
			"status": st2.text if st2 != null else ""})
		print("[MODEL] round=%d len=%d reply=%s" % [i + 1, line.length(), line.substr(0, 120).replace("\n", " ")])
	_check(_replies.size() == 5, "应有 5 轮回复（实际 %d）" % _replies.size())
	var all_long := true
	var cite := 0
	for r in _replies:
		if int(r["len"]) <= 5:
			all_long = false
		var body := str(r["reply"])
		if body.contains("PlainAndSimple") or body.contains("出生点") or body.contains("208") or body.contains("40"):
			cite += 1
	_check(all_long, "每轮回复长度必须 >5 ✓")
	_check(cite >= 2, "至少 2 轮必须引用地图事实（实际 %d）" % cite)
	var payload := {"probe": "strategic-model-rounds", "map": "PlainAndSimple", "spawn_index": 0,
		"replies": _replies, "rounds_with_map_facts": cite, "failures": _failures}
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://agent/runs/2026-10-06-strategic-prebattle-ui-map/"))
	var f := FileAccess.open(ProjectSettings.globalize_path(OUT), FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(payload, "  "))
		f.close()
	_finish(0 if _failures == 0 else 1)


## 等状态离开「等待」：返回 0=成功（已回复）1=失败（错误）2=超时 ✓
func _wait_settled(timeout_s: float) -> int:
	var st: Label = _page.get("_chat_status")
	var t0 := Time.get_ticks_msec()
	while float(Time.get_ticks_msec() - t0) / 1000.0 < timeout_s:
		await get_tree().process_frame
		if st == null:
			return 2
		var txt := st.text
		if txt.contains("已回复"):
			return 0
		if txt.contains("错误") or txt.contains("降级"):
			return 1
	return 2


func _history_text(history: VBoxContainer) -> String:
	var s := ""
	if history == null:
		return s
	for child in history.get_children():
		if child is RichTextLabel:
			s += (child as RichTextLabel).text + "\n"
		elif child is Label:
			s += (child as Label).text + "\n"
	return s


func _last_assistant_line(history: VBoxContainer) -> String:
	# 【口径修正】只认**最后一行**且必须是副官行 ✓（欢迎语已不在最后时自然被排除 ✓）
	var last := ""
	if history == null:
		return last
	for child in history.get_children():
		var txt := ""
		if child is RichTextLabel:
			txt = (child as RichTextLabel).text
		elif child is Label:
			txt = (child as Label).text
		if not txt.is_empty():
			last = txt
	if last.begins_with("副官："):
		var body := last.substr("副官：".length())
		if body.contains("讨论室就绪") or body.contains("你选择了出生点"):
			return ""
		return body
	return ""


func _wait_reply(history: VBoxContainer, baseline: String, timeout_s: float) -> String:
	var t0 := Time.get_ticks_msec()
	while float(Time.get_ticks_msec() - t0) / 1000.0 < timeout_s:
		await get_tree().process_frame
		var now := _history_text(history)
		if now != baseline and _last_assistant_line(history) != "":
			return now
	return baseline


func _check(cond: bool, msg: String) -> void:
	if cond:
		print("[MODEL] OK: " + msg)
	else:
		_failures += 1
		push_error("[MODEL] FAIL: " + msg)


func _finish(code: int) -> void:
	print("Strategic model rounds completed: %d failure(s), %d replies" % [_failures, _replies.size()])
	get_tree().quit(code)
