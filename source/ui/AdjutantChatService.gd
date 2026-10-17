extends Node

## 战略聊天适配层（2026-10-02 阶段 1：游戏内与战略层对话）。
##
## 职责边界（阶段 1 唯一目标）：
##   面板（AdjutantButton 的聊天区）→ 本适配层 → 本地战略模型（Ollama OpenAI 兼容端点）。
##   只返回**纯文本**战略讨论；不产生任何单位命令、资源扣除、任务/租约/决策模型调用。
##   本文件是 UI 到战略模型之间的**唯一**调用者：面板不得直接拼模型请求。
##
## 语义契约（请求）：
##   { request_id, conversation_id, match_id, player_id, paused, message, history_tail }
## 响应（成功）：
##   { ok:true, request_id, conversation_id, assistant_text, model, elapsed_ms }
## 失败：稳定 error_code（http_xxx / timeout / empty_output / invalid_output /
##   model_unavailable / sending_in_progress / empty_message）+ 中文说明（面板展示用）。
##
## 并发规则：同一会话最多一个在途请求；迟到响应按 request_id 丢弃；会话按 match 绑定，
## 换局由面板重新 setup（新 conversation_id、清历史）。暂停下仍可聊天（PROCESS_MODE_ALWAYS），
## 且聊天只发生在玩家操作时——没有轮询，也从不触碰模拟时间。

const ModelService := preload("res://source/ui/AdjutantModelService.gd")

## 单次请求超时（秒）。本地 2B 模型长回复实测 ~10-30s，取 60s 留余量。
const REQUEST_TIMEOUT_S := 60.0
## 末尾锚定：每条请求消息序列的最后一条 system（recency 位置）。
const END_OF_CONTEXT_REMINDER := "只回答用户刚才那条问题；讨论战略；引用 [战局摘要] 的具体数据；不得重复上一轮的回答。"

## 实例级超时（测试/特殊部署可覆盖；产品路径等于 REQUEST_TIMEOUT_S）。
var request_timeout_s := REQUEST_TIMEOUT_S
## 紧凑战局摘要 provider（只读）：返回一行战局事实文本，附加到上下文。
## 由面板注入（读活的对局树：资源/单位计数/可见敌情/模拟时间）；不设置则只有身份/状态行。
## 提示词 §4 口径："可用的安全战局摘要（若已有稳定只读来源）……没有可靠状态时宁可标记不可用"。
var context_provider: Callable = Callable()
## 随请求带上的历史轮数上限（每轮 = 一问一答）。紧凑上下文，不塞完整大 JSON。
## 6→4：2B 模型长历史会稀释摘要注意力（实测 30 轮后引用率 1/3），4 轮够回指。
const HISTORY_TAIL_TURNS := 4
## 会话历史保留轮数（超过后丢弃最老的；tail 从这里取）。
const HISTORY_KEEP_TURNS := 20
## 战略聊天结构化日志（请求/响应/错误一条一行的 jsonl）。
const LOG_PATH := "user://adjutant_logs/strategic_chat.jsonl"

## 收到回复/失败后发出（面板据此更新消息区与状态）。
signal reply_ready(result: Dictionary)
## 首条成功回复后发出一次（面板刷新顶部状态文案：战略聊天可用）。
signal model_confirmed_ready(model: String)

var match_id := ""
var player_id := ""
var conversation_id := ""
## 对话历史：[{role:"user"/"assistant", content:String}]
var history: Array = []
var _inflight_request_id := ""
var _inflight_started_ms := 0
## 防逐字重复：成功回复与上一条相同时，带提示自动重试一次（仅一次）。
var _retry_attempted := false
## 模型预热期间的排队消息（ready 后自动发送）；空 = 无排队。
var _warming_queued_message := ""
var _warming_poll_timer: Timer = null
var _last_messages: Array = []
var _last_assistant_text := ""
## 最近一次失败/成功的 error_code（""=无）；测试与面板诊断读它。
var _last_error_code := ""
var _http: HTTPRequest
## 测试/桩模型端点覆盖：非空时 send() 用它而不是 ModelService.endpoint()。
## 产品路径永远为空（唯一口径是 AdjutantModelService）。
var endpoint_override := ""
var _request_counter := 0


