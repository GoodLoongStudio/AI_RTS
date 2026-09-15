extends RefCounted

## 本机副官 runner 的**唯一装配入口**（对局加载页与面板按钮共用）。
##
## 由来（2026-09-15 用户要求）："可以把对局的加载界面的时间放长点来等冷启动嘛" ——
## 要让**加载页**在对局加载期间就把 runner 拉起来、并在离开加载页前等它挂上，
## 而"读配置 / 写引导文件 / 启动进程 / 判活"这套逻辑面板里已经有一份。
## 两处各写一份必然漂移（历史事故全出在"两份实现各自解析"上），所以收敛到这里：
## - `Loading.gd`（对局加载页）：预热 + 等挂上；
## - `AdjutantButton.gd`（对局面板）：接管/停止时读写同一份配置与同一个 pidfile。
##
## 口径（与面板历史行为一致，别擅自改）：
## - 配置：`user://adjutant_local.cfg` 的 `[runner]` 是**覆盖项**，缺的必备项用仓库约定补齐；
## - 日志/握手目录：默认 `user://adjutant_logs`；验收/自动化可用环境变量
##   `AIRTS_RUNNER_HUD` 覆盖（与验收工装同口径，避免与面板抢同一个 pidfile）；
## - 权威口：本进程 DCS（`/root/DebugControlServer.port()`）→ 配置 → 24579；
## - 启动方式：写引导文件 + 只把文件路径传给 python（`-c` 在 Windows 下有引号坑）。

const CFG_PATH := "user://adjutant_local.cfg"
const LOG_DIR_DEFAULT := "user://adjutant_logs"
const PIDFILE_NAME := "agent_runner.pid"
const BOOTSTRAP_NAME := "runner_bootstrap.py"
const AUTHORITY_PORT_DEFAULT := 24579
##: runner 心跳新鲜度窗口（秒）。与 `AdjutantButton.LIVENESS_FRESH_SECONDS` 同值：
##: 单轮最坏含一次慢模型调用（实测 ~45s），取 90s 留一倍余量。
const LIVENESS_FRESH_SECONDS := 90.0


## runner 的日志/握手目录（绝对路径）。
static func log_dir() -> String:
	var override := OS.get_environment("AIRTS_RUNNER_HUD")
	if not override.is_empty():
		return override
	return ProjectSettings.globalize_path(LOG_DIR_DEFAULT)


## 读本机 runner 配置（文件覆盖 + 仓库约定补齐）。返回空字典 = 没找到 python。
static func config() -> Dictionary:
	var fallback := autodetect_config()
	var cfg := ConfigFile.new()
	if cfg.load(CFG_PATH) != OK:
		return fallback
	var loaded := {
		"python": str(cfg.get_value("runner", "python", "")),
		"src_root": str(cfg.get_value("runner", "src_root", "")),
		"work_dir": str(cfg.get_value("runner", "work_dir", "")),
		"authority_port": int(cfg.get_value("runner", "authority_port", AUTHORITY_PORT_DEFAULT)),
		"player": str(cfg.get_value("runner", "player", "")),
		"env_file": str(cfg.get_value("runner", "env_file", "")),
	}
	# GDScript 没有元组字面量：这里必须用**数组**（`("a","b")` 会直接 Parse Error）。
	for key in ["python", "src_root", "work_dir", "env_file"]:
		if str(loaded.get(key, "")).is_empty() and not str(fallback.get(key, "")).is_empty():
			loaded[key] = fallback[key]
	return loaded


## 仓库约定的自动探测（G:\AIRTS 布局：AI_RTS 与 临时文件夹/airts_agent_venv 同级）。
static func autodetect_config() -> Dictionary:
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
		"authority_port": AUTHORITY_PORT_DEFAULT,
		"player": "",
		"env_file": src_root.path_join("adjutant_coordinator/.env.local"),
	}


## 本机权威口：本进程 DCS（唯一不需要猜的来源）→ 配置 → 默认 24579。
static func authority_port() -> int:
	# 注意：`Engine.get_main_loop()` 是 Variant，必须显式 `as SceneTree` 才能取 `.root`
	# （否则 `var x := ...` 直接 Parse Error："Cannot infer the type"）。
	var tree := Engine.get_main_loop() as SceneTree
	if tree != null:
		var dcs: Node = tree.root.get_node_or_null("DebugControlServer")
		if dcs != null and dcs.has_method("port"):
			var own := int(dcs.call("port"))
			if own > 0:
				return own
	var cfg := config()
	if not cfg.is_empty() and int(cfg.get("authority_port", 0)) > 0:
		return int(cfg["authority_port"])
	return AUTHORITY_PORT_DEFAULT


# ---------------- 判活 ----------------

