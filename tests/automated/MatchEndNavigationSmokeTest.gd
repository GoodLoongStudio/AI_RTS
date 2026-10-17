extends Node

## 单机对局结束 → 本局对局统计（用户 2026-09-27 需求）端到端冒烟。
##
## 验证三件事：
## ① 真实对局数据链： recorder → MatchReportStore.upsert → last_report_id / get_report；
## ② 结算页（MatchDetail）能按 id 读到本局统计（成长系统读同一份 store，不另造数）；
## ③ MatchEndHandler 退出按钮：单机结束跳 MatchDetail 且返回成长画像（不再回首页）；
##    不伪造：全新 store 不得出现 demo 播种报告，读不到的字段保持 null。

const MatchEndHandlerScene = preload("res://source/match/handlers/MatchEndHandler.tscn")
const MatchDetailScene = preload("res://source/main-menu/MatchDetail.tscn")

const FAKE_MATCH_ID := "local-test-20260927"
const FAKE_REPORT := {
	"report_id": "MR-TEST-001",
	"match_id": FAKE_MATCH_ID,
	"outcome": "victory",
	"duration_seconds": 622.0,
	"map": {"name": "Plain & Simple", "seed": 20260927},
	"mode": "single_player",
	# 对局层没有权威来源的字段：保持 null，不允许编默认值（用户"不要伪造"）。
	"difficulty": null,
	"adjutant": null,
	"overview": {"score": 72},
}

var _failures := 0
var _store: Node
var _tmp_root := ""


func _ready():
	# 测试已经是 root 的子节点。解除 current_scene 身份，使详情页跳转
	# 只切换被测页面，测试宿主仍留在树中执行跳转后的断言。
	get_tree().current_scene = null
	await get_tree().process_frame
	await _check_no_demo_seeding()
	await _check_legacy_demo_dropped()
	await _check_real_report_recorded()
	await _check_detail_reads_report()
	await _check_exit_navigates_to_detail()
	print("Match end navigation smoke test completed: %d failure(s)" % _failures)
	SmokeTestExit.request(get_tree(), 0 if _failures == 0 else 1)


## ① 不伪造：临时存档路径下的全新 store 不得含任何 demo 报告。
func _check_no_demo_seeding() -> void:
	_store = get_node_or_null("/root/MatchReportStore")
	_check(_store != null, "MatchReportStore autoload 应可用")
	if _store == null:
		return
	if _store.has_method("configure_paths"):
		_tmp_root = OS.get_user_data_dir().path_join("match_end_nav_test")
		DirAccess.make_dir_recursive_absolute(_tmp_root)
		var legacy := _tmp_root.path_join("legacy.json")
		_store.configure_paths(_tmp_root.path_join("reports.json"), legacy)
		var loaded: Dictionary = _store.load_all()
		_check(int(loaded.get("seeded_demo", 0)) == 0,
			"不得自动播种 demo 报告（用户 2026-09-27：不要伪造）")
		# 显式演示入口保留（不删他人代码），但本测试不调用它：
		# DemoMatchReports._build_one():159 自身有越界缺陷，且默认路径已不走 demo。
		_check(_store.has_method("seed_demo"), "显式 seed_demo() API 应保留")
		var reports: Array = _store.get("reports")
		var demo_count := 0
		for report in reports:
			if str((report as Dictionary).get("report_id", "")).begins_with("MR-DEMO"):
				demo_count += 1
		_check(demo_count == 0, "首次运行后不得残留 demo 报告（实际 %d 条）" % demo_count)


## ①b 旧存档：mix 了 demo 播种与真实记录 → 加载时剔除 demo，保留真实。
func _check_legacy_demo_dropped() -> void:
	var legacy_file := FileAccess.open(_tmp_root.path_join("reports.json"), FileAccess.WRITE)
	legacy_file.store_string(JSON.stringify([
		{"report_id": "MR-DEMO-001", "match_id": "demo-1", "outcome": "victory"},
		{"report_id": "MR-REAL-777", "match_id": "local-real-1", "outcome": "defeat"},
		{"report_id": "MR-DEMO-006", "match_id": "demo-6", "outcome": "defeat"},
	]))
	legacy_file.close()
	var loaded: Dictionary = _store.load_all()
	var reports: Array = _store.get("reports")
	var demo := 0
	var real := 0
	for entry in reports:
		var rid := str((entry as Dictionary).get("report_id", ""))
		if rid.begins_with("MR-DEMO"):
			demo += 1
		if rid == "MR-REAL-777":
			real += 1
	_check(demo == 0, "旧存档里的 demo 播种报告应被剔除（实际 %d 条）" % demo)
	_check(real == 1, "旧存档里的真实报告必须保留（实际 %d 条）" % real)
	_check(int(loaded.get("dropped_seeded_demo", 0)) == 2,
		"剔除计数应如实上报（实际 %s）" % str(loaded.get("dropped_seeded_demo", 0)))


