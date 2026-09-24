extends Node

## 本地模型服务（System 2 的 2B 推理后端）的**自动保障**。
##
## 为什么需要这个文件（2026-09-23 用户实测定性）：
## 副官的战略层要连本地 Ollama（`minicpm5-adj-16k`）。而"把服务起起来"这一步
## 原来只写在 `build/启动AI_RTS.bat` 里 —— 玩家只要不是用那个 .bat 启动游戏
## （从编辑器/DEBUG 跑、直接双击 exe），模型服务就必然不在，战略层每轮都是
## `Connection error`，面板显示"战略思考这一轮没成功，先用规则顶住"。
## 用户的要求很明确：**游戏启动要自动满足所有条件，不能让我来操作**。
##
## 所以这里把"保障"搬进游戏本体：起 runner 之前先确保服务在听、并且**模型已预热**。
## 只预热不等人的理由：冷模型首次推理要 ~70s（2.6GB 载入），阻塞启动不可接受；
## 而 Ollama 的 KEEP_ALIVE 实测是"永不卸载"，所以这个成本每台机器只付一次。
##
## 状态机（`state()`，玩家可见文案见 `status_text()`）：
##   ""       未开始
##   starting 已拉起/已在跑，正在等端口
##   warming  端口已通，正在发预热请求（模型载入中）
##   ready    预热完成，战略层可用
##   timeout  等超时（不阻塞：runner 自行降级，下一轮自愈）
##   missing  这台机器上没有模型运行时（ollama.exe 找不到）

##: 模型服务专用端口。与 `build/启动AI_RTS.bat` 的 `MODEL_PORT` **同值**——
## 当年就是为了"不依赖也不打扰机器上可能装了的 Ollama（默认 11434）"才用专用口。
const PORT := 11436

##: 等端口就绪的上限（秒）。实测冷启 ~8s。
const PORT_TIMEOUT_S := 45.0

##: 等模型预热完成的上限（秒）。实测冷模型首次推理 ~70s。
const WARM_TIMEOUT_S := 180.0

##: 预热用的最短请求（只要 1 个 token：目的是把 2.6GB 权重载进显存/内存）。
const WARM_MAX_TOKENS := 1

##: 端口探测间隔（秒）。
const POLL_INTERVAL_S := 0.5

##: 我们亲手拉起的那个服务进程 pid（0 = 不是本进程起的 / 没起过）。
static var _spawned_pid := 0

##: 当前状态（见文件头状态机）。
static var _state := ""

##: 状态文案（玩家看的，中文人话）。空状态不显示。
static var _detail := ""

##: 是否已经有一次 `ensure_started_async()` 在跑（防并发重复拉起）。
static var _ensuring := false


## ---------------- 运行时定位 ----------------

## 找到模型运行时的两个关键路径。两种布局都覆盖：
##   ① **分发布局**：`<exe 同级>/adjutant_runtime/{ollama/ollama.exe, models}`
##   ② **仓库布局**（开发机）：`<工程>/build/adjutant_runtime/{...}`
## 返回空字典 = 这台机器上没有模型运行时（面板据此说"未找到"，不说"没成功"）。
static func resolve_runtime() -> Dictionary:
	for root in _runtime_roots():
		var ollama: String = root.path_join("ollama/ollama.exe").simplify_path()
		if not FileAccess.file_exists(ollama):
			continue
		var models: String = root.path_join("models").simplify_path()
		if not DirAccess.dir_exists_absolute(models):
			continue
		return {"ollama": ollama, "models": models, "root": root}
	return {}


static func _runtime_roots() -> Array:
	var roots: Array = []
	var exe_dir := OS.get_executable_path().get_base_dir()
	if not exe_dir.is_empty():
		roots.append(exe_dir.path_join("adjutant_runtime").simplify_path())
		# 防御：有的分发形态把运行时放在 exe 的上一级。
		roots.append(exe_dir.path_join("../adjutant_runtime").simplify_path())
	var project_dir := ProjectSettings.globalize_path("res://")
	if not project_dir.is_empty():
		roots.append(project_dir.path_join("build/adjutant_runtime").simplify_path())
	return roots


## ---------------- 端点与模型名（与 runner 同一份口径） ----------------

## 副官要连的 OpenAI 兼容端点。**游戏侧唯一口径**：与 `build/启动AI_RTS.bat` 的
## `MODEL_PORT` 同值（专用口，不打扰机器上可能装了的 Ollama 默认 11434）。
## 通过 runner 引导文件的环境变量把它钉给 runner（`env_file.py` 只填"尚未存在"的键，
## 所以这里显式注入就够，不依赖 `.env.local` 写对——那份文件曾经写成 11434，
## 与 .bat 的 11436 不一致，是 2026-09-23"战略思考每轮没成功"的帮凶之一）。
static func endpoint() -> String:
	return "http://127.0.0.1:%d/v1" % PORT