## 读握手文件里的 pid（0 = 没有/非法）。**不做 `is_process_running` 过滤**：
## 那个 API 对外部进程恒 false（实测），过滤掉就等于永远认不到外部 runner。
static func pidfile_pid() -> int:
	var path := log_dir().path_join(PIDFILE_NAME)
	if not FileAccess.file_exists(path):
		return 0
	var handle := FileAccess.open(path, FileAccess.READ)
	if handle == null:
		return 0
	var raw := handle.get_as_text().strip_edges()
	handle.close()
	return int(raw) if raw.is_valid_int() and int(raw) > 0 else 0


## 心跳：日志目录里最新 `*.jsonl` 的修改时间在窗口内（runner 每轮都会写）。
static func heartbeat_fresh() -> bool:
	var path := log_dir()
	var dir := DirAccess.open(path)
	if dir == null:
		return false
	var newest := 0
	for name in dir.get_files():
		if not name.ends_with(".jsonl"):
			continue
		newest = maxi(newest, FileAccess.get_modified_time(path.path_join(name)))
	if newest <= 0:
		return false
	return int(Time.get_unix_time_from_system()) - newest <= int(LIVENESS_FRESH_SECONDS)


## 本机是否有**在跑的**副官（握手文件 + 心跳双证；只看其一都会误判，实测踩过）。
static func is_attached() -> bool:
	return pidfile_pid() > 0 and heartbeat_fresh()


# ---------------- 启动 / 停止 ----------------

## 启动本机 runner，返回子进程 pid（<=0 = 失败）。已在跑则不重复起（返回现有 pid）。
static func start(authority_port_value: int = 0) -> int:
	var cfg := config()
	if cfg.is_empty():
		push_warning("[ADJ] 未找到本机 runner 配置（user://adjutant_local.cfg 或仓库约定布局）")
		return 0
	var port := authority_port_value if authority_port_value > 0 else authority_port()
	var dir := log_dir()
	DirAccess.make_dir_recursive_absolute(dir)
	var args: PackedStringArray = [
		"--authority-port", str(port),
		"--provider", "real",
		"--state-dir", dir,
		"--log-dir", dir,
		"--pidfile", dir.path_join(PIDFILE_NAME),
		"--engine", "langgraph",
		# runner 的端口纪律只放行生产局服 24571；本机起局的权威口是本进程 DCS
		# （正常游玩 = 24579，带 --debugport=N 时 = N）。不带这个开关装配阶段直接
		# RunnerError 退出（2026-09-14 实测真因）。
		"--allow-other-port",
	]
	var env_file := str(cfg.get("env_file", ""))
	if not env_file.is_empty():
		args.append("--env-file")
		args.append(env_file)
	if not str(cfg.get("player", "")).is_empty():
		args.append("--player")
		args.append(str(cfg["player"]))
	var bootstrap_path := dir.path_join(BOOTSTRAP_NAME)
	var handle := FileAccess.open(bootstrap_path, FileAccess.WRITE)
	if handle == null:
		push_warning("[ADJ] 引导文件不可写：%s" % bootstrap_path)
		return 0
	handle.store_string("\n".join([
		"import os, sys",
		# 冷启动体检：runner 的 start 事件会带 `since_spawn_ms`（从这一刻起算）。
		"import time",
		"os.environ['ADJUTANT_SPAWN_TS'] = '%.3f' % time.time()",
		"os.chdir(%s)" % JSON.stringify(str(cfg["work_dir"])),
		"sys.path.insert(0, %s)" % JSON.stringify(str(cfg["src_root"])),
		"sys.argv = ['agent_runner'] + %s" % JSON.stringify(args),
		"from adjutant_coordinator.deploy.agent_runner import main",
		"sys.exit(main())",
		"",
	]))
	handle.close()
	return OS.create_process(str(cfg["python"]), PackedStringArray([bootstrap_path]), false)


## 停止本机 runner（仅按**握手文件里的 pid** 精确杀；并删掉握手文件）。
static func stop() -> void:
	var pid := pidfile_pid()
	if pid > 0:
		OS.kill(pid)
	var path := log_dir().path_join(PIDFILE_NAME)
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)


# ---------------- "下次对局自动预热/接管"开关 ----------------

## 玩家是否希望**新对局自动把副官拉起来**（加载页预热用）。
## 存进面板自己的配置文件（不新增文件）：点"接管"置 true，点"停止"置 false。
## 自动化/验收可用环境变量 `AIRTS_ADJ_AUTO_TAKEOVER=1|0` 显式覆盖（隔离测试用）。
static func auto_takeover() -> bool:
	var override := OS.get_environment("AIRTS_ADJ_AUTO_TAKEOVER")
	if not override.is_empty():
		return override == "1" or override.to_lower() == "true"
	var cfg := ConfigFile.new()
	if cfg.load(CFG_PATH) != OK:
		return false
	return bool(cfg.get_value("runner", "auto_takeover", false))


static func set_auto_takeover(enabled: bool) -> void:
	var cfg := ConfigFile.new()
	cfg.load(CFG_PATH)  # 不存在也没关系：保存时会新建
	cfg.set_value("runner", "auto_takeover", bool(enabled))
	cfg.save(CFG_PATH)
