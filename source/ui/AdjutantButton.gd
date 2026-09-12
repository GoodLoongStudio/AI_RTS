extends Node

## AI 副官按钮组：对局 HUD 右上角的"AI 接管/停止"开关 + 连通性测试
## + 左上角实时思考状态面板（轮询副官会话日志尾部）。
## 点击 → HTTP POST 到服务器副官 daemon（nginx /adjutant/ 反代）→
## 启停 Hermes 副官会话（它以 as_player 身份通过服务器权威端点指挥你的部队）。
## 纯 UI 便利层：不参与任何玩法逻辑，随时可拆。

## 本机 runner 配置与日志目录（本地完整副官重构后不再使用云端 daemon；
## `SERVER_URL` 仅保留给"连通测试"按钮做历史链路自检，不参与实时控制）。
const RUNNER_CFG_PATH := "user://adjutant_local.cfg"
const RUNNER_LOG_DIR := "user://adjutant_logs"
const SERVER_URL := "http://101.43.121.102/adjutant"
## 副官管理凭证：不再硬编码（旧值已随仓库公开并被服务端轮换作废）。
## 运行时按优先级读取：环境变量 AI_ADJUTANT_TOKEN → user://adjutant_credentials.cfg。
## 两者都未配置时按钮进入"未配置"状态；服务端 403 时进入"认证失败"状态并停止
## 自动轮询（不做重试风暴，等用户显式再次操作）。
const TOKEN_ENV_VAR := "AI_ADJUTANT_TOKEN"
const CREDENTIALS_CFG_PATH := "user://adjutant_credentials.cfg"
const HTTP_FORBIDDEN := 403
const TAIL_INTERVAL := 5.0
## runner 心跳新鲜度窗口（秒）。取值理由：runner 每轮循环都会往
## `user://adjutant_logs` 写 jsonl（tick 行），但单轮里可能包含一次慢模型调用
## （实测最坏 ~45s）→ 窗口取 90s，留一倍余量，既不误判死、也不长时间挂着已死的 runner。
const LIVENESS_FRESH_SECONDS := 90.0

## 本机副官权威通道：DebugControlServer 的**裸 TCP + 一行 JSON** 协议
## （注意不是 HTTP，所以不能用 HTTPRequest；见 DebugControlServer._dispatch）。
const AUTHORITY_HOST := "127.0.0.1"
const AUTHORITY_PORT := 24579
## 预留调整步长（按资源类型的绝对额度）。
const RESERVE_STEP := {"A": 100, "B": 10}

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
var _title_label: Label
var _state_label: Label
var _action_label: Label
var _reason_label: Label
var _result_label: Label
## 当前副官引擎（"langgraph" / "hermes"），来自 /adjutant/status 的只读字段。
var _engine := ""

## 资源预留（方案 §6）：面板上的"预留"行 + 加减按钮，唯一数据源是游戏权威端。
var _reserve_label: Label
var _reserve_buttons: Array = []
var _reserve_values := {}
var _balance_values := {}
## 同一时刻只允许一个预留请求在飞（权威通道是短连接，避免打满）。
var _reserve_busy := false

## 正则：op 关键词（词边界防误报）+ 内部路径/命令参数清洗。
var _op_regex: RegEx = RegEx.create_from_string("\\b(status|move|gather|build|produce|attack|sleep)\\b")
var _path_regex: RegEx = RegEx.create_from_string("(res://|file:///|/home/|/tmp/)[^\\s]*")
var _kv_regex: RegEx = RegEx.create_from_string("\\b(as_player|units|dest|scene|kind|unit|target|pos|path|op|port|token)\\s*=\\s*\\S*")


## 运行时凭证缓存：只驻内存，不写日志/面板/任何持久文件。
var _token := ""
var _token_loaded := false
## 服务端 403 后置位：停止 tail 自动轮询等一切自动重试，避免认证重试风暴；
## 用户显式再次操作（重新加载凭证并尝试）才复位。
var _auth_blocked := false


