extends Node

## 对局实例登记（2026-09-29）：让"同一台机器同时开多个单人对局"成为一等公民，
## 并从根上消灭"僵尸局"。
##
## 【为什么要有】本机开发/测试的端口此前散落硬编码（24568/24569/24570/24572/24579…），
## 于是三件事反复发生（都有实据）：
##   1) 第二个对局的 DCS 抢不到口 → **静默**不监听：进程还在、窗口还在，看着像在对局，
##      实际任何命令都下不进去（`DebugControlServer._ready` 只 print 一行就 return）。
##   2) 工具靠"猜端口"连接 → 连到**别人家**正在跑的对局上（2026-09-28 实测：测试脚本
##      "秒连"成功，其实连的是并行会话的客户端，命令全下错了地方）。
##   3) 工具按**端口**清理 → 杀掉别人的进程（`config/dev_ports.json` 里记着 2026-09-13
##      血案：验收收尾按端口清理，把游戏内面板的 runner 一起杀了）。
##
## 【本节点的契约】只在**开发/自动化模式**下激活 —— 判据是环境变量
## `AIRTS_INSTANCE_DIR` 指向一个登记目录。普通玩家进程不带这个变量，在 `_ready`
## 就自毁：不写盘、不轮询、零副作用（发布包同样安全）。
##
## 激活后做四件事：
##   A. **登记**：写 `<AIRTS_INSTANCE_DIR>/<实例名>.json`，含 pid / 父 pid / 角色 /
##      **实际监听**的游戏口与调试口 / 对局号 / 心跳时间。工具**读登记**取端口，
##      不再猜端口 → 永远连到自己那一局（A 是"多开不打架"的地基）。
##   B. **心跳**：每 2s 刷新；进程正常退出时删除登记。被 `taskkill /F` 硬杀则留下
##      残留文件，由下一次启动的清扫或 `tools/dev/match_instance.py reap` 处理。
##   C. **清扫/识别僵尸**：启动时扫描登记目录 —— pid 已死 = 残留文件，直接删；
##      pid 活着但心跳过期 = 疑似僵尸，**只报告不擅杀**（杀谁的进程必须由人决定），
##      把结论写进自己的登记 `stale_records` 供工具读取。绝不按端口杀进程。
##   D. **看门狗**：`AIRTS_PARENT_PID` 指向的启动器一死，本进程立即自退。
##      启动器崩了/被 Ctrl-C 掉了，桌面上也不会留下一局没人管的"僵尸局"。
##
## 环境变量：
##   AIRTS_INSTANCE_DIR      登记目录（**唯一开关**；空 = 本节点完全惰性）
##   AIRTS_INSTANCE          实例名（默认 `<角色>-<pid>`）
##   AIRTS_PARENT_PID        启动器 pid（看门狗目标；缺省则不启用看门狗）
##   AIRTS_INSTANCE_STALE_S  心跳过期阈值秒数（默认 20）
##   AIRTS_INSTANCE_STRICT_DCS  1/0（默认 1）：调试口没绑上就**显式退场**，
##                          而不是留在桌面上当一局不可控的僵尸

const ENV_DIR := "AIRTS_INSTANCE_DIR"
const ENV_NAME := "AIRTS_INSTANCE"
const ENV_PARENT := "AIRTS_PARENT_PID"
const ENV_STALE_S := "AIRTS_INSTANCE_STALE_S"
const ENV_STRICT_DCS := "AIRTS_INSTANCE_STRICT_DCS"
const ENV_TEST_BASE := "AIRTS_TEST_BASE"

const SCHEMA := 1
const HEARTBEAT_INTERVAL := 2.0
const DEFAULT_STALE_S := 20.0
## 绑定调试口后的宽限期：过了这个时间还没绑上就判定"不可控"。
const DCS_GRACE_S := 6.0

