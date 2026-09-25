extends Node

## 副官状态发现/渲染的纯函数守门测试（headless 跑 .tscn）。
##
## 背景（2026-09-20 用户实测）：副官以"外部进程"指挥本局时，面板四行只剩
## "当前状态：副官正在指挥（外部进程）/ 最近行动：—/ 为什么：—"，副官的决策
## 思考完全看不见。修复让面板去发现"正在指挥的副官"写的 hud_status.json 并渲染。
## 这里守门的是其中不依赖文件系统的纯函数：
##   · `_events_file_match_prefix`：事件日志文件名 → 对局身份前缀；
##   · `_select_hud_status`：候选状态挑选（身份对齐 > 自己目录 > 新鲜度）；
##   · `_apply_hud_status`：四行渲染（外部前缀 + 判据备注不能丢，旧格式不能变）。

const AdjutantButtonScript = preload("res://source/ui/AdjutantButton.gd")

var _failures := 0


func _check(cond: bool, msg: String) -> void:
	if cond:
		print("[PASS] " + msg)
	else:
		_failures += 1
		print("[FAIL] " + msg)


func _ready() -> void:
	var node: Node = AdjutantButtonScript.new()

	# --- 事件日志文件名 → 对局身份前缀 ---
	_check(node._events_file_match_prefix(
		"agent_runner_events_20260920_233230_86c6ce43.jsonl") == "86c6ce43",
		"事件日志文件名应解出 match_id 前 8 位")
	_check(node._events_file_match_prefix(
		"agent_runner_events_20260920_233230_nomatch.jsonl") == "nomatch",
		"没挂上对局时应解出 nomatch")
	_check(node._events_file_match_prefix(
		"agent_runner_20260920_233230_86c6ce43.jsonl").is_empty(),
		"非事件日志（无 events）应返回空")
	_check(node._events_file_match_prefix("hud_status.json").is_empty(),
		"状态文件不应被当成事件日志")
	_check(node._events_file_match_prefix("").is_empty(), "空文件名不抛异常")

	# --- 候选状态挑选 ---
	var own_orphan := {
		"dir": "user://adjutant_logs", "own": true,
		"status": {"phase": "观察中", "thinking": "上一局的残留思考"},
		"match": "deadbeef", "mtime": 500,
	}
	var external_current := {
		"dir": "tmp_logs/campaign_accept/hud", "own": false,
		"status": {"phase": "分派任务", "thinking": "正在执行：攻击移动"},
		"match": "86c6ce43", "mtime": 400,
	}
	var external_other := {
		"dir": "tmp_logs/temp_room/runner", "own": false,
		"status": {"phase": "应急反应", "thinking": "另一局在跑"},
		"match": "12345678", "mtime": 999,
	}
	# ① 身份对齐的外部候选，必须赢过"更新鲜但身份不符"的自己目录（孤儿 runner 场景）
	var picked: Dictionary = node._select_hud_status(
		[own_orphan, external_current, external_other], "86c6ce43")
	_check(str(picked.get("thinking", "")) == "正在执行：攻击移动",
		"对局身份对齐的候选应优先于更新鲜的其它对局")
	# ② 身份拿不到（空串）时自己这一侧优先
	picked = node._select_hud_status([external_other, own_orphan], "")
	_check(str(picked.get("thinking", "")) == "上一局的残留思考",
		"没有身份信息时自己目录优先")
	# ③ 只有外部候选时取最新鲜的
	picked = node._select_hud_status([external_current, external_other], "")
	_check(str(picked.get("thinking", "")) == "另一局在跑",
		"没有自己目录时取最新鲜的外部候选")
	# ④ 身份对不上任何候选时仍要有内容（新鲜度兜底），不许空白
	picked = node._select_hud_status([external_current, external_other], "ffffffff")
	_check(str(picked.get("thinking", "")) == "另一局在跑",
		"身份都对不上时按新鲜度兜底")
	# ⑤ 全空
	_check(node._select_hud_status([], "86c6ce43").is_empty(), "无候选返回空字典")
	_check(node._select_hud_status([], "").is_empty(), "无候选且无身份返回空字典")

	# --- 四行渲染：外部前缀 + 判据备注 ---
	node._state_label = Label.new()
	node._action_label = Label.new()
	node._reason_label = Label.new()
	node._result_label = Label.new()
	node._apply_hud_status({
		"phase": "分派任务",
		"goal": "阶段：摸底 · 下一目标：工人开采",
		"thinking": "正在执行：攻击移动",
		"why": "战术思考这一轮没成功，先用规则顶住",
		"result": "下发 4 条：攻击移动（丢弃 6 条：等待权威确认×6）",
		"units": 94,
	}, node.PANEL_EXTERNAL, "权威口 24579 对局身份一致")
	_check(node._state_label.text.begins_with(
		"当前状态：" + str(node.PANEL_EXTERNAL) + " · 分派任务"),
		"外部局状态行应带外部进程前缀与阶段")
	_check(node._state_label.text.contains("目标：阶段：摸底"),
		"外部局状态行应保留整局主线目标")
	_check(node._action_label.text == "最近行动：正在执行：攻击移动",
		"外部局最近行动应显示副官在想什么")
	_check(node._reason_label.text == "为什么：战术思考这一轮没成功，先用规则顶住",
		"外部局为什么应显示副官的理由")
	_check(node._result_label.text.contains("下发 4 条：攻击移动"),
		"外部局执行结果应显示本轮下发")
	_check(node._result_label.text.contains("指挥 94 个单位"),
		"执行结果应带指挥单位数")
	_check(node._result_label.text.contains("（权威口 24579 对局身份一致）"),
		"执行结果应附判据说明")

	# --- 旧调用格式（无前缀/备注）不能变 ---
	node._apply_hud_status({"phase": "观察中", "thinking": "正在维持：采集×2"})
	_check(node._state_label.text == "当前状态：观察中",
		"本机 runner 的状态行保持原格式")
	_check(node._action_label.text == "最近行动：正在维持：采集×2",
		"本机 runner 的最近行动保持原格式")
	# 空状态文件 → 四行都是"—"，不许把内部字段名显示出来
	node._apply_hud_status({})
	_check(node._state_label.text == "当前状态：运行中", "空状态回落到运行中")
	_check(node._action_label.text == "最近行动：—", "空状态最近行动为占位符")
	_check(node._reason_label.text == "为什么：—", "空状态为什么为占位符")
	_check(node._result_label.text == "执行结果：—", "空状态执行结果为占位符")

	_run_filesystem_checks(node)
	node.free()
	print("AdjutantHudStatusDiscovery: %d failure(s)" % _failures)
	get_tree().quit(1 if _failures > 0 else 0)


