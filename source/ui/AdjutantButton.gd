extends Node

## AI 副官按钮组：对局 HUD 右上角的"AI 接管/停止"开关 + 连通性测试
## + 左上角实时思考状态面板（轮询副官会话日志尾部）。
## 点击 → HTTP POST 到服务器副官 daemon（nginx /adjutant/ 反代）→
## 启停 Hermes 副官会话（它以 as_player 身份通过服务器权威端点指挥你的部队）。
## 纯 UI 便利层：不参与任何玩法逻辑，随时可拆。

const SERVER_URL := "http://101.43.121.102/adjutant"
const TOKEN := "AIRTS-ADJ-7c91f2x9"
const TAIL_INTERVAL := 5.0

## 副官动作关键词 → 玩家可读状态（rts_ctl 的 op 名 / 命令行）。
const ACTION_LABELS := {
	"status": "正在观察战况",
	"move": "正在机动",
	"gather": "正在发展经济",
	"build": "正在建造",
	"produce": "正在生产",
	"attack": "正在交战",
	"sleep": "等待下一轮战况",
}

## 服务器回执/错误关键词 → 玩家可读执行结果（比较时统一转小写）。
const RESULT_LABELS := {
	"accepted": "命令已被服务器接受",
	"partiallyaccepted": "部分单位已接受命令",
	"pendingauthority": "等待服务器确认",
	"insufficientresources": "资源不足，暂缓执行",
	"queuefull": "生产队列已满",
	"productnotallowed": "生产建筑不匹配",
	"producernotfound": "找不到生产建筑",
	"targetnotfound": "还没发现这个目标，需要先侦察",
	"unitsnotfound": "没有可执行的单位",
	"resourcenotfound": "附近没有可采集的资源点",
	"定义未找到": "暂不支持生产这个单位",
	"definitionnotfound": "暂不支持生产这个单位",
	"occupied": "放置位置被占用，换个位置试试",
	"surfacenotbuildable": "这里不能建造，换块平地",
	"weaponcannottargetdomain": "武器打不了这种目标（对空/对地不匹配）",
	"nogateway": "副官暂时无法下达命令",
	"nonetsync": "对局网络层还没就绪",
	"调用失败": "上一条命令没有执行",
	"error": "上一条命令没有执行",
}

const PANEL_UNKNOWN := "副官正在整理战况"
const PANEL_IDLE := "副官尚未启动"
const PANEL_CONNECTING := "正在连接战场"
const PANEL_DASH := "—"

var _button: Button
var _test_button: Button
var _http: HTTPRequest
var _test_http: HTTPRequest
var _tail_http: HTTPRequest
var _active := false
var _installed := false
var _test_timer: Timer
var _tail_timer: Timer
var _panel: PanelContainer
var _state_label: Label
var _action_label: Label
var _reason_label: Label
var _result_label: Label

## 正则：op 关键词（词边界防误报）+ 内部路径/命令参数清洗。
var _op_regex: RegEx = RegEx.create_from_string("\\b(status|move|gather|build|produce|attack|sleep)\\b")
var _path_regex: RegEx = RegEx.create_from_string("(res://|file:///|/home/|/tmp/)[^\\s]*")
var _kv_regex: RegEx = RegEx.create_from_string("\\b(as_player|units|dest|scene|kind|unit|target|pos|path|op|port|token)\\s*=\\s*\\S*")


func _ready() -> void:
	get_tree().node_added.connect(_on_node_added)


func _on_node_added(node: Node) -> void:
	# 对局场景根节点名固定为 Match（跨进程确定性命名）。
	if node.name != "Match" or _installed:
		return
	_installed = true
	# 等场景树安定后再装按钮（节点刚 add 时子树可能未全）。
	_install.call_deferred(node)
	# 对局结束返回主菜单后允许再次安装（下局再用）。
	node.tree_exiting.connect(func(): _installed = false)


