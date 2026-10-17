extends Node

## 地图工作台「总进度流程图」状态合同冒烟测试（2026-10-11 提示词 §二）。
##
## 用**隔离可控的 job 数据**直接喂渲染层，不碰真实生成服务、不发 HTTP、不开地图纹理：
## 覆盖 完成 / 进行中 / 等待 / 失败 / 跳过 / done+pass=false / 快速预览未运行 /
## 上游失败不得伪装完成 / 游戏内 skip_engine_check / 重试后旧状态被覆盖 /
## 中心流程图与右侧检查**同源** / 终态不得整块隐藏。
## 这些判据全部来自 `STAGE_ORDER`/`STAGE_TEXT`/`_stage_display` 这一条路径，
## 所以任何一处口径漂移都会同时反映在两侧（正是要钉住的合同）。

const MapGenerationScene = preload("res://source/main-menu/MapGeneration.tscn")

var _failures := 0
var _finished := false
var _page: Node = null


func _ready():
	get_tree().create_timer(90.0).timeout.connect(_on_failsafe)
	_page = MapGenerationScene.instantiate()
	add_child(_page)
	for _i in 6:
		await get_tree().process_frame
	_run_cases()
	_finish()


func _on_failsafe():
	if _finished:
		return
	print("FAIL: 看门狗超时——流程图测试中断未收尾")
	_finish()


func _finish():
	if _finished:
		return
	_finished = true
	print("Map progress flow smoke test completed: %d failure(s)" % _failures)
	SmokeTestExit.request(get_tree(), 0 if _failures == 0 else 1, _page)


func _check(condition: bool, message: String) -> void:
	if condition:
		return
	_failures += 1
	print("FAIL: %s" % message)
	push_error("Map progress flow assertion failed: %s" % message)


func _flow_text(stage_id: String) -> String:
	var nodes: Dictionary = _page.get("_flow_nodes")
	var label: Label = nodes[stage_id]["state"]
	return label.text


func _inspect_text(stage_id: String) -> String:
	var rows: Dictionary = _page.get("_stage_rows")
	var label: Label = rows[stage_id]["state"]
	return label.text


func _phase_text() -> String:
	return (_page.get("_progress_phase") as Label).text


func _detail_text() -> String:
	return (_page.get("_progress_detail") as Label).text


func _banner_visible() -> bool:
	return (_page.get("_progress_banner") as Control).visible


func _stage_node(over: Dictionary, status: String, extra: Dictionary = {}) -> Dictionary:
	var stage := {"status": status}
	for key in over:
		stage[key] = over[key]
	for key in extra:
		stage[key] = extra[key]
	return stage


func _render(job: Dictionary) -> void:
	_page.call("_render_job", job)


func _run_cases() -> void:
	_case_a_running_full()
	_case_b_done_but_check_failed()
	_case_c_quick_preview()
	_case_d_skip_engine_check()
	_case_e_upstream_failure()
	_case_f_retry_overwrites_stale()
	_case_g_single_source_and_terminal_kept()
	_case_h_real_backend_job()
	_case_i_stale_http_response_dropped()
	_case_j_history_switch_and_disconnect()


## 用**真实生成服务跑出来的 job**（不是合成数据）驱动渲染，证明状态合同对真数据也成立。
## 记录由 agent/runs/20261011-adjutant-map-progress/drive_workbench.py 落在独立端口 8767 上。
const REAL_JOB_RECORD := "G:/AIRTS/AI_RTS/agent/runs/20261011-adjutant-map-progress/workbench-g2.json"


func _case_h_real_backend_job() -> void:
	if not FileAccess.file_exists(REAL_JOB_RECORD):
		print("SKIP: 没有真实后端 job 记录，跳过真数据用例（先跑 drive_workbench.py g2）")
		return
	var handle := FileAccess.open(REAL_JOB_RECORD, FileAccess.READ)
	if handle == null:
		print("SKIP: 真实 job 记录不可读")
		return
	var parsed = JSON.parse_string(handle.get_as_text())
	if not (parsed is Dictionary):
		_check(false, "真实 job 记录不是 JSON 对象")
		return
	var job: Dictionary = (parsed as Dictionary).get("final", {})
	_check(str(job.get("status", "")) == "done", "真实预览任务应为 done")
	var stages := _page_stages(job)
	_check(str(stages.get("g2_terrain", {}).get("status", "")) == "done",
		"真实后端必须把 G2 写进 stages（这是本轮补的后端合同）：%s" % str(stages.keys()))
	_render(job)
	_check(_flow_text("g1_input").contains("完成"), "真实 job G1 渲染错：%s" % _flow_text("g1_input"))
	_check(_flow_text("g2_terrain").contains("完成"), "真实 job G2 渲染错：%s" % _flow_text("g2_terrain"))
	for stage_id in ["g3_content", "g4_scene", "engine"]:
		_check(_flow_text(stage_id).contains("快速预览未运行"),
			"真实预览 job 的 %s 不能显示完成：%s" % [stage_id, _flow_text(stage_id)])
	_check(_phase_text().contains("2/2 阶段完成"), "真实 job 总状态错：%s" % _phase_text())