## 凭证加载（static 便于 headless 测试）：环境变量优先，其次受保护用户配置。
## 任何来源都没有时返回空串（调用方进入"未配置"状态，绝不回退到旧默认值）。
static func load_credential() -> String:
	var env_token := OS.get_environment(TOKEN_ENV_VAR)
	if env_token.strip_edges() != "":
		return env_token.strip_edges()
	var cfg := ConfigFile.new()
	if cfg.load(CREDENTIALS_CFG_PATH) == OK:
		var cfg_token := str(cfg.get_value("adjutant", "token", ""))
		if cfg_token.strip_edges() != "":
			return cfg_token.strip_edges()
	return ""


## 认证失败的用户可读说明（static 便于测试）。
static func describe_auth_failure(http_code: int) -> String:
	if http_code == HTTP_FORBIDDEN:
		return "副官认证失败（403）：凭证无效或未配置，请检查 AI_ADJUTANT_TOKEN 或用户配置"
	return "副官请求失败（HTTP %d）" % http_code


## 本机模式不需要云端凭证：runner 是本地进程，鉴权由文件系统与进程边界保证。
## 保留函数签名，供"连通测试"按钮走历史链路自检时复用。
func _ensure_credential() -> bool:
	return true


func _legacy_ensure_credential() -> bool:
	if not _token_loaded:
		_token = load_credential()
		_token_loaded = true
	if _token == "":
		_set_panel_texts(
			"副官凭证未配置",
			"请设置环境变量 AI_ADJUTANT_TOKEN，或按文档创建用户配置后重试",
			PANEL_DASH, PANEL_DASH)
		return false
	return true


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
	# 【2026-09-11 改】原来这个按钮打的是**云端 daemon**（101.43.121.102/adjutant），
	# 本地完整副官已经不用它了；没配 token 时就红字报"认证失败（403）"，
	# 玩家只会以为副官坏了（用户实测反馈："这又是为什么，UI 不要都搞错"）。
	# 现在只做**本机链路自检**（runner pidfile + 心跳 + 权威端口），不再碰云端。
	_test_button.text = "本机链路自检"
	_test_button.tooltip_text = "检查本机：runner 是否在跑（pidfile/心跳）、权威端口是否响应"
	# 位置放到副官面板正下方：原来在 (620,8) 会压住右上角帧率与侧栏（截图实测重叠）。
	_test_button.position = Vector2(8, 252)
	_test_button.z_index = 100
	hud.add_child(_test_button)
	_test_button.pressed.connect(_on_test_pressed)

	# 左上角实时思考状态面板：始终显示（监督服务器端 hermes 副官）。
	_panel = PanelContainer.new()
	_panel.position = Vector2(8, 36)
	_panel.custom_minimum_size = Vector2(280, 210)
	_panel.size = Vector2(280, 210)
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
	_title_label = Label.new()
	_title_label.text = "🔹 AI 副官"
	_title_label.add_theme_font_size_override("font_size", 12)
	_title_label.add_theme_color_override("font_color", Color(0.3, 0.85, 1.0))
	vbox.add_child(_title_label)
	_state_label = _make_panel_label()
	_action_label = _make_panel_label()
	_reason_label = _make_panel_label()
	_result_label = _make_panel_label()
	vbox.add_child(_state_label)
	vbox.add_child(_action_label)
	vbox.add_child(_reason_label)
	vbox.add_child(_result_label)
	_build_reserve_row(vbox)
	hud.add_child(_panel)
	_set_panel_texts(PANEL_IDLE, PANEL_DASH, PANEL_DASH, PANEL_DASH)
	_reserve_label.text = "预留：等待对局"

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
	# 本地完整副官（2026-09-11 重构）：按钮直接启停**本机** Python runner，
	# 不再走云端 daemon（原 SERVER_URL 指向 101.43.121.102，与"本机全链路"冲突）。
	_auth_blocked = false
	_button.disabled = true
	_button.text = "AI 副官：处理中…"
	if _active:
		_stop_local_runner()
	else:
		_start_local_runner()
	_restore_button()
	_update_status_line()
	_query_status()


## ---------- 本机 runner 进程管理 ----------
## 只管理**本次会话创建**的进程，退出/重开对局时结束；绝不结束无关的游戏或推理进程。
var _runner_pid := -1
## 该 pid 是否**由本按钮创建**（`OS.create_process`）。认领来的外部 runner 为 false：
## 退出对局时不杀它，但玩家点"停止"仍会尽力杀（那是明确指令）。
var _runner_owned := false