func _install(match_node: Node) -> void:
	var hud: CanvasLayer = match_node.get_node_or_null("HUD")
	if hud == null:
		_installed = false
		return
	_button = Button.new()
	_button.text = "AI 副官：接管"
	_button.tooltip_text = "让服务器上的 Hermes AI 全权托管本局（采集/建造/出兵/进攻）"
	_button.position = Vector2(470, 8)
	_button.z_index = 100
	hud.add_child(_button)
	_button.pressed.connect(_on_pressed)

	_test_button = Button.new()
	_test_button.text = "副官连通测试"
	_test_button.tooltip_text = "测试：本客户端 → 服务器 daemon → 游戏权威端点 全链路"
	_test_button.position = Vector2(620, 8)
	_test_button.z_index = 100
	hud.add_child(_test_button)
	_test_button.pressed.connect(_on_test_pressed)

	# 左上角实时思考状态面板：始终显示（监督服务器端 hermes 副官）。
	_panel = PanelContainer.new()
	_panel.position = Vector2(8, 36)
	_panel.custom_minimum_size = Vector2(280, 180)
	_panel.size = Vector2(280, 180)
	_panel.visible = true
	_panel.z_index = 100
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.05, 0.08, 0.12, 0.82)
	style.border_color = Color(0.3, 0.8, 1.0, 0.7)
	style.set_border_width_all(1)
	style.set_corner_radius_all(4)
	style.content_margin_left = 8.0
	style.content_margin_right = 8.0
	style.content_margin_top = 5.0
	style.content_margin_bottom = 5.0
	_panel.add_theme_stylebox_override("panel", style)
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 1)
	_panel.add_child(vbox)
	var title := Label.new()
	title.text = "🔹 AI 副官"
	title.add_theme_font_size_override("font_size", 12)
	title.add_theme_color_override("font_color", Color(0.3, 0.85, 1.0))
	vbox.add_child(title)
	_state_label = _make_panel_label()
	_action_label = _make_panel_label()
	_reason_label = _make_panel_label()
	_result_label = _make_panel_label()
	vbox.add_child(_state_label)
	vbox.add_child(_action_label)
	vbox.add_child(_reason_label)
	vbox.add_child(_result_label)
	hud.add_child(_panel)
	_set_panel_texts(PANEL_IDLE, PANEL_DASH, PANEL_DASH, PANEL_DASH)

	_http = HTTPRequest.new()
	_http.timeout = 10.0
	add_child(_http)
	_test_http = HTTPRequest.new()
	_test_http.timeout = 15.0
	add_child(_test_http)
	_tail_http = HTTPRequest.new()
	_tail_http.timeout = 10.0
	add_child(_tail_http)

	_test_timer = Timer.new()
	_test_timer.one_shot = true
	_test_timer.timeout.connect(_restore_test_button)
	add_child(_test_timer)

	_tail_timer = Timer.new()
	_tail_timer.wait_time = TAIL_INTERVAL
	_tail_timer.timeout.connect(_poll_tail)
	add_child(_tail_timer)
	_tail_timer.start()
	_query_status()


func _on_pressed() -> void:
	if _http == null:
		return
	_button.disabled = true
	_button.text = "AI 副官：通信中…"
	var action := "stop" if _active else "takeover"
	var body := JSON.stringify({"token": TOKEN, "action": action})
	var err := _http.request(
		SERVER_URL + "/control",
		["Content-Type: application/json"],
		HTTPClient.METHOD_POST,
		body,
	)
	if err != OK:
		_restore_button()
		return
	var result: Array = await _http.request_completed
	if result[0] != HTTPRequest.RESULT_SUCCESS or result[1] != 200:
		push_warning("[ADJ] 副官控制请求失败: %s" % str(result[1]))
		_restore_button()
		return
	_active = action == "takeover"
	_restore_button()


func _on_test_pressed() -> void:
	if _test_http == null:
		return
	_test_button.disabled = true
	_test_button.text = "测试中…"
	_test_button.modulate = Color.WHITE
	var body := JSON.stringify({"token": TOKEN, "action": "ping"})
	var err := _test_http.request(
		SERVER_URL + "/control",
		["Content-Type: application/json"],
		HTTPClient.METHOD_POST,
		body,
	)
	if err != OK:
		_show_test_result(false, "✗ 发送失败", Color(1, 0.4, 0.4))
		return
	var result: Array = await _test_http.request_completed
	if result[0] != HTTPRequest.RESULT_SUCCESS or result[1] != 200:
		_show_test_result(false, "✗ 服务器不可达", Color(1, 0.4, 0.4))
		return
	var parsed = JSON.parse_string(result[3].get_string_from_utf8())
	if not (parsed is Dictionary):
		_show_test_result(false, "✗ 响应异常", Color(1, 0.4, 0.4))
		return
	if not bool(parsed.get("game_alive", false)):
		_show_test_result(false, "✗ 游戏端点未响应", Color(1, 0.4, 0.4))
		return
	var suffix := "通·无对局"
	if bool(parsed.get("match", false)):
		suffix = "对局中·%d单位" % int(parsed.get("units", 0))
	var ms := int(parsed.get("latency_ms", -1))
	if ms >= 0:
		suffix += " · %dms" % ms
	_show_test_result(true, "✓ 全链路已通 %s" % suffix, Color(0.5, 1.0, 0.5))