## ---------- 文件系统相关：扫描 + 新鲜度 + 身份前缀（hermetic，用完自清） ----------
## 探针目录按真实布局搭：`<root>/tmp_logs/<标签>/<子目录>/hud_status.json`
## （`_external_hud_dirs` 的入参是"tmp_logs 的父目录"，与工程目录同级语义一致）。
## ⚠ 路径只能写字面量：`path_join` 不是常量表达式，写在 const 里会直接 Parse Error。

const PROBE_ROOT := "user://hud_probe"
const PROBE_TMP := "user://hud_probe/tmp_logs"
const PROBE_HUD := "user://hud_probe/tmp_logs/campaign_accept/hud"
const PROBE_RUNNER := "user://hud_probe/tmp_logs/temp_room"


func _write_probe(dir_path: String, status: Dictionary, events_name: String) -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir_path))
	var handle := FileAccess.open(dir_path.path_join("hud_status.json"), FileAccess.WRITE)
	handle.store_string(JSON.stringify(status))
	handle.close()
	if not events_name.is_empty():
		var events := FileAccess.open(dir_path.path_join(events_name), FileAccess.WRITE)
		events.store_string("{}\n")
		events.close()


func _remove_tree(path: String) -> void:
	var dir := DirAccess.open(path)
	if dir == null:
		return
	for sub in dir.get_directories():
		_remove_tree(path.path_join(str(sub)))
	for name in dir.get_files():
		DirAccess.remove_absolute(path.path_join(str(name)))
	DirAccess.remove_absolute(path)


func _run_filesystem_checks(node: Node) -> void:
	_remove_tree(PROBE_ROOT)
	_write_probe(PROBE_HUD, {
		"phase": "分派任务", "thinking": "正在执行：攻击移动",
		"why": "战术思考这一轮没成功，先用规则顶住",
		"result": "下发 4 条：攻击移动", "units": 94,
	}, "agent_runner_events_20260920_233230_86c6ce43.jsonl")
	# 同根下另一种布局：一层（tmp_logs/<标签>/hud_status.json）
	_write_probe(PROBE_RUNNER, {
		"phase": "观察中", "thinking": "正在维持：采集×2", "units": 4,
	}, "agent_runner_events_20260920_233232_5f6ea36e.jsonl")

	var scanned: Array = node._external_hud_dirs([PROBE_ROOT])
	_check(scanned.has(PROBE_HUD), "扫描应发现两层布局的 hud_status.json")
	_check(scanned.has(PROBE_RUNNER), "扫描应发现一层布局的 hud_status.json")
	_check(scanned.size() == 2, "扫描不应带出目录外的内容（实际 %d）" % scanned.size())

	_check(node._hud_dir_match_prefix(PROBE_HUD) == "86c6ce43",
		"目录的对局身份应取最新事件日志的文件名后缀")
	var candidate: Dictionary = node._hud_candidate(PROBE_HUD, false)
	_check(not candidate.is_empty(), "刚写的状态文件应通过新鲜度闸")
	_check(str(candidate.get("match", "")) == "86c6ce43", "候选应带上对局身份")

	# 端到端：身份对齐的候选必须被挑中（而不是同根下另一局）
	var picked: Dictionary = node._discover_hud_status("86c6ce43", [PROBE_ROOT])
	_check(str(picked.get("thinking", "")) == "正在执行：攻击移动",
		"端到端应挑出对局身份对齐的外部副官状态")
	# 身份未知时也要有内容可显示（新鲜度兜底）
	picked = node._discover_hud_status("", [PROBE_ROOT])
	_check(not picked.is_empty(), "身份未知时也要有内容可显示")

	# 新鲜度闸：刚写的算新鲜，模拟"上一局残留"（now 推后 10 倍窗口）必须判陈旧
	var status_path := PROBE_HUD.path_join("hud_status.json")
	var mtime := int(FileAccess.get_modified_time(status_path))
	_check(node._hud_status_fresh(PROBE_HUD, mtime + 5), "刚写的状态文件应算新鲜")
	_check(not node._hud_status_fresh(PROBE_HUD,
		mtime + int(node.HUD_STATUS_FRESH_SECONDS) + 60),
		"超出新鲜度窗口的状态文件必须判陈旧（上一局残留）")
	# 目录里没有状态文件时不产生候选
	_remove_tree(PROBE_HUD)
	_check(node._hud_candidate(PROBE_HUD, false).is_empty(), "没有状态文件不产生候选")

	_remove_tree(PROBE_ROOT)