## 模型名：优先 `.env.local` 里的 `STRATEGY_MODEL` / `LLM_MODEL`，
## 读不到就退回随包默认值（预热失败不该让整条链路起不来）。
static func model_name() -> String:
	for key in ["STRATEGY_MODEL", "LLM_MODEL"]:
		var value := _env_file_value(key)
		if not value.is_empty():
			return value
	return "minicpm5-adj-16k"


static func _env_file_value(key: String) -> String:
	for path in _env_file_candidates():
		if not FileAccess.file_exists(path):
			continue
		var handle := FileAccess.open(path, FileAccess.READ)
		if handle == null:
			continue
		var text := handle.get_as_text()
		handle.close()
		for line in text.split("\n"):
			var stripped := line.strip_edges()
			if stripped.begins_with("#") or not "=" in stripped:
				continue
			var name := stripped.substr(0, stripped.find("=")).strip_edges()
			if name != key:
				continue
			var value := stripped.substr(stripped.find("=") + 1).strip_edges()
			# 去掉成对的引号（.env 常见写法）。
			if value.length() >= 2 and value.begins_with("\"") and value.ends_with("\""):
				value = value.substr(1, value.length() - 2)
			return value
	return ""


static func _env_file_candidates() -> Array:
	var out: Array = []
	var exe_dir := OS.get_executable_path().get_base_dir()
	if not exe_dir.is_empty():
		out.append(exe_dir.path_join("adjutant_runtime/.env.local").simplify_path())
	var project_dir := ProjectSettings.globalize_path("res://")
	if not project_dir.is_empty():
		out.append(project_dir.path_join("source/adjutant_coordinator/.env.local")
			.simplify_path())
	return out


## ---------------- 探测 ----------------

## 端口是否在监听（TCP 直连，不走 HTTP：只要证明"服务在听"就够了）。
## 口径与 `AdjutantButton._tcp_json` 的探测段一致（`StreamPeerTCP` 是 Godot 4 的类名）。
static func is_listening(port: int = PORT) -> bool:
	var peer := StreamPeerTCP.new()
	if peer.connect_to_host("127.0.0.1", port) != OK:
		return false
	var waited := 0.0
	while waited < 0.5:
		peer.poll()
		if peer.get_status() != StreamPeerTCP.STATUS_CONNECTING:
			break
		OS.delay_msec(20)
		waited += 0.02
	peer.poll()
	var connected := peer.get_status() == StreamPeerTCP.STATUS_CONNECTED
	peer.disconnect_from_host()
	return connected


## ---------------- 状态查询（面板/日志用） ----------------

static func state() -> String:
	return _state


static func is_warming() -> bool:
	return _state == "starting" or _state == "warming"


static func is_ready() -> bool:
	return _state == "ready"


static func detail() -> String:
	return _detail


## 玩家看的一状态文案。空状态 = 无需打扰玩家（服务本来就好着）。
## 拆出 `status_text_for(state)` 是为了能对整张状态机做无副作用单测。
static func status_text() -> String:
	var base := status_text_for(_state)
	if base.is_empty() or _detail.is_empty():
		return base
	# 失败/超时/缺失必须带上**具体原因**：只说"启动失败"等于没说，
	# 玩家和排查的人都得知道到底是没找到运行时、还是调用方还没进场景树。
	match _state:
		"failed", "timeout", "missing":
			return "%s（%s）" % [base, _detail]
	return base


static func status_text_for(state: String) -> String:
	match state:
		"starting":
			return "本地模型服务启动中…"
		"warming":
			return "本地模型预热中（首次约 1~2 分钟），先用规则指挥"
		"ready":
			return "本地模型已就绪"
		"timeout":
			return "本地模型预热超时，本轮先用规则指挥"
		"missing":
			return "未找到本地模型服务（战略层不可用）"
		"failed":
			return "本地模型服务启动失败（战略层不可用）"
	return ""


# ---------------- 启动 / 预热 ----------------