## 读本机 runner 配置：user://adjutant_local.cfg（结构化，便于换机器/换路径）；
## 缺失时按仓库相对布局自动探测一次（G:\AIRTS 约定）。
func _load_runner_config() -> Dictionary:
	var cfg := ConfigFile.new()
	if cfg.load(RUNNER_CFG_PATH) == OK:
		return {
			"python": str(cfg.get_value("runner", "python", "")),
			"src_root": str(cfg.get_value("runner", "src_root", "")),
			"work_dir": str(cfg.get_value("runner", "work_dir", "")),
			"authority_port": int(cfg.get_value("runner", "authority_port", 24579)),
			"player": str(cfg.get_value("runner", "player", "")),
		}
	return _autodetect_runner_config()


func _autodetect_runner_config() -> Dictionary:
	# 仓库约定：AI_RTS 与 临时文件夹/airts_agent_venv 同级位于 G:\AIRTS 下。
	var project_dir := ProjectSettings.globalize_path("res://")
	var repo_root := project_dir.path_join("..").simplify_path()
	var venv_python := repo_root.path_join("临时文件夹/airts_agent_venv/Scripts/python.exe")
	var src_root := project_dir.path_join("source").simplify_path()
	if not FileAccess.file_exists(venv_python):
		return {}
	return {
		"python": venv_python,
		"src_root": src_root,
		"work_dir": src_root,
		"authority_port": 24579,
		"player": "",
		"env_file": src_root.path_join("adjutant_coordinator/.env.local"),
	}


func _start_local_runner() -> void:
	# 已在跑就不重复起。【不能】只用 `OS.is_process_running` 判：它对外部进程恒 false，
	# 会把已认领的外部 runner 当成"没在跑"→ 再起一个 → **两个 runner 抢同一个权威端口**，
	# 两边同时下发命令（实测踩过）。所以外部 runner 用心跳判。
	if _runner_pid > 0 and (OS.is_process_running(_runner_pid) or _runner_heartbeat_fresh()):
		_active = true
		_update_status_line()
		return
	var cfg := _load_runner_config()
	if cfg.is_empty():
		push_warning("[ADJ] 未找到本机 runner 配置（user://adjutant_local.cfg 或仓库约定布局）")
		_set_panel_texts("未配置本机 runner", PANEL_DASH, PANEL_DASH, PANEL_DASH)
		return
	var log_dir := ProjectSettings.globalize_path(RUNNER_LOG_DIR)
	DirAccess.make_dir_recursive_absolute(log_dir)
	var args: PackedStringArray = [
		"-m", "adjutant_coordinator.deploy.agent_runner",
		"--authority-port", str(cfg["authority_port"]),
		"--provider", "real",
		"--state-dir", log_dir,
		"--log-dir", log_dir,
		"--pidfile", log_dir.path_join("agent_runner.pid"),
		"--engine", "langgraph",
	]
	# 本机副官配置：指向本地 Ollama（单模型、直连、不走代理与隧道）。
	var env_file := str(cfg.get("env_file", ""))
	if not env_file.is_empty():
		args.append("--env-file")
		args.append(env_file)
	if not str(cfg["player"]).is_empty():
		args.append("--player")
		args.append(str(cfg["player"]))
	# 用 -c 先切工作目录并注入 sys.path，避免依赖 OS.create_process 的 cwd（其不支持）。
	var bootstrap := ("import os,sys;os.chdir(r'%s');sys.path.insert(0,r'%s');"
		+ "sys.argv=['agent_runner']+%s;"
		+ "from adjutant_coordinator.deploy.agent_runner import main;sys.exit(main())"
		% [cfg["work_dir"], cfg["src_root"], JSON.stringify(args)])
	_runner_pid = OS.create_process(str(cfg["python"]), PackedStringArray(["-c", bootstrap]), false)
	if _runner_pid <= 0:
		push_warning("[ADJ] 本机 runner 启动失败")
		_set_panel_texts("runner 启动失败", PANEL_DASH, PANEL_DASH, PANEL_DASH)
		return
	_runner_owned = true
	_active = true