func _ready() -> void:
	# 暂停时聊天照常：模型等待与面板输入都不受 tree.pause 影响。
	process_mode = Node.PROCESS_MODE_ALWAYS
	_http = HTTPRequest.new()
	_http.timeout = request_timeout_s
	add_child(_http)
	_http.request_completed.connect(_on_request_completed)


## 绑定一局会话：换 Match 必须重新 setup（新 conversation_id、清历史）。
func setup(new_match_id: String, new_player_id: String) -> void:
	match_id = new_match_id
	player_id = new_player_id
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	conversation_id = "chat-conv-%s-%04d" % [new_match_id, rng.randi() % 10000]
	history.clear()
	_inflight_request_id = ""
	_log_event("session_setup", {"conversation_id": conversation_id, "match_id": match_id})


func is_busy() -> bool:
	return not _inflight_request_id.is_empty()


## 当前会话的历史尾部（供契约里的 history_tail；最多 HISTORY_TAIL_TURNS 轮）。
func history_tail() -> Array:
	var turns: Array = []
	var start: int = maxi(0, history.size() - HISTORY_TAIL_TURNS)
	for i in range(start, history.size()):
		turns.append({"role": str(history[i].get("role")), "content": str(history[i].get("content"))})
	return turns


## 发送一条玩家消息。返回 {queued:bool, error_code:String}：
## queued=false 时 error_code 说明拒绝原因（空消息 / 已有在途请求）。
## 真正的结果经 `reply_ready` 信号异步返回。
func send(player_text: String) -> Dictionary:
	var text := player_text.strip_edges()
	if text.is_empty():
		return {"queued": false, "error_code": "empty_message"}
	if is_busy():
		return {"queued": false, "error_code": "sending_in_progress"}
	# 【2026-10-04 P0-1】模型 starting/warming 时不发 HTTP：模型冷加载期间请求会超时。
	# 排队消息，ready 后自动发送（面板显示预热状态并禁用输入）。
	if ModelService.state() in ["starting", "warming"]:
		_warming_queued_message = text
		_start_warming_poll()
		return {"queued": true, "error_code": "", "warming": true}
	if ModelService.endpoint().is_empty():
		return {"queued": false, "error_code": "model_unavailable"}

	_request_counter += 1
	var request_id := "chat-%s-%04d" % [
		conversation_id.substr(conversation_id.length() - 4), _request_counter]
	var payload := build_payload(request_id, conversation_id, match_id, player_id,
		_match_paused(), text, history_tail())
	# 消息序列：[角色/约束][战局摘要] + 历史 + [当前问题] + [末尾锚定]。
	# 末尾锚定放最后：2B 模型对长对话开头的 system 会失焦（实测 30 轮后引用率掉到 1/3），
	# recency 位置的小提醒最有效。
	var messages: Array = [
		{"role": "system", "content": strategic_system_prompt()},
		{"role": "system", "content": compact_context()},
	]
	for h in history_tail():
		messages.append({"role": str(h.get("role")), "content": str(h.get("content"))})
	messages.append({"role": "user", "content": text})
	messages.append({"role": "system", "content": END_OF_CONTEXT_REMINDER})
	var body := JSON.stringify({
		"model": ModelService.model_name(),
		"messages": messages,
		"temperature": 0.65,
		"max_tokens": 512,
	})
	_inflight_request_id = request_id
	_inflight_started_ms = Time.get_ticks_msec()
	_retry_attempted = false
	_last_messages = messages.duplicate(true)
	_log_event("request", {
		"request_id": request_id, "conversation_id": conversation_id,
		"match_id": match_id, "player_id": player_id,
		"paused": payload["paused"], "message": text,
		"history_turns": payload["history_tail"].size(),
		"model": ModelService.model_name(),
	})
	var target_endpoint: String = (endpoint_override
		if not endpoint_override.is_empty() else ModelService.endpoint())
	_http.timeout = request_timeout_s
	var err: int = _http.request(
		target_endpoint + "/chat/completions",
		PackedStringArray(["Content-Type: application/json", "Authorization: Bearer local"]),
		HTTPClient.METHOD_POST, body)
	if err != OK:
		# 【2026-10-06 修复·根因】HTTPRequest 正忙（ERR_BUSY）= **已有在途请求** ⇒
		# 此时清空 _inflight_request_id 会让那个**合法响应**被误判为"迟到"而丢弃 ✗
		# （实测日志 late_response_dropped status_code=200 反复出现 ⇒ UI 永远停在「等待战略层…」）。
		# 因此：只有确实**没派发出去**（非 ERR_BUSY）才清空 ✓；正忙时保留 id ✓，原响应照常投递 ✓。
		if err != ERR_BUSY:
			_inflight_request_id = ""
		_log_event("error", {"request_id": request_id, "error_code": "request_dispatch_failed",
			"err": err, "kept_inflight": err == ERR_BUSY})
		return {"queued": false, "error_code": "request_dispatch_failed"}
	history.append({"role": "user", "content": text})
	_trim_history()
	return {"queued": true, "error_code": "", "request_id": request_id}