## 确保模型服务在听、且模型已预热。**非阻塞**：内部自己跑异步轮询，
## 调用方拿去即走；状态走 `state()` / `status_text()` 供面板如实显示。
##
## `parent`：承载异步轮询（计时器 + HTTPRequest）的节点，**必须已在场景树里**。
## 静态方法自己没有 `self` 可挂子节点，所以由调用方给（加载页/面板都传自己）。
static func ensure_started(parent: Node) -> void:
	if _ensuring:
		return
	if _state == "ready" and is_listening():
		return
	if parent == null or not parent.is_inside_tree():
		# 调用方还没进树（极早期初始化）：不静默失败，留一句可诊断的状态。
		_state = "failed"
		_detail = "调用方节点尚未进入场景树，无法启动模型服务保障"
		_ensuring = false
		push_warning("[ADJ-MODEL] %s" % _detail)
		return
	_ensuring = true
	var node := Node.new()
	node.set_script(load("res://source/ui/AdjutantModelService.gd"))
	parent.add_child(node)
	node.call("run_async")


## 真正的异步流程（挂在一次性节点上跑，完事自己释放）。
func run_async() -> void:
	if is_listening():
		_state = "warming"
		_detail = "服务已在运行，等待模型预热"
		await _warm()
		_finish()
		return
	var runtime := resolve_runtime()
	if runtime.is_empty():
		_state = "missing"
		_detail = "未找到 ollama.exe / models 目录"
		_ensuring = false
		queue_free()
		return
	if not _spawn():
		_state = "failed"
		_detail = "ollama.exe 拉起失败"
		_ensuring = false
		queue_free()
		return
	_state = "starting"
	_detail = "已拉起本地模型服务，等待端口 %d" % PORT
	if not await _wait_port(PORT_TIMEOUT_S):
		_state = "timeout"
		_detail = "等待端口 %d 超时" % PORT
		_ensuring = false
		queue_free()
		return
	_state = "warming"
	_detail = "端口已就绪，模型载入中"
	await _warm()
	_finish()


func _finish() -> void:
	_ensuring = false
	queue_free()


## 拉起 `ollama.exe serve`。优先**脱离**父进程（服务活得比游戏久，二次启动免预热），
## 脱离失败就退回普通子进程（只活本次会话，仍然满足"不用手动起"）。
func _spawn() -> bool:
	var runtime := resolve_runtime()
	if runtime.is_empty():
		return false
	var pid: int = _spawn_detached(str(runtime["ollama"]), str(runtime["models"]))
	if pid <= 0:
		# 兜底：普通子进程。`ollama serve` 没有 --host/--models 参数，只认环境变量，
		# 而 Windows 子进程会继承父进程环境块 —— 所以先 set 再 create。
		OS.set_environment("OLLAMA_HOST", "127.0.0.1:%d" % PORT)
		OS.set_environment("OLLAMA_MODELS", str(runtime["models"]))
		pid = OS.create_process(str(runtime["ollama"]), PackedStringArray(["serve"]), false)
		print("[ADJ-MODEL] 脱离拉起不可用，改用普通子进程（服务只活本次会话）")
	if pid <= 0:
		push_warning("[ADJ-MODEL] ollama.exe 拉起失败")
		return false
	_spawned_pid = pid
	print("[ADJ-MODEL] 已拉起本地模型服务 pid=%d（端口 %d）" % [pid, PORT])
	return true


