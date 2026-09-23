extends Node

## 副官 UI 状态一致性守门测试（2026-09-23 用户截图：按钮"AI 副官：停止" +
## 标题"● 副官尚未启动" + 正文"运行中"三脸互相打脸）。
##
## 守门的不变式：
## ① `_active` 变化时，按钮文案、面板标题、HUD 标题**同源同步**（单一判据）；
## ② 聊天/问答结束后，HUD 状态行恢复**真实状态**，不得硬编码"已接入"
##    （旧实现在副官没启动时也显示"● 副官已接入，正在观察"）；
## ③ `current_state_text()` 与 `_update_status_line()` 写 HUD 的文案同口径；
## ④ `_query_status` 重入守卫存在（协程并发交错曾导致三脸不一致）。

const AdjutantButtonScript = preload("res://source/ui/AdjutantButton.gd")

var _failures := 0


func _check(cond: bool, msg: String) -> void:
	if cond:
		print("[PASS] " + msg)
	else:
		_failures += 1
		print("[FAIL] " + msg)


func _read_source(res_path: String) -> String:
	var fh := FileAccess.open(res_path, FileAccess.READ)
	if fh == null:
		return ""
	var text := fh.get_as_text()
	fh.close()
	return text


func _ready():
	var node: Node = AdjutantButtonScript.new()

	# --- ① 状态判据单源：current_state_text 与 _hud_state_text 一致 ---
	node.set("_active", false)
	node.set("_engine", "")
	_check(node.current_state_text() == "● 副官尚未启动",
		"未启动时 current_state_text 应为'尚未启动'（实际：%s）" % node.current_state_text())
	node.set("_active", true)
	node.set("_engine", "langgraph")
	node.set("_runner_owned", false)
	node.set("_external_runner", false)
	_check(node.current_state_text() == "● 副官运行中（LangGraph）",
		"运行中时应带引擎名（实际：%s）" % node.current_state_text())
	node.set("_external_runner", true)
	_check(node.current_state_text() == "● 副官运行中（外部进程）",
		"外部进程时应如实标注（实际：%s）" % node.current_state_text())
	node.set("_external_runner", false)
	# "启动中"分支依赖心跳新鲜度（读磁盘日志目录），单测环境不稳定，
	# 改为源码级守门：分支必须存在且优先于引擎名后缀。
	var btn_src_early: String = _read_source("res://source/ui/AdjutantButton.gd")
	var starting_idx: int = btn_src_early.find("启动中（等待挂上对局")
	var engine_idx: int = btn_src_early.find("state += \"（%s）\" % engine_label")
	_check(starting_idx > 0 and engine_idx > starting_idx,
		"冷启动'启动中'分支必须存在且优先于引擎名展示")

	# --- ② 重入守卫字段存在 ---
	_check("_query_status_in_flight" in node,
		"_query_status 必须有重入守卫字段（协程并发曾导致三脸不一致）")

	# --- ③ _update_status_line 不再因 _title_label 缺失跳过 HUD 同步 ---
	# 直接检查函数体不再以 _title_label 守卫开头（用反射拿不到源码，改为
	# 验证 _hud_state_text 是独立函数且不依赖 _title_label）。
	node.set("_active", false)
	_check(node._hud_state_text("已停止") == "● 副官尚未启动",
		"_hud_state_text 在未激活时应返回尚未启动")
	node.set("_active", true)
	_check(node._hud_state_text("运行中") == "● 副官运行中",
		"_hud_state_text 在激活时应返回运行中")

	# --- ④ HUD 聊天处理器不得硬编码 ONLINE ---
	var hud_src: String = _read_source("res://source/match/hud/AICommandHUD.gd")
	_check(not hud_src.contains("_set_agent_state(STATE_ONLINE)"),
		"AICommandHUD 不得再硬编码 STATE_ONLINE（副官没启动也会显示已接入）")
	_check(hud_src.contains("_restore_real_adjutant_state"),
		"AICommandHUD 聊天结束必须恢复真实状态")
	_check(hud_src.contains("current_state_text"),
		"AICommandHUD 恢复状态必须向权威源取值")

	# --- ⑤ 按钮与标题成对渲染：_start_local_runner 的成功/已在跑分支都调 _restore_button ---
	var btn_src: String = _read_source("res://source/ui/AdjutantButton.gd")
	var start_idx: int = btn_src.find("func _start_local_runner")
	var stop_idx: int = btn_src.find("func _stop_local_runner")
	_check(start_idx > 0 and stop_idx > start_idx, "应能定位 _start_local_runner 函数体")
	var start_body: String = btn_src.substr(start_idx, stop_idx - start_idx)
	var restore_calls: int = start_body.count("_restore_button()")
	_check(restore_calls >= 2,
		"_start_local_runner 的两条成功路径都必须渲染按钮（实际 %d 次）" % restore_calls)

	# --- ⑥ 轮询体（_poll_tail）与查询（_query_status）不得再各自为政 ---
	_check(btn_src.contains("func _query_status_inner"),
		"_query_status 应有 inner 实现（外层重入守卫包装）")

	if _failures == 0:
		print("Adjutant UI state consistency: 0 failure(s)")
		get_tree().quit(0)
	else:
		print("Adjutant UI state consistency: %d failure(s)" % _failures)
		get_tree().quit(1)