## 关闭面板/换局/退出时：把在途请求标记为陈旧（迟到回复按 id 丢弃）。
func cancel_pending() -> void:
	if is_busy():
		_log_event("cancel", {"request_id": _inflight_request_id})
		_inflight_request_id = ""
		_http.cancel_request()


## 语义契约（唯一实现，供单测对照）：
## { request_id, conversation_id, match_id, player_id, paused, message, history_tail }
static func build_payload(request_id: String, conversation_id: String, match_id: String,
		player_id: String, paused: bool, message: String, history_tail: Array) -> Dictionary:
	return {
		"request_id": request_id,
		"conversation_id": conversation_id,
		"match_id": match_id,
		"player_id": player_id,
		"paused": paused,
		"message": message,
		"history_tail": history_tail,
	}


## 战略聊天 system prompt（阶段 1）：只讨论战略，不得声称执行任何动作。
static func strategic_system_prompt() -> String:
	return "".join([
		"你是 RTS 游戏《AI_RTS》里玩家身边的战略讨论副官。你的职责：分析战略目标、风险、",
		"资源取舍和可能的战略方向；可以提出建议与澄清问题。\n",
		"《AI_RTS》是一款沙盘 RTS：双方基地、资源点A、坦克/重坦/步兵/无人机/防御塔，",
		"没有英雄、泉水、兵线或野区。\n",
		"硬性约束：\n",
		"1. 你只讨论战略，绝对没有下达命令、控制单位、修改任务或执行计划的能力；",
		"回复中不得出现已执行、已下令、已派遣等表述。\n",
		"2. 回答必须引用 [战局摘要] 里的具体数据（资源数字、单位构成、敌情方位/距离、",
		"射程），先摆事实再给判断；禁止输出持续关注敌方动向、加强防御这类没有数据支撑的空话。\n",
		"3. 摘要里没有的信息（敌方基地位置、隐藏单位、确切意图）要明确说摘要中没有，",
		"不要编造敌情、资源、路径或单位能力；可以告诉玩家需要什么情报。\n",
		"4. 涉及能否交战/威胁多大时，用射程和距离判断（例：敌方对地塔射程 16m，",
		"我方坦克射程 7.5m，打塔必须先进它的圈）。\n",
		"5. 用简体中文回复，先结论后理由，不超过 200 字；允许用短列表。",
		"6. 每一轮都直接回答当前的问题，不要复述或微调上一轮的回答。",
	])


## 紧凑战局上下文（阶段 1 只带身份/状态/模式 + 可选的一行战局摘要，不塞完整大 JSON）。
func compact_context() -> String:
	var parts: Array = [
		"[当前对局] match=%s 玩家=%s %s 阶段=战略讨论（无计划结构化输出，只对话）" % [
			match_id, player_id,
			("已暂停（战局时间冻结，可正常讨论）" if _match_paused() else "运行中"),
		],
	]
	if context_provider.is_valid():
		var summary: String = str(context_provider.call()).strip_edges()
		if not summary.is_empty():
			parts.append("[战局摘要] " + summary)
		else:
			parts.append("[战局摘要] 当前状态不可用（不要编造战局数据）")
	else:
		# 无 provider（如纯聊天/测试）：必须显式声明"没有摘要"，
		# 否则"必须引用摘要"的指令会逼模型编造假数据（实测：编出 12km/16m/15 辆坦克）。
		parts.append("[战局摘要] 暂无。需要什么战局数据请直接向玩家说明，不要编造、不要复述本行。")
	return "".join(parts)