## 通过 WMI（`Win32_Process.Create`）拉起服务，返回新进程 pid（<=0 = 失败）。
##
## 为什么要绕这一圈：`OS.create_process` 的子进程在 Windows 上会被父进程的
## **作业对象**管着，父进程一退全部被杀（实测 2026-09-23：Godot 一退出，
## 连同 `cmd /c start` 起的子孙一起死）。服务活得比游戏久才有意义——
## 冷模型首次载入 ~70s，每次开游戏都重付一遍是不可接受的。
## 经 WMI 服务主机创建的进程不在我们的作业对象里，能活过游戏退出。
##
## `ollama serve` 只认 `OLLAMA_HOST` / `OLLAMA_MODELS` 两个环境变量（没有对应命令行
## 参数），而 WMI 的 Create 不能传环境变量 —— 所以承一层 .cmd（由本函数写文件，
## 不进任何 shell 解析），再用 .ps1 去调 WMI（同样写文件，避免嵌套引号地狱）。
func _spawn_detached(ollama: String, models: String) -> int:
	var dir := ProjectSettings.globalize_path("user://adjutant_logs")
	if not DirAccess.dir_exists_absolute(dir):
		var err := DirAccess.make_dir_recursive_absolute(dir)
		if err != OK:
			push_warning("[ADJ-MODEL] 日志目录不可建：%s" % dir)
			return 0
	var ps1_path := dir.path_join("start_model_service.ps1")
	var ps1 := FileAccess.open(ps1_path, FileAccess.WRITE)
	if ps1 == null:
		push_warning("[ADJ-MODEL] 无法写入 %s" % ps1_path)
		return 0
	# PowerShell 单引号串里的单引号要翻倍；路径来自本机文件系统，正常不会有，但防一手。
	var ps1_ollama := ollama.replace("'", "''")
	var ps1_models := models.replace("'", "''")
	var ps1_dir := dir.replace("'", "''")
	ps1.store_string("\n".join([
		"# 由游戏自动生成（AdjutantModelService）：拉起本地模型服务并脱离游戏进程。",
		"$ErrorActionPreference = 'Stop'",
		"$cmdPath = Join-Path '%s' 'start_model_service.cmd'" % ps1_dir,
		"$lines = @(",
		"  '@echo off',",
		"  'set \"OLLAMA_HOST=127.0.0.1:%d\"'," % PORT,
		"  'set \"OLLAMA_MODELS=%s\"'," % ps1_models,
		"  'start \"\" /B \"%s\" serve'" % ps1_ollama,
		")",
		"Set-Content -Path $cmdPath -Value $lines -Encoding ASCII",
		"$result = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{",
		"  CommandLine = ('cmd.exe /c \"{0}\"' -f $cmdPath)",
		"}",
		"if ($result.ReturnValue -ne 0) { exit 1 }",
		"Write-Output $result.ProcessId",
		"",
	]))
	ps1.close()
	var out: Array = []
	var code: int = OS.execute("powershell", PackedStringArray([
		"-NoProfile", "-ExecutionPolicy", "Bypass", "-File", ps1_path]), out, true)
	if code != 0 or out.is_empty():
		push_warning("[ADJ-MODEL] WMI 脱离拉起失败 exit=%d" % code)
		return 0
	var text := str(out[0]).strip_edges()
	if not text.is_valid_int():
		push_warning("[ADJ-MODEL] WMI 返回异常：%s" % text)
		return 0
	return int(text)


func _wait_port(timeout_s: float) -> bool:
	var waited := 0.0
	while waited < timeout_s:
		if is_listening():
			return true
		await get_tree().create_timer(0.5).timeout
		waited += 0.5
	return is_listening()


## 预热：发一个只要 1 token 的最短请求，把 2.6GB 权重载进去。
## 失败不致命（可能只是这台机器显存不够）——状态留在 warming 之外即可，
## 由 runner 自己按 15s 超时降级，下一轮再试。
func _warm() -> void:
	var request := HTTPRequest.new()
	request.name = "ModelWarmup"
	add_child(request)
	var body := JSON.stringify({
		"model": model_name(),
		"messages": [{"role": "user", "content": "hi"}],
		"max_tokens": WARM_MAX_TOKENS,
		"temperature": 0.0,
	})
	var headers := PackedStringArray([
		"Content-Type: application/json",
		"Authorization: Bearer local",
	])
	var err: int = request.request(
		endpoint() + "/chat/completions", headers,
		HTTPClient.METHOD_POST, body)
	if err != OK:
		push_warning("[ADJ-MODEL] 预热请求下发失败 err=%d" % err)
		request.queue_free()
		_state = "failed"
		_detail = "预热请求下发失败"
		return
	var result: Array = await request.request_completed
	request.queue_free()
	if result.size() < 3 or int(result[1]) != 200:
		var code: int = int(result[1]) if result.size() >= 2 else -1
		push_warning("[ADJ-MODEL] 预热失败 HTTP %d" % code)
		_state = "failed"
		_detail = "预热失败 HTTP %d" % code
		return
	_state = "ready"
	_detail = "模型 %s 已就绪" % model_name()
	print("[ADJ-MODEL] 模型预热完成：%s" % _detail)


## 我们亲手拉起的那个服务进程是否还活着。
static func spawned_alive() -> bool:
	return _spawned_pid > 0 and OS.is_process_running(_spawned_pid)


## runner 引导文件里要注入的环境变量行（Python 源码，插在 `import os, sys` 之后）。
##
## 为什么必须显式注入：runner 的 `env_file.py` 只填"**尚未存在**"的变量，
## 所以引导文件里先写好的值永远赢。这样 runner 连的端口**就是游戏实际保障起来的
## 那个**，不依赖 `.env.local` 有没有写对——那份文件曾经写成 11434 而 .bat 用 11436，
## 不走 .bat 启动游戏时就必然连不上，而面板只说"没成功"、不说连不上哪儿。
static func bootstrap_env_lines() -> String:
	var lines: Array = []
	for key in ["LLM_BASE_URL", "TACTICS_BASE_URL", "STRATEGY_BASE_URL"]:
		lines.append("os.environ[%s] = %s" % [
			JSON.stringify(key), JSON.stringify(endpoint())])
	return "\n".join(lines)