var _enabled := false
var _dir := ""
var _name := ""
var _path := ""
var _parent_pid := 0
var _stale_s := DEFAULT_STALE_S
var _strict_dcs := true
var _role := "client"
var _headless := false
var _game_port := 0
var _connect_host := ""
var _started_at := 0.0
var _accum := 0.0
var _elapsed := 0.0
var _phase := "booting"
var _ds_error := ""
var _stale_records: Array = []
var _finalized := false
## 启动器租约文件路径与"是否见过租约"（见 `_watchdog_tripped`）。
var _parent_lease_path := ""
var _parent_seen := false
var _parent_miss_streak := 0


func _ready() -> void:
	_dir = OS.get_environment(ENV_DIR).strip_edges()
	if _dir.is_empty():
		# 普通玩家进程：不登记、不写盘、不做看门狗。
		queue_free()
		return
	_enabled = true
	var args := OS.get_cmdline_user_args()
	var engine_args := OS.get_cmdline_args()
	_headless = engine_args.has("--headless") or DisplayServer.get_name() == "headless"
	_role = "server" if (args.has("--server") or engine_args.has("--server")) else "client"
	_name = OS.get_environment(ENV_NAME).strip_edges()
	if _name.is_empty():
		var idx := args.find("--instance")
		if idx >= 0 and idx + 1 < args.size():
			_name = str(args[idx + 1]).strip_edges()
	if _name.is_empty():
		_name = "%s-%d" % [_role, OS.get_process_id()]
	_path = _dir.path_join("%s.json" % _name)
	_parent_pid = OS.get_environment(ENV_PARENT).strip_edges().to_int()
	_parent_lease_path = _dir.path_join("parents").path_join("parent-%d.json" % _parent_pid)
	var stale_raw := OS.get_environment(ENV_STALE_S).strip_edges()
	_stale_s = float(stale_raw) if stale_raw.is_valid_float() else DEFAULT_STALE_S
	_strict_dcs = OS.get_environment(ENV_STRICT_DCS).strip_edges() != "0"
	_resolve_ports(args)
	_started_at = Time.get_unix_time_from_system()
	DirAccess.make_dir_recursive_absolute(_dir)
	_sweep()
	_write_record()
	print("[INSTANCE] 登记 %s（角色=%s pid=%d 游戏口=%d 调试口=%d 目录=%s）" % [
		_name, _role, OS.get_process_id(), _game_port, DebugControlServer.port(), _dir])


## 从命令行解析本实例的端口。**只读不猜**：
## - 游戏口：专用服是自己绑的 `--port`；客户端是要连的 `--smokeport`（缺省回退 `--port`）。
## - 调试口（DCS）：由 `DebugControlServer.port()` 给出**实际监听值**（0 = 没绑上）。
func _resolve_ports(args: Array) -> void:
	var port_idx := args.find("--port")
	var smoke_idx := args.find("--smokeport")
	var smokehost_idx := args.find("--smokehost")
	if _role == "server":
		_game_port = int(args[port_idx + 1]) if port_idx >= 0 and port_idx + 1 < args.size() else NetSession.DEFAULT_PORT
		_connect_host = "0.0.0.0"
	else:
		if smoke_idx >= 0 and smoke_idx + 1 < args.size():
			_game_port = int(args[smoke_idx + 1])
			_connect_host = str(args[smokehost_idx + 1]) if smokehost_idx >= 0 and smokehost_idx + 1 < args.size() else "127.0.0.1"
		elif port_idx >= 0 and port_idx + 1 < args.size():
			_game_port = int(args[port_idx + 1])
			_connect_host = "127.0.0.1"
		else:
			_game_port = NetSession.DEFAULT_PORT
			_connect_host = NetSession.DEFAULT_HOST


func _process(delta: float) -> void:
	if not _enabled:
		return
	_elapsed += delta
	_accum += delta
	if _accum < HEARTBEAT_INTERVAL:
		return
	_accum = 0.0
	if _watchdog_tripped():
		return
	_update_phase()
	_write_record()