func _stop_local_runner() -> void:
	# 【为什么不先问 is_process_running】本机实测该 API **对外部进程恒 false**，
	# 先问就等于"永远不杀"（点停止没反应）。`OS.kill` 对外部进程有效（实测 err=0）。
	if _runner_pid > 0:
		OS.kill(_runner_pid)
	# 握手文件必须一起删：否则日志还新，下一轮 `_query_status` 会按心跳把它重新认领成"运行中"。
	var pid_path := ProjectSettings.globalize_path(RUNNER_LOG_DIR).path_join("agent_runner.pid")
	if FileAccess.file_exists(pid_path):
		DirAccess.remove_absolute(pid_path)
	_runner_pid = -1
	_runner_owned = false
	_active = false


func _exit_tree() -> void:
	# 只结束**本次会话创建**的 runner（避免留孤儿进程占端口）；
	# 认领来的外部 runner 不是我们起的，退出对局时**不杀**。
	if _runner_owned and _runner_pid > 0:
		OS.kill(_runner_pid)
	_runner_pid = -1


func _on_test_pressed() -> void:
	# 本机链路自检：**不碰云端**（理由见 `_install` 里按钮的说明）。
	if _test_button == null or not is_instance_valid(_test_button):
		return
	_test_button.disabled = true
	_test_button.text = "自检中…"
	_test_button.modulate = Color.WHITE
	var pid := _read_runner_pidfile()
	if pid <= 0:
		_show_test_result(false, "✗ 没有运行中的 runner（pidfile 缺失或内容非法）",
			Color(1, 0.4, 0.4))
		return
	if not _runner_heartbeat_fresh():
		_show_test_result(false, "✗ runner 心跳超时（pid=%d，日志超过 %d 秒没更新）"
			% [pid, int(LIVENESS_FRESH_SECONDS)], Color(1, 0.4, 0.4))
		return
	# 权威端口是加分项、不是必需项：runner 可能在别的端口，或对局尚未就绪。
	var payload: Dictionary = await _authority_call({"op": "status", "lite": true})
	if payload.is_empty() or payload.has("error"):
		_show_test_result(true, "✓ runner 在跑（pid=%d）；权威端口 %d 未响应（本机测试常见，不影响副官）"
			% [pid, AUTHORITY_PORT], Color(0.95, 0.9, 0.5))
		return
	_show_test_result(true, "✓ 本机链路正常 · pid=%d · 对局=%s"
		% [pid, str(payload.get("match", false))], Color(0.5, 1.0, 0.5))


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
	# 本机模式：直接读本地 runner 日志尾部（不再拉云端 _tail）。
	_query_status()
	if _panel == null or not is_instance_valid(_panel):
		return
	if not _active:
		_set_panel_texts(PANEL_IDLE, PANEL_DASH, PANEL_DASH, PANEL_DASH)
		return
	var status := _read_hud_status()
	if status.is_empty():
		# 兜底：状态文件还没写出来（runner 刚起）。**绝不能**显示"副官尚未启动"
		# —— 那会与标题"运行中"自相矛盾。诊断只落文件、不上屏：
		# 面板是给玩家看的，只允许中文人话（用户明确要求）。
		_tail_diag()
		_set_panel_texts(PANEL_CONNECTING, "正在读取副官状态", PANEL_DASH, "副官已在运行")
	else:
		_apply_hud_status(status)
	# 预留额度由权威端持有；面板每轮同步一次（玩家点按钮时也会立即刷新）。
	_refresh_reserves()