## ② 真实对局记录：upsert 一份如实报告（缺失字段 null），last_report_id 可定位。
func _check_real_report_recorded() -> void:
	var result: Dictionary = _store.upsert(FAKE_REPORT)
	_check(bool(result.get("ok", false)), "recorder 风格的上报应被接受")
	_check(str(_store.get("last_report_id")) == "MR-TEST-001",
		"upsert 后 last_report_id 应指向本局报告")
	var found: Dictionary = _store.get_report("MR-TEST-001")
	_check(not found.is_empty(), "store 应能按 id 取回本局报告")
	_check(found.get("difficulty") == null, "缺失字段必须保持 null，不得伪造默认值")


## ③ 详情页按 id 读到本局统计（成长系统读同一份 store）。
func _check_detail_reads_report() -> void:
	MatchHistoryNav.return_scene = "res://source/main-menu/PlayerProfile.tscn"
	MatchHistoryNav.open_detail("MR-TEST-001", 0)
	var detail: Node = MatchDetailScene.instantiate()
	add_child(detail)
	await get_tree().process_frame
	var title := detail.get_node_or_null(
		"CenterContainer/PanelContainer/MarginContainer/VBoxContainer/TopBar/Title")
	if title != null:
		_check(str((title as Label).text).contains("MR-TEST-001"),
			"详情页标题应显示本局报告 id（实际：%s）" % str((title as Label).text))
	var growth := get_node_or_null("/root/GrowthStore")
	if growth != null and growth.has_method("ingest_match_reports"):
		var summaries: Array = _store.call("profile_summaries")
		growth.call("ingest_match_reports", summaries)
		var stored: Array = growth.get("match_reports")
		var found_real := false
		for entry in stored:
			if str((entry as Dictionary).get("match_id", "")) == "MR-TEST-001":
				found_real = true
		_check(found_real, "成长系统应摄入本局真实报告（打通对局记录）")
	detail.queue_free()
	await get_tree().process_frame


## ④ 退出按钮：单机结束 → MatchDetail（不是首页），返回成长画像。
func _check_exit_navigates_to_detail() -> void:
	var match_root := Node.new()
	match_root.name = "Match"
	add_child(match_root)
	var outcome_runtime := Node.new()
	outcome_runtime.name = "MatchOutcomeRuntime"
	# 仅测试退出导航，但处理器仍需真实运行时声明的同名信号。
	outcome_runtime.add_user_signal("MatchResolved", [{"name": "resolution", "type": TYPE_DICTIONARY}])
	match_root.add_child(outcome_runtime)
	var handler: CanvasLayer = MatchEndHandlerScene.instantiate()
	match_root.add_child(handler)
	await get_tree().process_frame
	handler._on_exit_button_pressed()
	await get_tree().process_frame
	await get_tree().process_frame
	var scene_name := str(get_tree().current_scene.name) if get_tree().current_scene != null else ""
	_check(scene_name == "MatchDetail", "单机结束应跳到本局对局统计页（实际：%s）" % scene_name)
	_check(str(MatchHistoryNav.return_scene).contains("PlayerProfile"),
		"统计页返回应回到成长系统的玩家画像（实际：%s）" % str(MatchHistoryNav.return_scene))
	# MatchDetail._ready 会消费并清空待处理编号；跳转后应检查页面实际加载的报告。
	var loaded_report: Dictionary = get_tree().current_scene.get("_report") if scene_name == "MatchDetail" else {}
	_check(str(loaded_report.get("report_id", "")) == "MR-TEST-001",
		"统计页应定位到本局报告（实际：%s）" % str(loaded_report.get("report_id", "")))
	_check(MatchHistoryNav.pending_report_id.is_empty(), "详情页应消费本局待处理报告编号")


func _check(condition: bool, message: String) -> void:
	if condition:
		return
	_failures += 1
	push_error("Match end navigation assertion failed: %s" % message)