func _page_stages(job: Dictionary) -> Dictionary:
	return _page.call("_job_stages", job)


func _case_a_running_full() -> void:
	_render({
		"id": "A", "status": "running", "target": "full", "duration": 12.0,
		"stages": {
			"g1_input": _stage_node({}, "done", {"pass": true, "duration_s": 1.2}),
			"g2_terrain": _stage_node({}, "running"),
		},
		"progress": {"stage": "G2", "phase": "地形候选", "attempt": 3, "limit": 5},
	})
	_check(_banner_visible(), "running 时进度区必须可见")
	_check(_flow_text("g1_input").contains("完成"), "G1 完成态文案错：%s" % _flow_text("g1_input"))
	_check(_flow_text("g2_terrain").contains("进行中"), "G2 进行中态文案错：%s" % _flow_text("g2_terrain"))
	_check(_flow_text("g3_content").contains("等待"), "G3 未开始应显示等待：%s" % _flow_text("g3_content"))
	_check(_phase_text().contains("1/5 阶段完成"), "总状态计数错：%s" % _phase_text())
	_check(_phase_text().contains("地形生成 进行中"), "总状态当前阶段错：%s" % _phase_text())
	_check(_detail_text().contains("第 2/5 阶段"), "无真实百分比时应显示第 N/5 阶段：%s" % _detail_text())
	_check(_detail_text().contains("3/5"), "应显示后端真实 attempt/limit：%s" % _detail_text())


func _case_b_done_but_check_failed() -> void:
	_render({
		"id": "B", "status": "running", "target": "full", "duration": 20.0,
		"stages": {
			"g1_input": _stage_node({}, "done", {"pass": true, "duration_s": 1.0}),
			"g2_terrain": _stage_node({}, "done", {"pass": false, "error": "最小路宽 3.1m 不足"}),
		},
		"progress": {"stage": "G2", "phase": "地形复核图渲染中"},
	})
	_check(_flow_text("g2_terrain").contains("检查未通过"),
		"done+pass=false 不得显示完成：%s" % _flow_text("g2_terrain"))
	_check(not _flow_text("g2_terrain").ends_with("完成"), "pass=false 不能涂成完成：%s" % _flow_text("g2_terrain"))
	_check(_phase_text().contains("1 个阶段检查未通过"), "总状态需说明未过检：%s" % _phase_text())
	var nodes: Dictionary = _page.get("_flow_nodes")
	var state_label: Label = nodes["g2_terrain"]["state"]
	_check(state_label.get_theme_color("font_color") != SystemUIStyle.GREEN,
		"检查未通过不得使用完成绿")


func _case_c_quick_preview() -> void:
	_render({
		"id": "C", "status": "done", "target": "g2", "duration": 5.0,
		"stages": {
			"g1_input": _stage_node({}, "done", {"pass": true, "duration_s": 1.0}),
			"g2_terrain": _stage_node({}, "done", {"pass": true, "duration_s": 2.0}),
		},
		"progress": {},
	})
	_check(_banner_visible(), "快速预览终态也要保留流程结果")
	for stage_id in ["g3_content", "g4_scene", "engine"]:
		_check(_flow_text(stage_id).contains("快速预览未运行"),
			"%s 在快速预览下不能显示完成：%s" % [stage_id, _flow_text(stage_id)])
	_check(_phase_text().contains("2/2 阶段完成"), "预览应按 G1/G2 计：%s" % _phase_text())


func _case_d_skip_engine_check() -> void:
	_render({
		"id": "D", "status": "done", "target": "full", "duration": 30.0,
		"skip_engine_check": true,
		"stages": {
			"g1_input": _stage_node({}, "done", {"pass": true}),
			"g2_terrain": _stage_node({}, "done", {"pass": true}),
			"g3_content": _stage_node({}, "done", {"pass": true}),
			"g4_scene": _stage_node({}, "done", {"pass": true}),
			"engine": _stage_node({}, "skipped",
				{"reason": "游戏内生成：跳过引擎验收（截图/导航检查由玩家实局代替）"}),
		},
		"progress": {"stage": "ENGINE", "phase": "地图已装进工程，跳过引擎验收"},
	})
	_check(_flow_text("engine").contains("跳过：游戏内生成路径"),
		"游戏内跳过引擎验收必须写明原因：%s" % _flow_text("engine"))
	_check(not _flow_text("engine").contains("完成"), "跳过不得显示引擎验收完成：%s" % _flow_text("engine"))


func _case_e_upstream_failure() -> void:
	_render({
		"id": "E", "status": "error", "target": "full", "duration": 9.0,
		"stages": {
			"g1_input": _stage_node({}, "done", {"pass": true}),
			"g2_terrain": _stage_node({}, "error", {"error": "候选地形全部被硬拒"}),
		},
		"progress": {"stage": "G2", "phase": "布局失败"},
	})
	_check(_flow_text("g2_terrain").contains("失败"), "G2 失败态错：%s" % _flow_text("g2_terrain"))
	for stage_id in ["g3_content", "g4_scene", "engine"]:
		_check(_flow_text(stage_id).contains("未运行：上游阶段失败"),
			"%s 不得在失败后伪装完成：%s" % [stage_id, _flow_text(stage_id)])
	_check(_phase_text().contains("失败阶段：地形生成"), "总状态要指出失败阶段：%s" % _phase_text())