## 读本机 runner 日志目录里最新的 jsonl，取最后若干行原始文本。
func _read_local_runner_tail() -> Array:
	var dir_path := ProjectSettings.globalize_path(RUNNER_LOG_DIR)
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return []
	var newest := ""
	var newest_time := 0
	for file_name in dir.get_files():
		var name := str(file_name)
		if not name.ends_with(".jsonl"):
			continue
		# 优先读**事件**文件：`_apply_runner_tail` 认的字段（route/accepted/
		# degraded_reason）写在 `agent_runner_events_*.jsonl` 里；同目录另有
		# `agent_runner_<stamp>_<match>.jsonl`（另一种 schema），按 mtime 碰运气
		# 会读到解析不出内容的那个 → 面板正文永远空白（2026-09-11 实测）。
		var weight := 1 if name.contains("_events_") else 0
		var path := dir_path.path_join(name)
		var mtime := int(FileAccess.get_modified_time(path)) + weight * 100000000
		if mtime > newest_time:
			newest_time = mtime
			newest = path
	if newest.is_empty():
		return []
	var fh := FileAccess.open(newest, FileAccess.READ)
	if fh == null:
		return []
	var lines: Array = []
	# 显式标注类型：FileAccess.get_line_count() 在 --check-only 下推断不出类型。
	var total: int = fh.get_line_count()
	var start: int = maxi(0, total - 12)
	var idx := 0
	while not fh.eof_reached():
		var line := fh.get_line()
		if idx >= start and not line.strip_edges().is_empty():
			lines.append(line)
		idx += 1
	fh.close()
	return lines


## 读 runner 维护的面板状态文件（单行 JSON，见 runner `_write_hud_status_file`）。
## 为什么不用"扫目录 + tail 事件 jsonl"：实测在游戏进程里读出来是空的（同一文件
## 外部工具读得到），而它只是表现层，不值得为它继续深挖 —— 一个单行文件最小、最稳。
func _read_hud_status() -> Dictionary:
	var path := ProjectSettings.globalize_path(RUNNER_LOG_DIR).path_join("hud_status.json")
	if not FileAccess.file_exists(path):
		return {}
	var fh := FileAccess.open(path, FileAccess.READ)
	if fh == null:
		return {}
	var raw := fh.get_as_text()
	fh.close()
	var parsed = JSON.parse_string(raw)
	return parsed if parsed is Dictionary else {}


## 渲染面板四行（**中文人话**；文案由 runner 保证，这里只做拼装，不再猜字段）。
func _apply_hud_status(status: Dictionary) -> void:
	var phase := str(status.get("phase", "")).strip_edges()
	var goal := str(status.get("goal", "")).strip_edges()
	var thinking := str(status.get("thinking", "")).strip_edges()
	var why := str(status.get("why", "")).strip_edges()
	var result := str(status.get("result", "")).strip_edges()
	var units := int(status.get("units", 0))
	var head := phase if not phase.is_empty() else "运行中"
	if not goal.is_empty():
		head += "（目标：%s）" % goal
	if units > 0:
		result += "（指挥 %d 个单位）" % units
	_set_panel_texts(
		head,
		thinking if not thinking.is_empty() else PANEL_DASH,
		why if not why.is_empty() else PANEL_DASH,
		result if not result.is_empty() else PANEL_DASH)


## 诊断：面板为什么读不到 runner 日志尾部。**只写文件、不上屏**
## （面板只给玩家看中文人话；这份是给排查用的）。
## 存在的意义就是"不许猜"：2026-09-11 面板正文长期停在兜底文案，
## 靠它把目录是否可打开、有几个 jsonl、能否打开最新那个一次性钉死。
func _tail_diag() -> String:
	var dir_path := ProjectSettings.globalize_path(RUNNER_LOG_DIR)
	var text := ""
	var dir := DirAccess.open(dir_path)
	if dir == null:
		text = "dir_open_null path=%s" % dir_path
	else:
		var files := dir.get_files()
		var jsonl := 0
		var newest := ""
		for file_name in files:
			var name := str(file_name)
			if not name.ends_with(".jsonl"):
				continue
			jsonl += 1
			newest = name
		var opened := "n/a"
		if not newest.is_empty():
			var fh_probe := FileAccess.open(dir_path.path_join(newest), FileAccess.READ)
			opened = str(fh_probe != null)
			if fh_probe != null:
				fh_probe.close()
		text = "files=%d jsonl=%d last=%s open=%s" % [files.size(), jsonl, newest, opened]
	var out := FileAccess.open(dir_path.path_join("hud_diag.txt"), FileAccess.WRITE)
	if out != null:
		out.store_line("active=%s pid=%d %s" % [str(_active), _runner_pid, text])
		out.close()
	return text