## 解析模型回执（纯函数，供单测）。任何失败都返回稳定 error_code：
##   ok=true → {ok, assistant_text}
##   失败 → {ok:false, error_code: http_502/empty_output/invalid_output}
static func parse_chat_completion(status_code: int, body_text: String) -> Dictionary:
	if status_code != 200:
		return {"ok": false, "error_code": "http_%d" % status_code}
	# 静默解析（2026-10-04 复核第 2 项收尾）：改用 JSON 实例的 parse()——它**不向引擎日志**
	# 打印解析错误（JSON.parse_string 会），错误码与数据由调用方读取。
	# 错误语义不变：一切语法错误/顶层类型错误/缺 choices/message/content 都是 invalid_output。
	var trimmed := body_text.strip_edges()
	if trimmed.is_empty():
		return {"ok": false, "error_code": "invalid_output"}
	var json := JSON.new()
	var parse_err := json.parse(trimmed)
	if parse_err != OK:
		return {"ok": false, "error_code": "invalid_output"}
	var parsed = json.get_data()
	if not parsed is Dictionary:
		return {"ok": false, "error_code": "invalid_output"}
	var choices = parsed.get("choices")
	if not choices is Array or (choices as Array).is_empty():
		return {"ok": false, "error_code": "invalid_output"}
	var message = (choices as Array)[0].get("message") if choices[0] is Dictionary else null
	if not message is Dictionary:
		return {"ok": false, "error_code": "invalid_output"}
	var content = (message as Dictionary).get("content")
	if not content is String:
		# 缺 content 键是结构错误（invalid_output，2026-10-04 复核第 2 项语义拆分）
		return {"ok": false, "error_code": "invalid_output"}
	if (content as String).strip_edges().is_empty():
		# content 键存在但值是空白/空串 → empty_output
		return {"ok": false, "error_code": "empty_output"}
	return {"ok": true, "assistant_text": (content as String).strip_edges()}


