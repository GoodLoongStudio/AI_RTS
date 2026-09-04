extends Node

## AI 副官按钮组：对局 HUD 右上角的"AI 接管/停止"开关 + 连通性测试
## + 左上角实时思考状态面板（轮询副官会话日志尾部）。
## 点击 → HTTP POST 到服务器副官 daemon（nginx /adjutant/ 反代）→
## 启停 Hermes 副官会话（它以 as_player 身份通过服务器权威端点指挥你的部队）。
## 纯 UI 便利层：不参与任何玩法逻辑，随时可拆。

const SERVER_URL := "http://101.43.121.102/adjutant"
const TOKEN := "AIRTS-ADJ-7c91f2x9"
const TAIL_INTERVAL := 5.0

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
var _status_label: Label


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
	title.text = "🔹 AI 副官实时思考"
	title.add_theme_font_size_override("font_size", 12)
	title.add_theme_color_override("font_color", Color(0.3, 0.85, 1.0))
	vbox.add_child(title)
	_status_label = Label.new()
	_status_label.text = "（连接中…）"
	_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status_label.custom_minimum_size = Vector2(264, 0)
	_status_label.add_theme_font_size_override("font_size", 12)
	_status_label.add_theme_color_override("font_color", Color(0.88, 0.94, 1.0))
	_status_label.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(_status_label)
	hud.add_child(_panel)

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


## 轮询副官会话日志尾部 → 刷新左上角思考面板。
## 面板始终可见（监督模式）：服务器端 hermes 未跑时显示"未启动"，跑了就显示思考文本。
func _poll_tail() -> void:
	if _tail_http == null or _panel == null:
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
		return
	var parsed = JSON.parse_string(result[3].get_string_from_utf8())
	if not (parsed is Dictionary):
		return
	var lines: Array = parsed.get("lines", [])
	if lines.is_empty():
		_status_label.text = "（服务器端未启动副官会话）"
	else:
		# 只留最近 10 行，避免面板溢出。
		var recent := lines.slice(maxi(0, lines.size() - 10))
		_status_label.text = "\n".join(PackedStringArray(recent))
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