## 解析本机 runner 日志尾部为四类玩家可读信息（沿用既有字段约定）。
func _apply_runner_tail(lines: Array) -> void:
	var state := PANEL_DASH
	var action := PANEL_DASH
	var reason := PANEL_DASH
	var result := PANEL_DASH
	# 【首选】runner 主动写的 `hud_status`：阶段/思考/为什么/结果由它直接给结论，
	# 面板 1:1 渲染 —— 用户要的就是"看副官的思考信息"，不能让 HUD 去猜字段。
	for i in range(lines.size() - 1, -1, -1):
		var parsed = JSON.parse_string(str(lines[i]))
		if not (parsed is Dictionary):
			continue
		if str(parsed.get("event", "")) != "hud_status":
			continue
		_set_panel_texts(
			str(parsed.get("phase", PANEL_UNKNOWN)),
			str(parsed.get("thinking", PANEL_DASH)),
			str(parsed.get("why", PANEL_DASH)),
			str(parsed.get("result", PANEL_DASH)))
		return
	# 兜底：老格式事件（route/accepted/degraded_reason/sent）。
	for raw in lines:
		var parsed = JSON.parse_string(str(raw))
		if not (parsed is Dictionary):
			continue
		if parsed.has("route"):
			state = "阶段：%s" % str(parsed.get("route", ""))
		if parsed.has("accepted"):
			result = "本次接受：%s" % str(parsed.get("accepted", []))
		if parsed.has("degraded_reason") and not str(parsed["degraded_reason"]).is_empty():
			reason = "降级：%s" % str(parsed["degraded_reason"])
		if parsed.has("sent"):
			action = "累计下发：%s" % str(parsed.get("sent", ""))
	_set_panel_texts(state, action, reason, result)


func _legacy_poll_tail() -> void:
	if _tail_http == null or _panel == null:
		return
	# 每轮先同步真实运行状态：此前 `_active` 只在启动时查一次，若启动瞬间副官未运行，
	# 面板/按钮就永远停在"副官尚未启动 / 接管"（2026-09-10 用户反馈"看不到副官在动"）。
	_query_status()
	if _auth_blocked:
		# 403 后停止自动轮询（不重试风暴）；用户重新操作时复位。
		return
	if not _ensure_credential():
		return
	if not _active:
		_set_panel_texts(PANEL_IDLE, PANEL_DASH, PANEL_DASH, PANEL_DASH)
		return
	# HTTPRequest 同时只能一个请求，上一轮没回来就跳过本轮。
	if _tail_http.get_http_client_status() != HTTPClient.STATUS_DISCONNECTED:
		return
	var body := JSON.stringify({"token": _token, "action": "tail"})
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
	# 本机模式：运行状态 = runner 进程是否存活（不再轮询云端 /status）。
	#
	# 【2026-09-11 实测根因，别再改回 is_process_running 判活】
	# `OS.is_process_running()` 在本机**只对自己 `OS.create_process()` 出来的子进程
	# 返回 true**；对一切**外部**进程（python runner、甚至别的 Godot 实例）**恒返回 false**
	# —— 实测：把机器上所有 python/Godot 的 pid 逐个喂给它，全是 false，只有 self 是 true。
	# 这正是"面板永远显示'副官尚未启动'、按钮永远是'接管'，而 runner 明明在指挥"
	# 的真正原因（换目录、换路径都不是根因）。
	# 因此**外部 runner 的存活一律用心跳新鲜度判**（`_runner_heartbeat_fresh`），
	# `is_process_running` 仅作为"本按钮自己创建的子进程"的补充信号。
	if _runner_pid < 0:
		var adopted := _read_runner_pidfile()
		if adopted > 0:
			_runner_pid = adopted
	var alive := false
	if _runner_pid > 0:
		alive = OS.is_process_running(_runner_pid) or _runner_heartbeat_fresh()
	if alive != _active:
		_active = alive
		_restore_button()
		# 标题必须跟按钮一起刷新：只改按钮文字时，面板标题永远停在"🔹 AI 副官"，
		# 玩家在屏幕上唯一能看到"到底有没有接管"的地方就是这里
		# （2026-09-11 用户反馈：接管成功要给明确反馈，否则不知道该不该等）。
		_update_status_line()
	if not alive:
		_runner_pid = -1