func _case_f_retry_overwrites_stale() -> void:
	_render({
		"id": "F", "status": "running", "target": "full", "duration": 4.0,
		"stages": {
			"g1_input": _stage_node({}, "running"),
		},
		"progress": {"stage": "G1", "phase": "改试新布局"},
	})
	_check(_flow_text("g1_input").contains("进行中"), "重试后旧状态必须被新 stage 覆盖：%s" % _flow_text("g1_input"))
	_check(_flow_text("g2_terrain").contains("等待"),
		"布局轮换重做上游时后续节点应回到等待：%s" % _flow_text("g2_terrain"))
	_check(not _phase_text().contains("失败"), "重试不得沿用上一轮失败文案：%s" % _phase_text())


func _case_g_single_source_and_terminal_kept() -> void:
	_render({
		"id": "G", "status": "done", "target": "full", "duration": 40.0,
		"stages": {
			"g1_input": _stage_node({}, "done", {"pass": true}),
			"g2_terrain": _stage_node({}, "done", {"pass": true}),
			"g3_content": _stage_node({}, "done", {"pass": true}),
			"g4_scene": _stage_node({}, "done", {"pass": true}),
			"engine": _stage_node({}, "done", {"pass": true, "duration_s": 62.0}),
		},
		"progress": {"stage": "ENGINE", "phase": "导航验收通过"},
	})
	_check(_banner_visible(), "全流程完成后仍要保留流程图")
	for stage_id in ["g1_input", "g2_terrain", "g3_content", "g4_scene", "engine"]:
		var flow := _flow_text(stage_id).replace("✓ ", "")
		_check(flow == _inspect_text(stage_id),
			"中心流程图与右侧检查必须同源（%s：%s vs %s）" % [stage_id, flow, _inspect_text(stage_id)])
	_check(_phase_text().contains("5/5 阶段完成"), "完成局总状态错：%s" % _phase_text())
	_render({})
	_check(not _banner_visible(), "无任务时进度区应隐藏")


## 迟到 HTTP 响应不得覆盖新请求（沿用工作台已有的 token 机制）。
func _case_i_stale_http_response_dropped() -> void:
	var http := HTTPRequest.new()
	_page.add_child(http)
	var first := int(_page.call("_next_http_token", http))
	var second := int(_page.call("_next_http_token", http))
	_check(not bool(_page.call("_is_current_http_token", http, first)),
		"旧 token 必须失效，否则迟到的上一个响应会覆盖新状态")
	_check(bool(_page.call("_is_current_http_token", http, second)),
		"最新 token 必须有效")
	http.queue_free()


## 切历史 / 服务断连：流程图只反映**所选 job**，且网络断连不得被写成阶段失败或阶段完成。
func _case_j_history_switch_and_disconnect() -> void:
	var running := {
		"id": "RUN", "status": "running", "target": "full", "duration": 8.0,
		"stages": {"g1_input": {"status": "done", "pass": true},
			"g2_terrain": {"status": "running"}},
		"progress": {"stage": "G2", "phase": "地形候选"},
	}
	_page.set("_active_id", "RUN")
	_page.set("_jobs", [running, {
		"id": "HIST", "status": "done", "target": "g2", "duration": 3.0,
		"stages": {"g1_input": {"status": "done", "pass": true},
			"g2_terrain": {"status": "done", "pass": true}}, "progress": {}}])
	# 正在生成时切去看历史记录：流程必须跟着所选 job 走。
	_render({"id": "HIST", "status": "done", "target": "g2", "duration": 3.0,
		"stages": {"g1_input": {"status": "done", "pass": true},
			"g2_terrain": {"status": "done", "pass": true}}, "progress": {}})
	_check(_flow_text("g3_content").contains("快速预览未运行"),
		"切历史后必须显示所选（历史）job 的状态：%s" % _flow_text("g3_content"))
	var title: Label = _page.get("_map_title")
	_check(title.text.contains("另有任务生成中"),
		"活动生成任务要用简短标记提示，不与所选 job 混用：%s" % title.text)
	# 服务断连：job 一条都没再回来。不得凭空把阶段涂成完成或失败。
	_page.set("_active_id", "")
	_render({"id": "GONE", "status": "running", "target": "full", "duration": 1.0,
		"stages": {}, "progress": {}})
	_check(_flow_text("g1_input").contains("等待"),
		"断连时没有 stage 数据就该显示等待：%s" % _flow_text("g1_input"))
	for stage_id in ["g2_terrain", "g3_content", "g4_scene", "engine"]:
		_check(not _flow_text(stage_id).contains("完成"),
			"断连不许伪装完成（%s=%s）" % [stage_id, _flow_text(stage_id)])