func _show_test_result(good: bool, text: String, color: Color) -> void:
	_test_button.text = text
	_test_button.modulate = color
	_test_button.disabled = false
	_test_timer.start(4.0)


func _restore_test_button() -> void:
	if _test_button == null or not is_instance_valid(_test_button):
		return
	_test_button.text = "副官连通测试"
	_test_button.modulate = Color.WHITE


## 轮询副官会话日志尾部 → 刷新左上角状态面板。
## 面板始终可见（监督模式）：未启动显示"副官尚未启动"；接管中把日志尾部
## 解析成四类玩家可读信息（当前状态/最近行动/为什么/执行结果），
## 不再直接显示服务器原始日志。
func _poll_tail() -> void:
	if _tail_http == null or _panel == null:
		return
	if not _active:
		_set_panel_texts(PANEL_IDLE, PANEL_DASH, PANEL_DASH, PANEL_DASH)
		return
	# HTTPRequest 同时只能一个请求，上一轮没回来就跳过本轮。
	if _tail_http.get_http_client_status() != HTTPClient.STATUS_DISCONNECTED:
		return
	var body := JSON.stringify({"token": TOKEN, "action": "tail"})
	var err := _tail_http.request(
		SERVER_URL + "/control",
		["Content-Type: application/json"],
		HTTPClient.METHOD_POST,
		body,
	)
	if err != OK:
		return
	var result: Array = await _tail_http.request_completed
	if not _active or _panel == null or not is_instance_valid(_panel):
		return
	if result[0] != HTTPRequest.RESULT_SUCCESS or result[1] != 200:
		_set_panel_texts("暂时联系不上服务器", PANEL_DASH, PANEL_DASH, PANEL_DASH)
		return
	var parsed = JSON.parse_string(result[3].get_string_from_utf8())
	if not (parsed is Dictionary):
		_set_panel_texts(PANEL_UNKNOWN, PANEL_DASH, PANEL_DASH, PANEL_DASH)
		return
	var lines: Array = parsed.get("lines", [])
	if lines.is_empty():
		_set_panel_texts(PANEL_CONNECTING, PANEL_DASH, PANEL_DASH, PANEL_DASH)
	else:
		_apply_digest(_digest_lines(lines))
	_panel.visible = true


func _query_status() -> void:
	if _http == null:
		return
	var err := _http.request(SERVER_URL + "/status")
	if err != OK:
		return
	var result: Array = await _http.request_completed
	if result[0] == HTTPRequest.RESULT_SUCCESS and result[1] == 200:
		var parsed = JSON.parse_string(result[3].get_string_from_utf8())
		if parsed is Dictionary:
			_active = bool(parsed.get("running", false))
			_restore_button()


func _restore_button() -> void:
	if _button == null or not is_instance_valid(_button):
		return
	_button.disabled = false
	_button.text = "AI 副官：停止" if _active else "AI 副官：接管"
	_button.modulate = Color(1.0, 0.55, 0.55) if _active else Color.WHITE


## ---------- 日志尾部 → 玩家可读四类信息 ----------

## 把日志行数组解析成 {state, action, why, result}，全部为玩家可读中文。
## 兼容 JSON 事件行（{"type":"cmd","text":...}）与普通文本行；
## 解析不出的内容不参与显示，未知日志最终回落到"副官正在整理战况"。
func _digest_lines(lines: Array) -> Dictionary:
	var action := ""
	var result := ""
	var why := ""
	# 从最新一行往前扫：最先命中的就是"最近"的信息。
	for i in range(lines.size() - 1, -1, -1):
		var text := _extract_log_text(str(lines[i]))
		if text.is_empty():
			continue
		var lower := text.to_lower()
		if result.is_empty():
			result = _match_result(lower)
		if action.is_empty():
			action = _match_action(lower, text)
		if why.is_empty():
			why = _match_reason_text(text)
	var state := ""
	if result == str(RESULT_LABELS["pendingauthority"]):
		state = result
	elif not action.is_empty():
		state = action
	if state.is_empty():
		state = PANEL_UNKNOWN
	return {
		"state": state,
		"action": action if not action.is_empty() else PANEL_DASH,
		"why": why if not why.is_empty() else "根据当前战况决定",
		"result": result if not result.is_empty() else "暂无新结果",
	}