## 读取本机 runner 的 pidfile（runner 启动时由 `--pidfile` 写入）。
## **这里是唯一的"认领握手"**：只要 pidfile 内容合法就返回该 pid，
## 存活与否交给 `_query_status`/`_runner_heartbeat_fresh` 判
## （**不能**在这里用 `OS.is_process_running` 过滤：对外部进程恒 false，
## 会把所有外部 runner 全部拒之门外 —— 这正是此前"永远尚未启动"的写法）。
## 返回 0 表示没有可认领的 runner。
func _read_runner_pidfile() -> int:
	var path := ProjectSettings.globalize_path(RUNNER_LOG_DIR).path_join("agent_runner.pid")
	if not FileAccess.file_exists(path):
		return 0
	var fh := FileAccess.open(path, FileAccess.READ)
	if fh == null:
		return 0
	var raw := fh.get_as_text().strip_edges()
	fh.close()
	if not raw.is_valid_int():
		return 0
	var pid := int(raw)
	return pid if pid > 0 else 0


## runner 心跳：它每轮都会往 `user://adjutant_logs` 写 jsonl（tick 行与事件）。
## 取该目录里最新 `*.jsonl` 的修改时间，超过 `LIVENESS_FRESH_SECONDS` 视为已停。
## 为什么用"心跳"而不是 pid 存活：见 `_query_status` 的实测结论。
func _runner_heartbeat_fresh() -> bool:
	var dir_path := ProjectSettings.globalize_path(RUNNER_LOG_DIR)
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return false
	var now := int(Time.get_unix_time_from_system())
	for file_name in dir.get_files():
		if not str(file_name).ends_with(".jsonl"):
			continue
		var age := now - int(FileAccess.get_modified_time(
			dir_path.path_join(str(file_name))))
		if age <= int(LIVENESS_FRESH_SECONDS):
			return true
	return false


func _legacy_query_status() -> void:
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
			# 只接受字符串型引擎名：服务端字段异常（非字符串）时留空，标题不显示括号，
			# 避免把布尔值当引擎名显示成"运行中（true）"。
			var engine_value = parsed.get("engine", "")
			_engine = str(engine_value) if engine_value is String else ""
			_restore_button()
			_update_status_line()


func _restore_button() -> void:
	if _button == null or not is_instance_valid(_button):
		return
	_button.disabled = false
	_button.text = "AI 副官：停止" if _active else "AI 副官：接管"
	_button.modulate = Color(1.0, 0.55, 0.55) if _active else Color.WHITE


## 面板标题显示运行状态 + 引擎：面板正文只反映日志内容，不足以判断"到底有没有在跑"。
func _update_status_line() -> void:
	if _title_label == null or not is_instance_valid(_title_label):
		return
	var engine_label: String = {"langgraph": "LangGraph", "hermes": "Hermes"}.get(_engine, _engine)
	var state := "运行中" if _active else "已停止"
	if _active and not _engine.is_empty():
		state += "（%s）" % engine_label
	_title_label.text = "🔹 AI 副官 · %s" % state


## daemon 拒绝原因 → 玩家可读文本（409 有两种：already running / no active match）。
func _describe_control_failure(result: Array) -> String:
	if result.size() < 4 or result[3] == null:
		return ""
	var parsed = JSON.parse_string(result[3].get_string_from_utf8())
	if not (parsed is Dictionary):
		return ""
	match str(parsed.get("error", "")):
		"already running":
			return "副官已在运行"
		"no active match":
			return "服务器上没有进行中的对局"
		"bad token":
			return "凭证无效，请检查 AI_ADJUTANT_TOKEN"
		"unknown engine":
			return "引擎参数不支持"
		_:
			return str(parsed.get("error", ""))


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


## ---------- 资源预留（方案 §6） ----------