## 看门狗：启动器没了就自退 —— 这是"不留僵尸局"的最后一道闸。
##
## ⚠ **不要**用 `OS.is_process_running(_parent_pid)` 判活：Godot 这个 API 只认
## **本进程自己 create_process 出来的子进程**（内部 process_map），对外部启动器的 pid
## 一律返回 false。2026-09-29 实测：驱动进程活得好好的，游戏却立刻判"启动器已退出"
## 并自退，把整轮多开验证打挂。
##
## 改用**租约文件**：启动器每 2s 刷新 `<登记目录>/parents/parent-<pid>.json` 的心跳。
## 文件不再更新 = 启动器已死/已挂（崩溃、taskkill、Ctrl-C 都覆盖，且能覆盖"卡死"），
## 本进程在下一次心跳（2s）内自退。
func _watchdog_tripped() -> bool:
	if _parent_pid <= 0:
		return false
	var lease := _read_record(_parent_lease_path)
	var age := -1.0
	if not lease.is_empty():
		age = Time.get_unix_time_from_system() - float(lease.get("heartbeat_at", 0))
	if age >= 0.0 and age <= _parent_stale_s():
		_parent_seen = true
		_parent_miss_streak = 0
		return false
	# 读不到（文件正在被替换/尚未落盘）或读到但过期：都要**连续两次**才动手。
	# 误杀一局的代价远大于晚几秒自退 —— 这是"宁可晚，不可错"的取舍。
	_parent_miss_streak += 1
	if not _parent_seen:
		# 租约还没出现过：启动顺序不保证，先给启动器一个宽限期。
		if _elapsed <= maxf(_parent_stale_s() * 2.0, 20.0):
			return false
	if _parent_miss_streak < 2:
		print("[INSTANCE] 启动器租约 %s 一时读不到或已过期（age=%s，已 %.0fs）→ 再看一拍（实例 %s）"
			% [_parent_lease_path.get_file(), ("未出现" if age < 0.0 else "%.1fs" % age), _elapsed, _name])
		return false
	print("[INSTANCE] 启动器 pid=%d 的租约连续 %d 次不可用（age=%s，已运行 %.0fs）→ 本局自退，避免留下僵尸局（实例 %s）"
		% [_parent_pid, _parent_miss_streak, ("未出现" if age < 0.0 else "%.1fs" % age), _elapsed, _name])
	_phase = "launcher_gone"
	_write_record()
	_quit_now()
	return true


## 启动器租约的过期阈值：比实例登记的阈值更宽松 —— "启动器挂了"要判得准，晚几秒自退无所谓。
func _parent_stale_s() -> float:
	return maxf(_stale_s * 3.0, 30.0)


func _update_phase() -> void:
	var dcs_port := DebugControlServer.port()
	if dcs_port > 0:
		_phase = "controllable"
		_ds_error = ""
		return
	_ds_error = DebugControlServer.bind_error() if DebugControlServer.has_method("bind_error") else "not_listening"
	if _elapsed < DCS_GRACE_S:
		_phase = "booting"
		return
	_phase = "dcs_down"
	if _strict_dcs:
		print("[INSTANCE] 调试口未监听（原因=%s）→ 本实例不可控，按严格模式退场（实例 %s）" % [_ds_error, _name])
		_write_record()
		_quit_now()


func _quit_now() -> void:
	_finalize()
	get_tree().quit(1)