## 兼容两类日志行：JSON 事件行取其 text/message 字段，普通文本原样返回。
func _extract_log_text(raw: String) -> String:
	var text := raw.strip_edges()
	if text.begins_with("{"):
		var parsed = JSON.parse_string(text)
		if parsed is Dictionary:
			for key in ["text", "message", "content", "cmd", "line"]:
				var value = parsed.get(key, "")
				if typeof(value) == TYPE_STRING and not (value as String).strip_edges().is_empty():
					return (value as String).strip_edges()
			return ""
	return text


## 动作识别：命令行（含参数标记）优先，普通文本提及 op 关键词兜底。
func _match_action(lower: String, original: String) -> String:
	var op := _op_keyword(lower)
	if op.is_empty():
		return ""
	if op == "move" and (original.contains("侦察") or lower.contains("scout") or lower.contains("drone")):
		return "正在侦察"
	return str(ACTION_LABELS.get(op, ""))


## 在小写文本里找 op 关键词（词边界正则，防 "look" 误报 "ok" 一类的子串问题）。
func _op_keyword(lower: String) -> String:
	var matches := _op_regex.search_all(lower)
	if matches.is_empty():
		return ""
	return str(matches[0].get_string())


## 结果识别：回执/错误关键词 → 中文；accepted/ok 的成功形态 → 已确认。
func _match_result(lower: String) -> String:
	for key in RESULT_LABELS:
		if lower.contains(str(key)):
			return str(RESULT_LABELS[key])
	var packed := lower.replace(" ", "").replace("'", "\"")
	if packed.contains("\"accepted\":true") or packed.contains("accepted=true") \
			or packed.contains("\"ok\":true") or packed.contains("ok=true"):
		return "服务器已确认执行"
	return ""


## 理由识别：取最近一条"非命令、非回执"的自然语言短句（如副官的复盘文字）。
func _match_reason_text(text: String) -> String:
	var lower := text.to_lower()
	if _match_result(lower) != "":
		return ""
	if _looks_like_command_line(text) and _op_keyword(lower) != "":
		return ""
	var cleaned := _clean_text(text)
	if cleaned.length() < 4 or cleaned.length() > 80:
		return ""
	return cleaned


## 命令行特征：带键值参数或 JSON 事件标记。
func _looks_like_command_line(text: String) -> bool:
	return text.contains("=") or text.contains("=\"") or text.contains("'") \
		or text.contains("res://") or text.contains("[\"")


## 净化玩家可见文本：剥掉内部路径、命令参数、JSON 痕迹，截断到一行。
func _clean_text(text: String) -> String:
	var cleaned := _path_regex.sub(text, " ", true)
	cleaned = _kv_regex.sub(cleaned, " ", true)
	for junk in ["{", "}", "[", "]", "(", ")", "\"", "'", "`", ":"]:
		cleaned = cleaned.replace(junk, " ")
	cleaned = " ".join(cleaned.split(" ", false))
	if cleaned.length() > 48:
		cleaned = cleaned.substr(0, 48) + "…"
	return cleaned.strip_edges()


func _make_panel_label() -> Label:
	var label := Label.new()
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.custom_minimum_size = Vector2(264, 0)
	label.add_theme_font_size_override("font_size", 12)
	label.add_theme_color_override("font_color", Color(0.88, 0.94, 1.0))
	return label


func _apply_digest(digest: Dictionary) -> void:
	_set_panel_texts(
		str(digest.get("state", PANEL_UNKNOWN)),
		str(digest.get("action", PANEL_DASH)),
		str(digest.get("why", "根据当前战况决定")),
		str(digest.get("result", "暂无新结果")),
	)


func _set_panel_texts(state_text: String, action_text: String, why_text: String, result_text: String) -> void:
	if _state_label == null or not is_instance_valid(_state_label):
		return
	_state_label.text = "当前状态：%s" % state_text
	_action_label.text = "最近行动：%s" % action_text
	_reason_label.text = "为什么：%s" % why_text
	_result_label.text = "执行结果：%s" % result_text