## 面板预留行：只读展示 + 按类型加减（绝对值）。
## 数据源是游戏权威端 op=adjutant_reserves —— HUD 不自己算、不把本地缓存当权威。
func _build_reserve_row(vbox: VBoxContainer) -> void:
	_reserve_label = _make_panel_label()
	_reserve_label.text = "预留：—"
	vbox.add_child(_reserve_label)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 2)
	vbox.add_child(row)
	for kind in ["A", "B"]:
		for direction in [-1, 1]:
			var step := int(RESERVE_STEP.get(kind, 10))
			var button := Button.new()
			button.text = "%s%s%d" % [kind, "-" if direction < 0 else "+", step]
			button.add_theme_font_size_override("font_size", 11)
			button.pressed.connect(_on_reserve_button.bind(str(kind), int(direction)))
			row.add_child(button)
			_reserve_buttons.append(button)


func _on_reserve_button(kind: String, direction: int) -> void:
	var current := int(_reserve_values.get(kind, 0))
	var step := int(RESERVE_STEP.get(kind, 10))
	_adjust_reserve(kind, max(0, current + direction * step))


## 调整某一类资源的预留额度（绝对值）；设 0 表示该项不预留（副官可用全部）。
## 注意：协程调用不能用 `:=` 推断类型（仓库既有约定）。
func _adjust_reserve(kind: String, value: int) -> void:
	if _reserve_busy:
		return
	_reserve_busy = true
	var payload: Dictionary = await _authority_call({
		"op": "adjutant_reserves",
		"action": "set",
		"as_player": _local_player_name(),
		"reserves": {kind: int(value)},
	})
	_reserve_busy = false
	if payload.is_empty():
		_reserve_label.text = "预留：权威端不可达"
		return
	_apply_reserve_view(payload)


## 定期拉取预留快照刷新面板（对局未就绪 / 权威端不可达时静默跳过，不刷屏）。
func _refresh_reserves() -> void:
	if _reserve_busy or _panel == null or not is_instance_valid(_panel):
		return
	_reserve_busy = true
	var payload: Dictionary = await _authority_call({
		"op": "adjutant_reserves",
		"as_player": _local_player_name(),
	})
	_reserve_busy = false
	if payload.is_empty() or payload.has("error"):
		return
	_apply_reserve_view(payload)


func _apply_reserve_view(payload: Dictionary) -> void:
	_reserve_values = payload.get("reserves", {}) if payload.get("reserves", {}) is Dictionary else {}
	_balance_values = payload.get("balance", {}) if payload.get("balance", {}) is Dictionary else {}
	var parts: Array = []
	for kind in ["A", "B"]:
		parts.append("%s 预留%d/余额%d" % [kind, int(_reserve_values.get(kind, 0)),
			int(_balance_values.get(kind, 0))])
	_reserve_label.text = "预留：%s" % " ".join(parts)


## 单机自定义对局：players 组恰好一人时返回其名字；否则空串（交给权威端判定，不猜）。
func _local_player_name() -> String:
	var players := get_tree().get_nodes_in_group("players")
	if players.size() == 1:
		return str(players[0].name)
	return ""


## 与游戏权威端（DebugControlServer）通信：**裸 TCP + 一行 JSON**，不是 HTTP。
## 短连接 + 有界等待（本机往返 <10ms）；超时即放弃，不阻塞对局主循环。
func _authority_call(payload: Dictionary) -> Dictionary:
	var peer := StreamPeerTCP.new()
	if peer.connect_to_host(AUTHORITY_HOST, AUTHORITY_PORT) != OK:
		return {}
	var waited := 0.0
	while waited < 0.5:
		peer.poll()
		if peer.get_status() != StreamPeerTCP.STATUS_CONNECTING:
			break
		await get_tree().create_timer(0.02).timeout
		waited += 0.02
	peer.poll()
	if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		peer.disconnect_from_host()
		return {}
	peer.put_data((JSON.stringify(payload) + "\n").to_utf8_buffer())
	var buffer := ""
	waited = 0.0
	while waited < 1.0:
		await get_tree().create_timer(0.02).timeout
		peer.poll()
		var available := peer.get_available_bytes()
		if available > 0:
			buffer += peer.get_utf8_string(available)
			if buffer.contains("\n"):
				break
		waited += 0.02
	peer.disconnect_from_host()
	var parsed = JSON.parse_string(buffer.strip_edges())
	return parsed if parsed is Dictionary else {}


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