## HTTP 完成（成功/失败/超时共用）。request_id 不匹配 = 迟到响应，丢弃并记日志。
func _on_request_completed(_res: int, status_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	var request_id := _inflight_request_id
	_inflight_request_id = ""
	var elapsed_ms: int = Time.get_ticks_msec() - _inflight_started_ms
	_last_error_code = "" if request_id.is_empty() else "pending"
	if request_id.is_empty():
		_log_event("late_response_dropped", {"status_code": status_code, "elapsed_ms": elapsed_ms})
		return
	var outcome := {"ok": false, "error_code": "timeout"}
	if _res == HTTPRequest.RESULT_TIMEOUT:
		outcome = {"ok": false, "error_code": "timeout"}
	elif _res in [
		HTTPRequest.RESULT_CANT_CONNECT, HTTPRequest.RESULT_CANT_RESOLVE,
		HTTPRequest.RESULT_CONNECTION_ERROR,
	]:
		# 连不上本地模型（服务没起/端口不对）：明确降级，不冒充超时。
		outcome = {"ok": false, "error_code": "model_unavailable"}
	elif status_code > 0:
		outcome = parse_chat_completion(status_code, body.get_string_from_utf8())
	if outcome.get("ok", false):
		var text := str(outcome.get("assistant_text", ""))
		# 前缀包含（逐字重复或仅扩写）都算退化；≥20 字避免短句误判。
		var is_duplicate := (not _last_assistant_text.is_empty()
			and _last_assistant_text.length() >= 20
			and (text.begins_with(_last_assistant_text)
				or _last_assistant_text.begins_with(text)))
		if is_duplicate and not _retry_attempted:
			# 2B 模型偶发逐字重复退化（实测 30 轮中 4 次）：带提示重试一次，仅一次。
			_retry_attempted = true
			_inflight_request_id = request_id
			_inflight_started_ms = Time.get_ticks_msec()
			_log_event("repeat_retry", {"request_id": request_id})
			var messages: Array = _last_messages.duplicate(true)
			for i in range(messages.size() - 1, -1, -1):
				if str(messages[i].get("role")) == "system":
					messages[i]["content"] = "你上一条回复与之前的重复了。请针对用户刚提的新问题，换一个角度给出全新的回答。"
					break
			_http.timeout = request_timeout_s
			var retry_endpoint: String = (endpoint_override
				if not endpoint_override.is_empty() else ModelService.endpoint())
			var retry_err: int = _http.request(retry_endpoint + "/chat/completions",
				PackedStringArray(["Content-Type: application/json", "Authorization: Bearer local"]),
				HTTPClient.METHOD_POST, JSON.stringify({
					"model": ModelService.model_name(), "messages": messages,
					"temperature": 0.8, "max_tokens": 512,
				}))
			if retry_err != OK:
				_inflight_request_id = ""
			return
		history.append({"role": "assistant", "content": text})
		_last_assistant_text = text
		_trim_history()
		# 首条成功回复即证明本地模型端点+模型可用：把模型服务状态推到 ready，
		# 面板顶部文案随之从"副官尚未启动"切到"战略聊天可用"（2026-10-04 复核第 3 项）。
		if not ModelService.is_ready():
			ModelService.mark_ready(ModelService.model_name())
			model_confirmed_ready.emit(ModelService.model_name())
		var payload := {
			"ok": true, "request_id": request_id, "conversation_id": conversation_id,
			"assistant_text": text, "model": ModelService.model_name(), "elapsed_ms": elapsed_ms,
		}
		_log_event("response", {
			"request_id": request_id, "conversation_id": conversation_id,
			"match_id": match_id, "model": payload["model"],
			"elapsed_ms": elapsed_ms, "assistant_chars": text.length(),
		})
		reply_ready.emit(payload)
		return
	var error_code := str(outcome.get("error_code", "invalid_output"))
	_last_error_code = error_code
	_log_event("error", {
		"request_id": request_id, "conversation_id": conversation_id,
		"match_id": match_id, "error_code": error_code, "elapsed_ms": elapsed_ms,
	})
	reply_ready.emit({
		"ok": false, "request_id": request_id, "conversation_id": conversation_id,
		"assistant_text": "", "model": ModelService.model_name(), "elapsed_ms": elapsed_ms,
		"error_code": error_code,
		"message": error_text(error_code),
	})


## error_code → 面板展示的中文说明（稳定映射，供单测）。
static func error_text(error_code: String) -> String:
	match error_code:
		"timeout":
			return "等待战略层超时，可点击重试"
		"empty_output":
			return "战略层返回了空回复，可点击重试"
		"invalid_output":
			return "战略层返回了无法理解的回复，可点击重试"
		"sending_in_progress":
			return "上一条还在等待战略层回复"
		"empty_message":
			return "请先输入战略问题"
		"model_warming":
			return "模型预热中（首次约 1~2 分钟），消息将在就绪后自动发送"
		"model_unavailable":
			return "本地模型服务不可用，已降级（战斗不受影响）"
		"request_dispatch_failed":
			return "请求下发失败，请重试"
	if error_code.begins_with("http_"):
		return "战略层服务异常（HTTP %s），可点击重试" % error_code.substr(5)
	return "战略层出现未知错误，可点击重试"


func _trim_history() -> void:
	while history.size() > HISTORY_KEEP_TURNS * 2:
		history.pop_front()


## 预热轮询：模型 ready 后自动发送排队的消息（2026-10-04 P0-1）。
func _on_warming_poll() -> void:
	if not ModelService.is_ready():
		return
	if _warming_poll_timer != null:
		_warming_poll_timer.queue_free()
		_warming_poll_timer = null
	if _warming_queued_message.is_empty():
		return
	var msg := _warming_queued_message
	_warming_queued_message = ""
	send(msg)


func _start_warming_poll() -> void:
	if _warming_poll_timer != null:
		return
	_warming_poll_timer = Timer.new()
	_warming_poll_timer.wait_time = 2.0
	_warming_poll_timer.timeout.connect(_on_warming_poll)
	add_child(_warming_poll_timer)
	_warming_poll_timer.start()


func _match_paused() -> bool:
	var tree := get_tree()
	return tree != null and tree.paused


func _log_event(kind: String, fields: Dictionary) -> void:
	var record := {"ts_ms": Time.get_ticks_msec(), "kind": kind}
	for key in fields:
		record[key] = fields[key]
	var dir := ProjectSettings.globalize_path("user://adjutant_logs")
	if not DirAccess.dir_exists_absolute(dir):
		DirAccess.make_dir_recursive_absolute(dir)
	var handle := FileAccess.open(LOG_PATH, FileAccess.READ_WRITE)
	if handle == null:
		handle = FileAccess.open(LOG_PATH, FileAccess.WRITE)
	if handle == null:
		return
	handle.seek_end()
	handle.store_line(JSON.stringify(record, "", false, true))
	handle.close()