## 清扫登记目录 + 识别僵尸：**只报告，不删别人的文件、更不杀进程**。
##
## ⚠ 这里**不能**用 `OS.is_process_running` 判"登记里的 pid 还在不在"：它只认本进程
## spawn 的子进程，对外部 pid 一律 false —— 于是**并行会话正在运行的实例**的登记会被
## 当成"残留"删掉（2026-09-29 实测，靠守门测试才发现）。判据只留一条：**心跳是否过期**。
## 过期 = 疑似残留/僵尸，记进自己登记的 `stale_records` 供工具/人处理；
## 真正的清理（含按 pid 杀僵尸）只由 `tools/dev/match_instance.py reap` 做 ——
## Python 能可靠查 pid：已死则删文件，活着但心跳过期则按 pid 杀。
func _sweep() -> void:
	_stale_records = []
	var dir := DirAccess.open(_dir)
	if dir == null:
		return
	var now := Time.get_unix_time_from_system()
	for file_name in dir.get_files():
		if not file_name.ends_with(".json"):
			continue
		if _dir.path_join(file_name) == _path:
			continue
		var record := _read_record(_dir.path_join(file_name))
		if record.is_empty():
			continue
		var age := now - float(record.get("heartbeat_at", 0))
		if age <= _stale_s:
			continue
		var pid := int(record.get("pid", 0))
		var inst := str(record.get("instance", file_name))
		var entry := {"instance": inst, "pid": pid, "heartbeat_age_s": int(age),
			"role": str(record.get("role", "")), "dcs_port": int(record.get("dcs_port", 0))}
		_stale_records.append(entry)
		print("[INSTANCE] 疑似残留/僵尸：%s pid=%d 心跳过期 %ds（用 tools/dev/match_instance.py reap 清理）"
			% [inst, pid, int(age)])


func _read_record(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {}
	var text := file.get_as_text()
	file.close()
	var parsed = JSON.parse_string(text)
	return parsed if parsed is Dictionary else {}


## 登记文件写入：先写临时文件再原子改名，工具端永远读不到"写了一半"的 JSON。
func _write_record() -> void:
	if _path.is_empty():
		return
	var record := {
		"schema": SCHEMA,
		"instance": _name,
		"pid": OS.get_process_id(),
		"parent_pid": _parent_pid,
		"role": _role,
		"headless": _headless,
		"project": ProjectSettings.globalize_path("res://"),
		"started_at": int(_started_at),
		"heartbeat_at": int(Time.get_unix_time_from_system()),
		"phase": _phase,
		"game_port": _game_port,
		"connect_host": _connect_host,
		"dcs_port": DebugControlServer.port(),
		"dcs_error": _ds_error,
		"test_base": OS.get_environment(ENV_TEST_BASE).strip_edges(),
		"match": _match_info(),
		"stale_records": _stale_records,
	}
	var tmp := "%s.tmp" % _path
	var file := FileAccess.open(tmp, FileAccess.WRITE)
	if file == null:
		push_warning("[INSTANCE] 登记写入失败：%s" % tmp)
		return
	file.store_string(JSON.stringify(record, "  "))
	file.close()
	DirAccess.rename_absolute(tmp, _path)


## 对局信息（尽力而为，字段缺失一律留空，绝不影响对局本身）。
func _match_info() -> Dictionary:
	var info := {"active": false, "match_id": "", "map": ""}
	var tree := get_tree()
	if tree == null:
		return info
	var match_node: Node = tree.get_first_node_in_group("match")
	if match_node == null and tree.current_scene != null:
		match_node = tree.current_scene.find_child("Match", true, false)
	if match_node == null:
		return info
	info["active"] = true
	for key in ["match_id", "MatchId"]:
		var value = match_node.get(key)
		if value != null:
			info["match_id"] = str(value)
			break
	var map_value = match_node.get("map_path")
	if map_value != null:
		info["map"] = str(map_value)
	return info


func _finalize() -> void:
	if _finalized:
		return
	_finalized = true
	if _path.is_empty():
		return
	# 只删**自己的**登记（先确认文件里的 pid 就是本进程，避免误删复用 pid 的新实例）。
	if FileAccess.file_exists(_path):
		var record := _read_record(_path)
		if int(record.get("pid", 0)) == OS.get_process_id():
			DirAccess.remove_absolute(_path)


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_PREDELETE:
		_finalize()


func _exit_tree() -> void:
	_finalize()
