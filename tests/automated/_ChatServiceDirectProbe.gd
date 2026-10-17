extends Node

## 直接调用聊天服务（绕过页面 ✓）：把"模型/服务"与"页面"两层的责任分开 ✓。
## 输出：每轮的 queued / error_code / assistant_text / 状态 ✓。

const ChatService = preload("res://source/ui/AdjutantChatService.gd")
const ModelSvc = preload("res://source/ui/AdjutantModelService.gd")
const OUT := "res://agent/runs/2026-10-06-strategic-prebattle-ui-map/service-direct.json"

var _rows: Array = []


func _process(_delta: float) -> void:
	if get_tree().paused:
		get_tree().paused = false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	get_tree().create_timer(900.0).timeout.connect(func() -> void:
		push_error("[SVC] 超时")
		_finish(2))
	await _run()


func _run() -> void:
	# 等模型就绪 ✓
	var t0 := Time.get_ticks_msec()
	while (ModelSvc.is_warming() or not ModelSvc.is_listening()) and float(Time.get_ticks_msec() - t0) / 1000.0 < 300.0:
		await get_tree().process_frame
	print("[SVC] 就绪 listening=%s warming=%s" % [str(ModelSvc.is_listening()), str(ModelSvc.is_warming())])
	ModelSvc.ensure_started(self)
	var adapter: Node = ChatService.new()
	add_child(adapter)
	adapter.setup("svc-direct-probe", "local_player")
	adapter.context_provider = Callable(self, "_ctx")
	var got: Array = []
	adapter.reply_received.connect(func(r: Dictionary) -> void: got.append(r))
	var asked := 0
	var t1 := Time.get_ticks_msec()
	while asked < 3 and float(Time.get_ticks_msec() - t1) / 1000.0 < 420.0:
		var before := got.size()
		var res: Dictionary = adapter.send("第 %d 问：根据已知地图事实，我的开局侦察顺序是什么？" % (asked + 1))
		print("[SVC] send#%d queued=%s error=%s warming=%s" % [asked + 1, str(res.get("queued")), str(res.get("error_code")), str(res.get("warming"))])
		var t2 := Time.get_ticks_msec()
		while got.size() == before and float(Time.get_ticks_msec() - t2) / 1000.0 < 120.0:
			await get_tree().process_frame
		if got.size() > before:
			var r: Dictionary = got[got.size() - 1]
			_rows.append({"round": asked + 1, "ok": bool(r.get("ok", false)), "error_code": str(r.get("error_code", "")),
				"len": str(r.get("assistant_text", "")).length(), "text": str(r.get("assistant_text", "")).substr(0, 400),
				"model": str(r.get("model", "")), "elapsed_ms": int(r.get("elapsed_ms", 0))})
			print("[SVC] round=%d ok=%s err=%s len=%d" % [asked + 1, str(r.get("ok")), str(r.get("error_code")), str(r.get("assistant_text", "")).length()])
			print("[SVC] 正文: %s" % str(r.get("assistant_text", "")).substr(0, 160).replace("\n", " "))
		else:
			_rows.append({"round": asked + 1, "ok": false, "error_code": "no_reply_within_120s", "len": 0, "text": ""})
			print("[SVC] round=%d 120 秒内无回复" % (asked + 1))
			break
		asked += 1
	var payload := {"probe": "chat-service-direct", "rows": _rows, "last_error_code": str(adapter.get("_last_error_code"))}
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://agent/runs/2026-10-06-strategic-prebattle-ui-map/"))
	var f := FileAccess.open(ProjectSettings.globalize_path(OUT), FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(payload, "  "))
		f.close()
	_finish(0)


func _ctx() -> String:
	return "[战略测试地图]\n地图=PlainAndSimple 尺寸=208x208 来源=所选地图\n玩家出生点=1 坐标=(40,28) 朝向=未知\n模式=战前讨论；不执行命令"


func _finish(code: int) -> void:
	print("Chat service direct probe completed: %d rows" % _rows.size())
	get_tree().quit(code)
