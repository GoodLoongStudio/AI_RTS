extends Node
## 验证 AdjutantModelService 经 WMI 拉起本地模型服务时**不再弹出可见 cmd 控制台窗口**。
##
## 背景（2026-10-12 用户报告）：启动副官时屏幕上会常驻一个黑窗（标题 cmd.exe，
## 内容是 ollama serve 日志）——因为 WMI 默认启动信息为 cmd 新建可见控制台，
## `start /B` 起来的 ollama 继承该控制台并把日志打在里面。
##
## 本测试**只验证拉起方式**，不触碰真实模型服务：
## - 用一个无害的探针 .cmd（跑几秒 ping）替代 ollama.exe；
## - 真实调用产品代码 `AdjutantModelService._spawn_detached()`（生成 ps1 + WMI 创建进程）；
## - 断言：返回 pid>0、进程存活、**可见控制台窗口数不增加**（窗口统计由外层 PS 完成，
##   本测试把 pid 与本轮生成的 ps1 路径打印出来供外层核对）。
## Windows-only：非 Windows 直接判过（该路径本来就只走 Windows）。

## 探针路径从项目根派生（res://.. 不能直接用于 globalize_path）。
const PROBE_REL := "agent/runs/2026-10-12-adjutant-popup-fix/probe_service.cmd"

var _failures := 0


func _check(cond: bool, msg: String) -> void:
	if cond:
		print("[PASS] " + msg)
	else:
		_failures += 1
		print("[FAIL] " + msg)


func _ready() -> void:
	if OS.get_name() != "Windows":
		print("[SKIP] 非 Windows，本测试只针对 Windows WMI 拉起路径")
		print("Adjutant model spawn hidden test completed: 0 failure(s)")
		get_tree().quit(0)
		return

	var svc: Node = load("res://source/ui/AdjutantModelService.gd").new()
	var probe := ProjectSettings.globalize_path("res://").path_join(PROBE_REL).simplify_path()
	_check(FileAccess.file_exists(probe), "探针命令存在：%s" % probe)
	var models := ProjectSettings.globalize_path("res://").path_join("../nonexistent_models_dir").simplify_path()

	var pid: int = svc.call("_spawn_detached", probe, models)
	_check(pid > 0, "WMI 拉起返回有效 pid（%d）" % pid)
	print("[PROBE] spawned_pid=%d" % pid)

	# 生成的 ps1 必须带上隐藏窗口的启动信息（静态核对产品产物）。
	var ps1_path := ProjectSettings.globalize_path("user://adjutant_logs").path_join(
		"start_model_service.ps1")
	if FileAccess.file_exists(ps1_path):
		var handle := FileAccess.open(ps1_path, FileAccess.READ)
		var text := handle.get_as_text() if handle != null else ""
		if handle != null:
			handle.close()
		_check(text.contains("wscript.exe"), "生成的 ps1 用 wscript 宿主（GUI 子系统，不分配控制台）")
		_check(text.contains("launch_model_service.vbs"), "生成的 ps1 写 VBS 启动器")
		_check(text.contains("CreateObject"), "VBS 内容含 CreateObject（Run style 0 隐藏启动）")
	else:
		_check(false, "生成的 ps1 文件存在：%s" % ps1_path)

	# 返回的 pid 是 WMI 中转 cmd（`cmd /c` 调完即退），不适用存活断言；
	# 用探针自己写的心跳文件证明隐藏控制台里命令**真的在跑**。
	var heartbeat := probe.get_base_dir().path_join("probe_heartbeat.txt")
	if FileAccess.file_exists(heartbeat):
		DirAccess.remove_absolute(heartbeat)
	await get_tree().create_timer(3.0).timeout
	_check(pid > 0, "WMI 拉起返回 pid（%d）" % pid)
	if FileAccess.file_exists(heartbeat):
		var age := int(Time.get_unix_time_from_system()) - FileAccess.get_modified_time(heartbeat)
		_check(age <= 5, "探针心跳新鲜（%d 秒前）——隐藏控制台内命令确实在运行" % age)
	else:
		_check(false, "探针心跳文件存在（%s）" % heartbeat)
		# 收尾：按 pid 树清掉本轮探针（探针自己 ~8s 也会退）。
		OS.execute("taskkill", PackedStringArray(["/F", "/T", "/PID", str(pid)]))

	print("Adjutant model spawn hidden test completed: %d failure(s)" % _failures)
	# 夹具所有权：svc 是本测试 new 出来的裸 Node（不挂树、无人回收），必须显式 free，
	# 否则退出时 ObjectDB/resources 泄漏（与 AdjutantUIStateConsistencyTest 同类缺陷）。
	svc.free()
	get_tree().quit(1 if _failures > 0 else 0)
