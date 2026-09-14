extends Node

## 历史对局系统验收探针（数据层 + 版面层）。
##
## 用法：
##   godot --headless --path . res://tools/probe_match_history.tscn
##   godot --headless --path . res://tools/probe_match_history.tscn -- --res=1280x720,1600x900
##
## ⚠️ 断言文案里**禁用**这些词：`Parse Error` / `SCRIPT ERROR` / `Assertion failed` …
##    runner（`run_full_regression.ps1`）用 `-match` 比对禁用词表，而它是**正则且大小写不敏感**，
##    探针自己打印的文案里出现小写 "parse error" 也会把本用例判红
##    （实测踩过：`match-history` 长期假红，全因一句 "为 null 说明脚本有 parse error"）。
##    要表达同一件事就写「脚本加载失败」。
##
## 判据：逐条打印 `[PROBE] PASS/FAIL`，末行 `[PROBE] >>> PASS n / FAIL m`；
##      FAIL > 0 时退出码 1。
##
## 为什么用真实场景启动而不是 `--script`：Autoload（GrowthStore / MatchReportStore）
## 只在正常启动流程里注册，`--script` 会把"Autoload 未注册"误报成脚本错误。
##
## 数据层断言全部用**临时文件**（user://probe_match_history_*.json），绝不碰玩家真实档案。

const PAGES := [
	["历史列表", "res://source/main-menu/MatchHistory.tscn"],
	["对局详情", "res://source/main-menu/MatchDetail.tscn"],
]

const DEFAULT_RESOLUTIONS := ["1280x720", "1600x900"]

var _pass := 0
var _fail := 0
var _failures: Array[String] = []


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	await _check_schema()
	await _check_demo()
	await _check_requirement_coverage()
	await _check_scoring()
	await _check_legacy_and_garbage()
	await _check_store()
	await _check_profile_bridge()
	await _check_recorder()
	await _check_sparse_report()
	# 版面层必须在**探针自己的隔离档案**上跑：真实档案可以被并行会话或历史遗留写脏，
	# 断言"列表应有 10 条"就变成环境依赖的假红（实测踩过：真实档案里两条记录 report_id 为空）。
	await _prepare_isolated_store()
	await _check_legacy_json_file()
	await _check_facets_exclude_missing()
	for spec in _requested_resolutions():
		await _check_layout(spec)
	await _check_empty_state()
	print("[PROBE] >>> PASS %d / FAIL %d" % [_pass, _fail])
	# 回归清单（config/full_regression_suite.json）按这行找 expected_marker。
	print("Match history smoke test completed: %d failure(s)" % _fail)
	for line in _failures:
		print("[PROBE] FAILED: %s" % line)
	SmokeTestExit.request(get_tree(), 0 if _fail == 0 else 1)


## 把 autoload 的 `MatchReportStore` 切到探针专用临时档案并重新播种 Demo。
## 之后所有版面断言看到的都是确定性的 10 场 Demo，与玩家真实档案彻底隔离。
func _prepare_isolated_store() -> void:
	var store: Node = get_node_or_null("/root/MatchReportStore")
	if store == null:
		_check(false, "MatchReportStore autoload 可用")
		return
	var save_path := "user://probe_match_history_layout.json"
	var legacy_path := "user://probe_match_history_layout_legacy.json"
	DirAccess.remove_absolute(ProjectSettings.globalize_path(save_path))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(legacy_path))
	store.configure_paths(save_path, legacy_path)
	var count := (store.reports as Array).size()
	_check(count == 10, "隔离档案首次运行播种 10 场 Demo（实际 %d）" % count)
	_check(str(store.save_path) == save_path, "隔离档案路径已生效（%s）" % str(store.save_path))


func _requested_resolutions() -> Array:
	var requested: Array = []
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--res="):
			for token in arg.substr(6).split(","):
				if not token.strip_edges().is_empty():
					requested.append(token.strip_edges())
	if requested.is_empty():
		return DEFAULT_RESOLUTIONS.duplicate()
	return requested


# ==================== 数据层 ====================

func _check_schema() -> void:
	var schema := load("res://source/history/MatchReportSchema.gd")
	_check(schema != null, "MatchReportSchema.gd 可加载")
	# 空输入不崩、且不编造
	var empty: Dictionary = schema.normalize({})
	_check(empty["report"] is Dictionary, "空输入归一化后仍返回报告结构")
	_check(empty["report"]["outcome"] == null, "空报告 outcome 为 null（不默认成 victory/defeat）")
	_check(empty["missing"].size() > 40, "空报告记录了大量缺失字段（%d 项）" % empty["missing"].size())
	_check(float(empty["report"]["data_completeness"]["ratio"]) < 0.2,
		"空报告数据完整度低（%.2f），不会伪装成数据齐全" % empty["report"]["data_completeness"]["ratio"])
	# 非字典输入不崩
	var weird: Dictionary = schema.normalize("这不是报告")
	_check(weird["errors"].size() > 0, "非字典输入被记录为错误而不是崩溃")
	_check(weird["report"]["report_id"] == null, "非字典输入不会凭空产生 report_id")
	# 前向兼容：高版本未知字段必须保留
	var future: Dictionary = schema.normalize({"schema_version": 99, "report_id": "MR-FUTURE",
		"brand_new_field": {"a": 1}})
	_check(future["report"]["brand_new_field"]["a"] == 1,
		"高于当前版本的未知字段被原样保留（前向兼容）")
	_check(future["errors"].size() > 0, "遇到更高版本会告警")


func _check_demo() -> void:
	var demo := load("res://source/history/DemoMatchReports.gd")
	var a: Array = demo.build()
	var b: Array = demo.build()
	_check(a.size() == 10, "Demo 生成 10 场对局（实际 %d）" % a.size())
	_check(str(a[0]["report_id"]) == str(b[0]["report_id"])
		and float(a[0]["duration_seconds"]) == float(b[0]["duration_seconds"]),
		"Demo 数据可复现（同种子两次生成结果一致）")
	var statuses := {}
	var outcomes := {}
	var demo_flags := 0
	var evidence_missing := 0
	var cross_conflicts := 0
	var validate_errors := 0
	for report in a:
		var entry: Dictionary = report
		statuses[str(entry["hermes_analysis"]["status"])] = true
		outcomes[str(entry["outcome"])] = true
		if bool(entry["demo"]) and entry["demo_seed"] != null:
			demo_flags += 1
		for section in ["observations", "suggestions"]:
			for item in entry["hermes_analysis"][section]:
				if not (item is Dictionary) or (item as Dictionary)["evidence"].is_empty():
					evidence_missing += 1
		if float(entry["overview"]["damage_dealt"]) != float(entry["combat"]["damage"]["dealt"]):
			cross_conflicts += 1
		for issue in MatchReportSchema.validate(entry):
			if str((issue as Dictionary)["level"]) == "error":
				validate_errors += 1
	_check(demo_flags == a.size(), "全部 Demo 都带 demo 标记与 demo_seed（%d/%d）" % [demo_flags, a.size()])
	_check(evidence_missing == 0, "Hermes 每条结论都带 evidence（缺口 %d）" % evidence_missing)
	_check(cross_conflicts == 0, "总览与战斗伤害同源（冲突 %d 条）" % cross_conflicts)
	_check(validate_errors == 0, "Demo 报告通过结构校验（error %d 条）" % validate_errors)
	_check(outcomes.size() >= 3, "覆盖多种胜负结果（%s）" % ", ".join(PackedStringArray(outcomes.keys())))
	_check(statuses.size() >= 4, "覆盖多种 Hermes 状态（%s）" % ", ".join(PackedStringArray(statuses.keys())))
	_check(statuses.has("cached"), "存在 cached 状态（Hermes 不可用时展示缓存）")
	# 半途退出的 Demo：必须明确 aborted，且缺失区块留空而不是补零
	var aborted: Dictionary = {}
	for report in a:
		if str((report as Dictionary)["outcome"]) == "aborted":
			aborted = report
	_check(not aborted.is_empty(), "存在半途退出的 Demo 对局")
	if not aborted.is_empty():
		_check(aborted["combat"]["quality"]["focus_fire"] == null,
			"半途退出对局的不可得字段为 null（不补 0 冒充数据）")
		_check(float(aborted["data_completeness"]["ratio"]) < 0.9,
			"半途退出对局完整度偏低（%.2f）" % aborted["data_completeness"]["ratio"])
		var has_abort_event := false
		for event in aborted["timeline"]:
			if str((event as Dictionary)["type"]) == "match_aborted":
				has_abort_event = true
		_check(has_abort_event, "半途退出的时间线里有一条 match_aborted")
	# 时间线覆盖度：必须包含用户要求的关键节点
	var required_types := ["match_start", "first_resource_node", "first_unit_produced",
		"first_structure_built", "first_scout", "first_contact", "first_attack",
		"first_expansion", "tech_unlocked", "hermes_advice", "objective_completed",
		"objective_failed", "major_battle", "victory"]
	var seen_types := {}
	for report in a:
		for event in (report as Dictionary)["timeline"]:
			seen_types[str((event as Dictionary)["type"])] = true
	var missing_types := PackedStringArray()
	for type_key in required_types:
		if not seen_types.has(type_key):
			missing_types.append(type_key)
	_check(missing_types.is_empty(), "时间线覆盖用户要求的关键事件类型（缺：%s）"
		% ("、".join(missing_types) if not missing_types.is_empty() else "无"))


func _check_scoring() -> void:
	var demo := load("res://source/history/DemoMatchReports.gd")
	var reports: Array = demo.build()
	var zero_basis := 0
	var partial_count := 0
	for report in reports:
		var score: Dictionary = (report as Dictionary)["performance_score"]
		for dimension in MatchReportSchema.SCORE_DIMENSIONS:
			var entry: Dictionary = score["breakdown"][dimension]
			if entry["score"] != null and str(entry["basis"]).length() < 4:
				zero_basis += 1
		if bool(score["partial"]):
			partial_count += 1
	_check(zero_basis == 0, "每个有分的维度都给出了评分依据（空依据 %d）" % zero_basis)
	_check(partial_count > 0, "存在只给出部分维度评分的对局（%d 场），并标明了 partial" % partial_count)
	var sparse := {"report_id": "MR-SPARSE", "outcome": "victory"}
	var sparse_score: Dictionary = MatchReportScoring.evaluate(sparse)
	_check(sparse_score["total"] == null, "无数据时不给总分（null），而不是给 0 分")
	_check(bool(sparse_score["partial"]), "无数据时标记 partial")


func _check_legacy_and_garbage() -> void:
	# 旧版（v1 极简结构）迁移：保留真相、其余留空
	var legacy := {
		"match_id": "demo-777", "outcome": "victory",
		"resources": {"gathered": 1280, "spent": 1060},
		"production": {"units": 34, "routes": ["机械化步兵", "无人机"]},
		"construction": {"structures": 12, "value": 0.72},
		"combat": {"damage_dealt": 8420, "damage_taken": 5160, "units_lost": 11},
		"key_events": ["快速扩张", "中期反攻"],
		"growth_levels": {"combat_power": 2},
	}
	var migrated: Dictionary = MatchReportSchema.migrate_legacy(legacy, 1)
	_check(str(migrated["outcome"]) == "victory", "旧版迁移保留 outcome")
	_check(int(migrated["overview"]["units_produced"]) == 34, "旧版迁移保留生产单位数")
	_check(bool(migrated["migrated_from_legacy"]), "旧版迁移报告被标记 migrated_from_legacy")
	_check(migrated["combat"]["quality"]["focus_fire"] == null,
		"旧版没有的字段保持 null（不补默认值）")
	_check(float(migrated["data_completeness"]["ratio"]) < 0.6,
		"旧版迁移报告完整度偏低（%.2f），如实反映信息缺失" % migrated["data_completeness"]["ratio"])
	# 已经是新版结构的输入再次迁移 → 不重复迁移
	var again: Dictionary = MatchReportSchema.migrate_legacy(migrated, 2)
	_check(str(again["report_id"]) == str(migrated["report_id"]), "已是新版的报告不会被二次改写")


func _check_store() -> void:
	var store: Node = load("res://source/history/MatchReportStore.gd").new()
	add_child(store)
	var save_path := "user://probe_match_history_store.json"
	var legacy_path := "user://probe_match_history_legacy.json"
	DirAccess.remove_absolute(ProjectSettings.globalize_path(save_path))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(legacy_path))
	store.configure_paths(save_path, legacy_path)
	_check(store.reports.size() == 10, "首次运行播种 10 场 Demo（实际 %d）" % store.reports.size())
	_check(store.stats()["demo"] == 10 and store.stats()["real"] == 0, "统计区分 Demo 与真实数据")

	# 去重：同一 match_id 重复上报只留一条（防止统计翻倍）
	var before: int = store.reports.size()
	var duplicate: Dictionary = store.reports[0].duplicate(true)
	duplicate["report_id"] = "MR-PROBE-DUP"
	var outcome: Dictionary = store.upsert(duplicate)
	_check(str(outcome["action"]) != "inserted", "同一 match_id 二次上报被识别为重复（%s）" % outcome["action"])
	_check(store.reports.size() == before, "去重后条数不变（%d）" % store.reports.size())

	# 半途退出：写进 store 不崩，且 outcome 为 aborted
	var aborted: Dictionary = MatchReportSchema.aborted_report({
		"report_id": "MR-PROBE-ABORT", "match_id": "probe-abort", "player_id": "local_player_demo",
		"duration_seconds": 61.0, "outcome": "victory",
	}, "探针模拟中途退出")
	store.upsert(aborted)
	var stored: Dictionary = store.get_report("MR-PROBE-ABORT")
	_check(not stored.is_empty() and str(stored["outcome"]) == "aborted",
		"半途退出的报告可落盘且 outcome 被改写为 aborted")
	_check(stored["combat"]["quality"]["reaction_time_s"] == null,
		"半途退出报告缺失字段仍是 null")

	# 旧版文件迁移 + 占位 Demo 跳过
	var legacy_file := FileAccess.open(legacy_path, FileAccess.WRITE)
	legacy_file.store_string(JSON.stringify([
		{"match_id": "demo-001", "outcome": "victory", "resources": {"gathered": 1, "spent": 1}},
		{"match_id": "real-888", "outcome": "defeat", "resources": {"gathered": 900, "spent": 880}},
	]))
	legacy_file.close()
	var save2 := "user://probe_match_history_store2.json"
	DirAccess.remove_absolute(ProjectSettings.globalize_path(save2))
	store.configure_paths(save2, legacy_path)
	var skipped := int(store.last_load["skipped_placeholder"])
	var has_legacy_report := false
	for report in store.reports:
		if str((report as Dictionary)["match_id"]) == "real-888":
			has_legacy_report = true
	_check(has_legacy_report, "旧版真实档案被迁移进新库")
	_check(skipped == 1, "旧版占位 Demo 被跳过（跳过 %d 条）" % skipped)

	# 损坏 JSON 不崩、不删原文件
	var broken_path := "user://probe_match_history_broken.json"
	var broken := FileAccess.open(broken_path, FileAccess.WRITE)
	broken.store_string("{\"reports\": [ {\"report_id\": ")
	broken.close()
	store.configure_paths(broken_path, legacy_path)
	_check(store.reports.is_empty(), "损坏 JSON 被降级为空列表（不崩）")
	_check(store.last_load["errors"].size() > 0, "损坏 JSON 被记录进 last_load.errors")
	_check(FileAccess.file_exists(broken_path), "损坏文件被保留而不是删除")

	# 空库筛选与空状态
	var empty_result: Array = store.query({"outcome": "victory"})
	_check(empty_result.is_empty(), "空库查询返回空数组")
	var facets: Dictionary = store.facets()
	_check((facets["maps"] as Array).is_empty(), "空库时筛选项为空（不预先编造选项）")

	# 真实 Demo 库的筛选 / 排序
	store.configure_paths(save_path, legacy_path)
	var victories: Array = store.query({"outcome": "victory"})
	var wrong := 0
	for report in victories:
		if str((report as Dictionary)["outcome"]) != "victory":
			wrong += 1
	_check(wrong == 0 and victories.size() > 0, "按胜负筛选正确（%d 胜 / 共 %d）"
		% [victories.size(), store.reports.size()])
	var searched: Array = store.query({"search": "MR-DEMO-003"})
	_check(searched.size() == 1, "按编号搜索命中 1 条（实际 %d）" % searched.size())
	var by_map: Array = store.query({"map": str(facets_maps(store)[0])})
	_check(by_map.size() > 0, "按地图筛选有结果")
	var sorted_desc: Array = store.query({"sort": "date_desc"})
	var sorted_asc: Array = store.query({"sort": "date_asc"})
	_check(str(sorted_desc[0]["created_at"]) > str(sorted_desc[sorted_desc.size() - 1]["created_at"]),
		"按日期降序排序正确")
	_check(str(sorted_asc[0]["created_at"]) < str(sorted_asc[sorted_asc.size() - 1]["created_at"]),
		"按日期升序排序正确")
	_check(sorted_desc[0]["report_id"] != sorted_asc[0]["report_id"], "两种排序结果不同（排序真的生效）")

	# 清理：purge_demo 清干净 Demo
	var removed: int = store.purge_demo()
	_check(removed == 10, "一键清除 Demo 数据（清除 %d 条）" % removed)
	_check(store.stats()["demo"] == 0, "清除后 Demo 计数归零")
	store.queue_free()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(save_path))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(save2))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(legacy_path))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(broken_path))


func facets_maps(store: Node) -> Array:
	var facets: Dictionary = store.facets()
	return facets["maps"] if not (facets["maps"] as Array).is_empty() else ["__none__"]


func _check_profile_bridge() -> void:
	var demo := load("res://source/history/DemoMatchReports.gd")
	var reports: Array = demo.build()
	var summary: Dictionary = MatchReportSchema.profile_summary(reports[0])
	_check(summary.has("resources") and summary.has("combat") and summary.has("production"),
		"画像投影包含 MatchReportAdapter 需要的全部字段")
	_check(float(summary["resources"]["gathered"]) > 0.0, "画像投影保留采集量")
	_check(str(summary["match_id"]).begins_with("MR-"), "画像投影的 match_id 可追溯回原报告")
	# 把报告喂给现有适配器，确认不会崩且产出合法快照（只读校验，不落盘）。
	var adapter := load("res://source/growth/MatchReportAdapter.gd")
	var snapshot: Dictionary = adapter.build_profile_snapshot("probe_player",
		[summary, MatchReportSchema.profile_summary(reports[1])], {})
	_check(int(snapshot["sample_count"]) == 2, "画像快照统计样本数为 2")
	_check(snapshot["dimensions"]["combat"] != null, "画像快照给出战斗维度")


func _check_recorder() -> void:
	var recorder: Node = load("res://source/history/MatchReportRecorder.gd").new()
	add_child(recorder)
	recorder.begin({
		"map": {"name": "探针地图", "path": "", "seed": 1234, "size": "50×50", "players": 4},
		"mode": "custom", "difficulty": "normal",
		"adjutant": {"type": "前线指挥官", "level": 2},
		"player_id": "probe_player", "match_id": "probe-recorder",
	})
	# 模拟对局事件：只推进权威计数，不触任何对局 API。
	MatchSignals.unit_production_finished.emit(null, null)
	MatchSignals.unit_production_finished.emit(null, null)
	MatchSignals.unit_construction_finished.emit(null)
	MatchSignals.unit_died.emit(null)
	MatchSignals.not_enough_resources_for_production.emit(null)
	recorder.contribute("combat.damage", "dealt", 4200.0)
	recorder.contribute("combat.damage", "taken", 2600.0)
	var report: Dictionary = recorder.build_report()
	_check(int(report["overview"]["units_produced"]) == 2, "记录器统计到 2 个单位下线")
	_check(int(report["overview"]["structures_built"]) == 1, "记录器统计到 1 座建筑建成")
	_check(float(report["combat"]["damage"]["dealt"]) == 4200.0, "外部补充的权威伤害被写入报告")
	_check(float(report["overview"]["damage_dealt"]) == 4200.0,
		"总览与战斗分区共享同一数字（不存在两套统计）")
	_check(report["economy"]["totals"]["gathered"] == null,
		"记录器拿不到的采集总量保持 null（不估算）")
	_check(float(report["data_completeness"]["ratio"]) < 1.0,
		"真实对局报告如实标明完整度 %.2f" % report["data_completeness"]["ratio"])
	_check(not bool(report["demo"]), "真实对局报告不带 demo 标记")
	_check(str(report["timeline"][0]["type"]) == "match_start", "记录器时间线以 match_start 开头")
	recorder.free()




## 缺字段必须"什么都留不下"：不能变成 "unknown"，也不能在 UI 上渲染成 "<null>"。
## 这条纪律直接对应需求里的**不允许因数据缺失而编造统计**。
func _check_sparse_report() -> void:
	# 1) 标签函数：null / 空串 → "—"（"我们没有这个值"）；
	#    "unknown" → "未知"（"明确未知"）。两者在 UI 上必须能区分。
	_check(MatchReportSchema.mode_label(null) == "—", "缺失的模式渲染成 —（而不是「未知」）")
	_check(MatchReportSchema.difficulty_label(null) == "—", "缺失的难度渲染成 —")
	_check(MatchReportSchema.outcome_label(null) == "—", "缺失的胜负渲染成 —")
	_check(MatchReportSchema.mode_label("unknown") == "未知",
		"「明确未知」仍渲染成「未知」—— 与「没有这个值」必须能区分")
	
	# 2) 一份"对局层只能给出这些"的稀疏报告（= MatchHistoryHook 的真实产物形状）。
	var recorder: Node = load("res://source/history/MatchReportRecorder.gd").new()
	add_child(recorder)
	recorder.begin({
		"player_id": "probe_sparse", "match_id": "probe-sparse",
		"mode": null, "difficulty": null,
		"adjutant": {"type": null, "level": null},
		"map": {"name": null, "path": null},
	})
	var report: Dictionary = recorder.build_report()
	recorder.free()
	
	_check(report["mode"] == null, "拿不到模式时报告里是 null（不是 \"unknown\"）")
	_check(report["difficulty"] == null, "拿不到难度时报告里是 null")
	var map_section: Dictionary = report["map"]
	_check(map_section["name"] == null, "拿不到地图名时是 null")
	_check(map_section["path"] == null, "拿不到地图路径时是 null")
	var adjutant: Dictionary = report["adjutant"]
	_check(adjutant["type"] == null, "拿不到副官类型时是 null")
	
	# 3) 序列化文本里不许出现 str(null) 的字面量：它会一路漏到档案与 UI。
	_check(not JSON.stringify(report).contains("<null>"), "序列化后的报告不含字面量 <null>")
	
	# 4) 完整度必须如实低：这个形状绝不该拿到高分（否则画面会显得"数据很全"）。
	_check(float(report["data_completeness"]["ratio"]) < 0.6,
		"稀疏报告如实给出低完整度 %.2f" % report["data_completeness"]["ratio"])


## 筛选项不许把"没有这个值"变成一个可选项（否则玩家会看到名叫 "<null>" 的筛选项）。
## 在**探针自己的隔离档案**上跑，跑完还原，不影响后续版面断言。
func _check_facets_exclude_missing() -> void:
	var store: Node = get_node_or_null("/root/MatchReportStore")
	if store == null:
		_check(false, "MatchReportStore autoload 可用（筛选项检查）")
		return
	var before := (store.reports as Array).size()
	var facets_before: Dictionary = store.facets()
	
	var recorder: Node = load("res://source/history/MatchReportRecorder.gd").new()
	add_child(recorder)
	recorder.begin({
		"player_id": "probe_sparse", "match_id": "probe-sparse",
		"mode": null, "difficulty": null,
		"adjutant": {"type": null, "level": null},
		"map": {"name": null, "path": null},
	})
	var report: Dictionary = recorder.build_report()
	recorder.free()
	var result: Dictionary = store.upsert(report)
	_check(str(result.get("action", "")) == "inserted", "缺字段的报告可以入库（不因缺字段被拒）")
	
	var facets_after: Dictionary = store.facets()
	for key in ["maps", "modes", "difficulties"]:
		var before_list: Array = facets_before[key]
		var after_list: Array = facets_after[key]
		_check(after_list.size() == before_list.size(),
			"缺字段的报告不给筛选「%s」增加任何选项（%d → %d）"
			% [key, before_list.size(), after_list.size()])
		_check(not str(after_list).contains("<null>"), "筛选「%s」不含字面量 <null>" % key)
	
	# 还原：后面的版面断言要求隔离档案恰好是 10 场 Demo。
	store.remove(str(report.get("report_id", "")))
	_check((store.reports as Array).size() == before, "筛选项检查后档案已还原（%d 场）" % before)

# ==================== 版面层 ====================

## 版面条令（与既有 probe_system_ui 同一口径）：
## 1) **不允许"未溢出却显示滚动条"** —— 这是 SHOW_ALWAYS 的经典症状；
## 2) 顶层面板必须完全落在视口内，不允许被裁；
## 3) 内容确实溢出时**允许**出现滚动条（详情页/列表页的数据量本来就随对局增长）。
func _check_layout(spec: String) -> void:
	var parts := spec.split("x")
	if parts.size() != 2:
		return
	var size := Vector2i(int(parts[0]), int(parts[1]))
	for entry in PAGES:
		await _check_page(entry[0], entry[1], size)
	await _check_history_page(size)
	await _check_detail_page(size)


func _check_page(display_name: String, scene_path: String, size: Vector2i) -> void:
	if not ResourceLoader.exists(scene_path):
		_check(false, "%s：场景存在（%s）" % [display_name, scene_path])
		return
	var packed := load(scene_path) as PackedScene
	if packed == null:
		_check(false, "%s：场景可加载" % display_name)
		return
	get_window().size = size
	MatchHistoryNav.pending_report_id = ""
	MatchHistoryNav.pending_tab = 0
	var page = packed.instantiate()
	add_child(page)
	await get_tree().process_frame
	await get_tree().process_frame
	await get_tree().process_frame

	# 脚本没挂上 = 该页面脚本有 parse error。此时页面只是个裸 Control，
	# 后面的断言会全部落空，探针就会变成"假绿"。所以这里必须显式判红。
	_check(page.get_script() != null, "%s：场景脚本已加载（为 null 说明脚本加载失败）" % display_name)

	var viewport := get_viewport().get_visible_rect().size
	var problems: Array[String] = []
	for node in page.find_children("*", "ScrollContainer", true, false):
		var scroll := node as ScrollContainer
		var bar := scroll.get_v_scroll_bar()
		if bar.visible and bar.max_value <= bar.page + 0.5:
			problems.append("%s 未溢出却显示滚动条" % scroll.name)
	_check(problems.is_empty(), "%s @%dx%d：没有多余的常驻滚动条（%s）"
		% [display_name, size.x, size.y, "；".join(problems)])

	var panel := page.get_node_or_null("CenterContainer/PanelContainer") as Control
	if panel != null:
		var rect := panel.get_global_rect()
		_check(rect.end.x <= viewport.x + 0.5 and rect.end.y <= viewport.y + 0.5
			and rect.position.x >= -0.5 and rect.position.y >= -0.5,
			"%s @%dx%d：顶层面板完全落在视口内（%s）"
				% [display_name, size.x, size.y, str(rect)])
	page.queue_free()
	await get_tree().process_frame


func _check_history_page(size: Vector2i) -> void:
	get_window().size = size
	var page = load("res://source/main-menu/MatchHistory.tscn").instantiate()
	add_child(page)
	await get_tree().process_frame
	await get_tree().process_frame
	# 脚本没加载（parse error）时 Rows 仍是 tscn 声明节点（所以 rows 不会为 null），
	# 后面调 `page._refresh()` 会直接抛错中断协程 ⇒ 必须在这里堵住，否则探针假绿。
	if page.get_script() == null:
		_check(false, "历史列表页脚本已加载（为 null 说明 MatchHistory.gd 加载失败）")
		page.queue_free()
		return
	var rows := page.get_node_or_null(ROOT_HISTORY + "/ListPanel/ListScroll/Rows") as VBoxContainer
	_check(rows != null, "列表页能找到记录容器")
	if rows == null:
		page.queue_free()
		return
	var demo_count := 0
	for child in rows.get_children():
		if child is Button:
			demo_count += 1
	# 渲染条数必须与档案条数一致：任一记录若 report_id 为空会被去重逻辑丢掉，
	# 表现就是"列表静默少一条"，这条断言专门盯它。
	var store_node := get_node_or_null("/root/MatchReportStore")
	var stored_names := PackedStringArray()
	if store_node != null:
		for report in store_node.reports:
			stored_names.append(str((report as Dictionary).get("report_id", "")))
	_check(stored_names.size() == 10, "隔离档案里有 10 条记录（实际 %d）" % stored_names.size())
	var blank_ids := 0
	for report_id in stored_names:
		if report_id.strip_edges().is_empty() or report_id == "<null>":
			blank_ids += 1
	_check(blank_ids == 0, "每条记录都有非空 report_id（空 id %d 条）" % blank_ids)
	_check(demo_count == stored_names.size(),
		"列表渲染条数与档案一致（渲染 %d / 档案 %d）" % [demo_count, stored_names.size()])
	var first := rows.get_child(0) as Button
	_check(first != null and first.get_signal_connection_list("pressed").size() > 0,
		"列表记录绑定了点击进入详情")
	# 筛选：只剩失败
	page._filters["outcome"] = "defeat"
	page._refresh()
	await get_tree().process_frame
	var defeat_rows := _count_buttons(rows)
	_check(defeat_rows > 0 and defeat_rows < demo_count,
		"按胜负筛选生效（失败 %d 条 < 全部 %d 条）" % [defeat_rows, demo_count])
	# 搜索
	page._filters["outcome"] = "all"
	page._filters["search"] = "MR-DEMO-003"
	page._refresh()
	await get_tree().process_frame
	_check(_count_buttons(rows) == 1, "按对局编号搜索命中 1 条（实际 %d）" % _count_buttons(rows))
	# 筛选无结果 ≠ 崩溃：必须落到空状态
	page._filters["search"] = "不存在的对局编号"
	page._refresh()
	await get_tree().process_frame
	var text := _collect_text(rows)
	_check(text.contains("没有符合当前筛选条件的对局"), "筛选无结果时显示空状态文案")
	page._filters["search"] = ""
	page._refresh()
	await get_tree().process_frame
	_check(_count_buttons(rows) >= 10, "清除筛选后恢复全部记录")
	# 点击 → 进入对应详情（在 store 层验证导航契约，避免真的切场景）
	var store := get_node_or_null("/root/MatchReportStore")
	var target := str((store.reports[0] as Dictionary)["report_id"])
	MatchHistoryNav.open_detail(target)
	_check(MatchHistoryNav.take_pending_report_id() == target, "点击记录会把报告 id 传给详情页")
	page.queue_free()
	await get_tree().process_frame


func _check_detail_page(size: Vector2i) -> void:
	get_window().size = size
	# 半途退出的对局：详情页必须能正常打开并显示 aborted
	var store := get_node_or_null("/root/MatchReportStore")
	var aborted_id := ""
	var analyzed_id := ""
	for report in store.reports:
		if str((report as Dictionary)["outcome"]) == "aborted":
			aborted_id = str((report as Dictionary)["report_id"])
		elif str((report as Dictionary)["hermes_analysis"]["status"]) == "completed":
			analyzed_id = str((report as Dictionary)["report_id"])
	_check(not aborted_id.is_empty(), "Demo 里存在半途退出的对局可打开")
	MatchHistoryNav.open_detail(aborted_id)
	var page = load("res://source/main-menu/MatchDetail.tscn").instantiate()
	add_child(page)
	await get_tree().process_frame
	await get_tree().process_frame
	await get_tree().process_frame
	# 脚本没加载（parse error）时页面只是裸 Control：必须判红并早退，
	# 否则下面每一处 `page._xxx` 都会抛错中断协程，探针变成"假绿"。
	if page.get_script() == null:
		_check(false, "对局详情页脚本已加载（为 null 说明 MatchDetail.gd 加载失败）")
		page.queue_free()
		return
	_check(str(page._report.get("report_id", "")) == aborted_id,
		"半途退出对局的详情页正常打开（不崩）")
	_check(page._tab_bar.tab_count == 6, "详情页有 6 个标签页（实际 %d）" % page._tab_bar.tab_count)
	# TabBar 标签不能被挤在一起：每个标签的可点宽度必须比文字宽出内边距。
	# （`SystemUIStyle._style_tab_bar` 曾用 `flat()`，content margin 归零 ⇒ 六个标签
	#   渲染成 "总览经济生产与建设战斗时间线"，一个字都读不出来。）
	var tab_font: Font = page._tab_bar.get_theme_font("font")
	if tab_font != null:
		var tab_font_size: int = page._tab_bar.get_theme_font_size("font_size")
		var cramped := PackedStringArray()
		for index in range(page._tab_bar.tab_count):
			var title: String = str(page._tab_bar.get_tab_title(index))
			var needed: float = tab_font.get_string_size(
				title, HORIZONTAL_ALIGNMENT_LEFT, -1, tab_font_size).x + 8.0
			if page._tab_bar.get_tab_rect(index).size.x + 0.5 < needed:
				cramped.append(title)
		_check(cramped.is_empty(), "标签页标签之间有内边距（没挤在一起）：%s" % "、".join(cramped))
	else:
		_check(false, "TabBar 取到主题字体（否则无法判定标签是否挤在一起）")
	var label_counts: Array = []
	for index in range(6):
		page._select_tab(index)
		await get_tree().process_frame
		var visible := 0
		for child in page._pages:
			if (child as Control).visible:
				visible += 1
		_check(visible == 1, "标签 %d「%s」切换后只有一页可见" % [index, TABS_DETAIL[index]])
		var page_node := page._pages[index] as Node
		var labels := page_node.find_children("*", "Label", true, false)
		# 不用多行 lambda：GDScript 的单行 lambda 体遇到换行会把 `and …` 当成新语句。
		var chart_found := false
		for descendant in page_node.find_children("*", "", true, false):
			var script_ref: Variant = (descendant as Node).get_script()
			if script_ref != null \
					and str((script_ref as Script).resource_path).ends_with("ResourceCurveChart.gd"):
				chart_found = true
				break
		label_counts.append(labels.size())
		_check(labels.size() > 3, "标签 %d「%s」渲染出内容（%d 个文本节点）"
			% [index, TABS_DETAIL[index], labels.size()])
		if index == 1:
			_check(chart_found, "经济页包含资源曲线控件")
	# 需求覆盖度：新增的统计项必须**渲染到页面上**（数据结构里有 ≠ 玩家看得到）。
	var combat_labels := _labels_of(page._pages[3])
	_check(combat_labels.has("侦察单位数") and combat_labels.has("单位存活率"),
		"战斗页渲染「单位统计 11 项」汇总区")
	var build_labels := _labels_of(page._pages[2])
	_check(build_labels.has("建造开工数") and build_labels.has("同时在建峰值"),
		"生产与建设页渲染新增的 6 项建设统计")
	var all_overview_labels := _labels_of(page._pages[0])
	_check(all_overview_labels.has("峰值军力"), "总览页渲染峰值军力")
	# 事实与推断分区：自然语言只出现在最后一个标签页
	var overview_labels := _labels_of(page._pages[0])
	_check(not overview_labels.has("HERMES 观察（自然语言，属推断）"),
		"总览页不出现 Hermes 自然语言分区（事实与推断分区）")
	var hermes_labels := _labels_of(page._pages[5])
	_check(hermes_labels.has("HERMES 观察（自然语言，属推断）"), "成长与 Hermes 页有观察分区")
	# 有没有 Hermes 分析结果，断言的方向相反 —— 这条专门盯"不许把推断写成事实"。
	var hermes_status := str((page._report.get("hermes_analysis", {}) as Dictionary).get("status", "none"))
	if hermes_status == "completed" or hermes_status == "cached":
		_check(hermes_labels.any(func(text: String) -> bool: return text.begins_with("依据：")),
			"Hermes 结论都带出「依据：…」")
	else:
		_check(not hermes_labels.any(func(text: String) -> bool: return text.begins_with("依据：")),
			"Hermes 无分析结果（status=%s）时不编造带依据的结论" % hermes_status)
		_check(hermes_labels.has("本局没有此类内容。"),
			"Hermes 无数据时给出显式空状态（status=%s）" % hermes_status)
	# 时间线筛选
	page._select_tab(4)
	await get_tree().process_frame
	var before := _timeline_count(page)
	page._set_timeline_filter("结算")
	await get_tree().process_frame
	var after := _timeline_count(page)
	_check(before > 0 and after > 0 and after < before,
		"时间线按事件类型筛选生效（%d → %d）" % [before, after])
	page._set_timeline_filter("")
	await get_tree().process_frame
	_check(_timeline_count(page) == before, "清除时间线筛选后恢复全部事件")
	page.queue_free()
	await get_tree().process_frame

	# 已分析的对局：Hermes 分区要有内容且带证据
	if not analyzed_id.is_empty():
		MatchHistoryNav.open_detail(analyzed_id, 5)
		var page2 = load("res://source/main-menu/MatchDetail.tscn").instantiate()
		add_child(page2)
		await get_tree().process_frame
		await get_tree().process_frame
		var labels := _labels_of(page2._pages[5])
		_check(labels.any(func(text: String) -> bool: return text.begins_with("依据：")),
			"已分析对局的 Hermes 分区给出带依据的结论")
		var score_labels := _labels_of(page2._pages[0])
		_check(score_labels.any(func(text: String) -> bool: return text.begins_with("依据：")),
			"总览页评分区逐维给出评分依据")
		page2.queue_free()
		await get_tree().process_frame


func _labels_of(page_node: Node) -> Array[String]:
	## 返回 `Array[String]` 而不是 `PackedStringArray`：后者没有 `contains()` / `any()`，
	## 断言里要用它们做"文本存在/前缀存在"判断。
	var out: Array[String] = []
	for node in page_node.find_children("*", "Label", true, false):
		out.append(str((node as Label).text))
	return out


func _timeline_count(page) -> int:
	var body: VBoxContainer = page._timeline_body
	if body == null:
		return 0
	var count := 0
	for child in body.get_children():
		if child is PanelContainer:
			count += 1
	return count


func _count_buttons(rows: Node) -> int:
	var count := 0
	for child in rows.get_children():
		if child is Button:
			count += 1
	return count


func _collect_text(node: Node) -> String:
	var parts := PackedStringArray()
	for label in node.find_children("*", "Label", true, false):
		parts.append(str((label as Label).text))
	return " ".join(parts)


const ROOT_HISTORY := "CenterContainer/PanelContainer/MarginContainer/VBoxContainer"
const TABS_DETAIL := ["总览", "经济", "生产与建设", "战斗", "时间线", "成长与 Hermes"]


func _check_legacy_json_file() -> void:
	# 旧版本 JSON 文件（v1 极简结构）落到磁盘后，列表页必须能读、能显示、不报解析错误。
	var store: Node = get_node_or_null("/root/MatchReportStore")
	var backup_save: String = str(store.save_path)
	var backup_legacy: String = str(store.legacy_path)
	var legacy_path := "user://probe_legacy_history.json"
	var save_path := "user://probe_legacy_save.json"
	DirAccess.remove_absolute(ProjectSettings.globalize_path(save_path))
	var file := FileAccess.open(legacy_path, FileAccess.WRITE)
	file.store_string(JSON.stringify([
		{"match_id": "old-001", "outcome": "victory", "resources": {"gathered": 900, "spent": 700},
			"production": {"units": 20, "routes": ["步兵"]}, "construction": {"structures": 7, "value": 0.5},
			"combat": {"damage_dealt": 3000, "damage_taken": 2000, "units_lost": 5},
			"key_events": ["旧版事件"], "growth_levels": {"combat_power": 1}},
	]))
	file.close()
	store.configure_paths(save_path, legacy_path)
	var page = load("res://source/main-menu/MatchHistory.tscn").instantiate()
	add_child(page)
	await get_tree().process_frame
	await get_tree().process_frame
	# 脚本没加载（parse error）时 Rows 仍是 tscn 声明节点（所以 rows 不会为 null），
	# 后面调 `page._refresh()` 会直接抛错中断协程 ⇒ 必须在这里堵住，否则探针假绿。
	if page.get_script() == null:
		_check(false, "历史列表页脚本已加载（为 null 说明 MatchHistory.gd 加载失败）")
		page.queue_free()
		return
	var rows := page.get_node_or_null(ROOT_HISTORY + "/ListPanel/ListScroll/Rows") as VBoxContainer
	var text := _collect_text(rows)
	_check(text.contains("MR-LEGACY-001"), "旧版本 JSON 报告被迁移后出现在列表里（不报解析错误）")
	_check(int(store.last_load["migrated"]) == 1, "旧版本档案迁移计数为 1")
	page.queue_free()
	await get_tree().process_frame
	store.configure_paths(backup_save, backup_legacy)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(legacy_path))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(save_path))


func _check_empty_state() -> void:
	var store: Node = get_node_or_null("/root/MatchReportStore")
	var backup_save: String = str(store.save_path)
	var backup_legacy: String = str(store.legacy_path)
	var empty_path := "user://probe_empty_history.json"
	var file := FileAccess.open(empty_path, FileAccess.WRITE)
	file.store_string(JSON.stringify({"schema_version": 2, "reports": []}))
	file.close()
	store.configure_paths(empty_path, "user://probe_nonexistent_legacy.json")
	_check((store.reports as Array).is_empty(), "空档案文件读取后报告数为 0（不会被重新播种）")
	var page = load("res://source/main-menu/MatchHistory.tscn").instantiate()
	add_child(page)
	await get_tree().process_frame
	await get_tree().process_frame
	# 脚本没加载（parse error）时 Rows 仍是 tscn 声明节点（所以 rows 不会为 null），
	# 后面调 `page._refresh()` 会直接抛错中断协程 ⇒ 必须在这里堵住，否则探针假绿。
	if page.get_script() == null:
		_check(false, "历史列表页脚本已加载（为 null 说明 MatchHistory.gd 加载失败）")
		page.queue_free()
		return
	var rows := page.get_node_or_null(ROOT_HISTORY + "/ListPanel/ListScroll/Rows") as VBoxContainer
	var text := _collect_text(rows)
	_check(text.contains("暂无历史对局记录"), "没有数据时显示空状态而不是空白页")
	page.queue_free()
	await get_tree().process_frame
	store.configure_paths(backup_save, backup_legacy)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(empty_path))
	await _check_default_entry_points()


## 入口不回归：成长入口页与玩家画像页都要能打开，且画像页的历史按钮指向新列表页。
func _check_default_entry_points() -> void:
	# 两个入口页都要在最小分辨率下不溢出，并且真的挂上了历史系统入口。
	get_window().size = Vector2i(1280, 720)
	var viewport := get_viewport().get_visible_rect().size
	for entry in [["成长入口", "res://source/main-menu/Growth.tscn"],
			["玩家画像", "res://source/main-menu/PlayerProfile.tscn"]]:
		var page = (load(str(entry[1])) as PackedScene).instantiate()
		add_child(page)
		await get_tree().process_frame
		await get_tree().process_frame
		_check(page.get_script() != null, "%s 页脚本已加载" % str(entry[0]))
		var panel := page.get_node_or_null("CenterContainer/PanelContainer") as Control
		_check(panel != null, "%s 页在历史系统接入后仍可正常构建" % str(entry[0]))
		if panel != null:
			var rect := panel.get_global_rect()
			_check(rect.end.x <= viewport.x + 0.5 and rect.end.y <= viewport.y + 0.5,
				"%s 页 @1280x720 顶层面板落在视口内（%s）" % [str(entry[0]), str(rect)])
		page.queue_free()
		await get_tree().process_frame

	# 【2026-09-15 用户要求】成长页**不再挂**「历史对局」入口：现在只有 2 张卡
	# （永久加点 / 玩家画像）。历史系统本身仍在，只是入口收敛到玩家画像页（下面继续断言）。
	var growth = (load("res://source/main-menu/Growth.tscn") as PackedScene).instantiate()
	add_child(growth)
	await get_tree().process_frame
	await get_tree().process_frame
	var cards := growth.get_node_or_null(
		"CenterContainer/PanelContainer/MarginContainer/VBoxContainer/Cards") as VBoxContainer
	_check(cards != null, "成长页能找到卡片容器")
	if cards != null:
		_check(cards.get_child_count() == 2,
			"成长页有 2 张入口卡（实际 %d）" % cards.get_child_count())
		_check(not _collect_text(cards).contains("历史对局"),
			"成长页不再挂「历史对局」入口（2026-09-15 用户要求）")
		_check(_collect_text(cards).contains("玩家画像"), "成长页原有入口卡没被顶掉")
	growth.queue_free()
	await get_tree().process_frame

	# 玩家画像页的历史按钮必须已接线（旧实现是 AcceptDialog，现在是页面导航）。
	var profile = (load("res://source/main-menu/PlayerProfile.tscn") as PackedScene).instantiate()
	add_child(profile)
	await get_tree().process_frame
	await get_tree().process_frame
	var history_button := profile.get_node_or_null(
		"CenterContainer/PanelContainer/MarginContainer/VBoxContainer/Body/Insights/InsightsBox/HistoryButton") as Button
	_check(history_button != null, "玩家画像页有历史入口按钮")
	if history_button != null:
		_check(history_button.get_signal_connection_list("pressed").size() > 0,
			"玩家画像页的历史入口按钮已接线")
	profile.queue_free()
	await get_tree().process_frame


func _check(condition: bool, message: String) -> void:
	if condition:
		_pass += 1
		print("[PROBE] PASS %s" % message)
		return
	_fail += 1
	_failures.append(message)
	print("[PROBE] FAIL %s" % message)


## 需求覆盖度审计：把需求里写死的**数量**变成机器可判的断言。
##
## 为什么单列一条：需求逐条给了「伤害统计 11 项 / 单位统计 11 项 / 战斗质量 13 项 /
## 建设统计约 20 项 / 总览约 20 项 / 时间线 ≥21 类」这类硬数字。靠人肉扫字段表迟早漏，
## 这里固化成断言 —— 以后谁删了字段，探针立刻变红。
func _check_requirement_coverage() -> void:
	var template: Dictionary = MatchReportSchema.TEMPLATE
	var overview: Dictionary = template.get("overview", {}) if template.get("overview", {}) is Dictionary else {}
	var construction: Dictionary = template.get("construction", {}) \
		if template.get("construction", {}) is Dictionary else {}
	var combat: Dictionary = template.get("combat", {}) if template.get("combat", {}) is Dictionary else {}
	var damage: Dictionary = combat.get("damage", {}) if combat.get("damage", {}) is Dictionary else {}
	var unit_stats: Dictionary = combat.get("unit_stats", {}) if combat.get("unit_stats", {}) is Dictionary else {}
	var quality: Dictionary = combat.get("quality", {}) if combat.get("quality", {}) is Dictionary else {}
	var combat_overview: Dictionary = combat.get("overview", {}) \
		if combat.get("overview", {}) is Dictionary else {}
	var production: Dictionary = template.get("production", {}) if template.get("production", {}) is Dictionary else {}
	var composition: Dictionary = production.get("composition", {}) \
		if production.get("composition", {}) is Dictionary else {}
	# 注意：这里必须数**叶子**而不是键 —— `overview` 有 3 个键是资源对（A/B 两项）。
	# 用 `.size()` 会得到 17（键数），把"实际 20 项"误判成不达标。
	_check(_count_variant_leaves(overview) >= 20,
		"总览区 ≥20 项指标（实际 %d）" % _count_variant_leaves(overview))
	_check(_count_variant_leaves(production) >= 10,
		"生产统计 ≥10 项（实际 %d）" % _count_variant_leaves(production))
	_check(_count_variant_leaves(construction) >= 20,
		"建设统计 ≥20 项（实际 %d）" % _count_variant_leaves(construction))
	_check(combat_overview.size() == 13, "战斗总览 13 项（实际 %d）" % combat_overview.size())
	_check(damage.size() == 11, "伤害统计 11 项（实际 %d）" % damage.size())
	_check(unit_stats.size() == 11, "单位统计 11 项（实际 %d）" % unit_stats.size())
	_check(quality.size() == 13, "战斗质量 13 项（实际 %d）" % quality.size())
	_check(MatchReportSchema.TIMELINE_TYPES.size() >= 21,
		"时间线事件类型 ≥21 类（实际 %d）" % MatchReportSchema.TIMELINE_TYPES.size())
	_check(MatchReportSchema.SCORE_DIMENSIONS.size() == 6, "对局表现评分拆 6 维")
	for key in ["physical", "energy", "explosive", "friendly_fire"]:
		_check(damage.has(key), "伤害统计包含 %s" % key)
	_check(composition.size() == 6, "单位构成 6 项口径（实际 %d）" % composition.size())

	# ---- 汇总纪律：空明细 ⇒ 全 null（"未测量"不是 0）----
	var empty: Dictionary = MatchReportSchema.derive_unit_stats([])
	var non_null := 0
	for key in empty:
		if empty[key] != null:
			non_null += 1
	_check(empty.size() == 11 and non_null == 0,
		"没有单位明细时单位统计全为 null（非 null %d 项）" % non_null)
	# ---- 明细缺列 ⇒ 该项 null。recorder 的行只有 produced/lost，没有 killed。----
	var sparse: Dictionary = MatchReportSchema.derive_unit_stats([
		{"id": "soldier", "produced": 4, "lost": 1},
	])
	_check(sparse.get("kills", "x") == null, "明细没有 killed 列时不给编造 0（kills=null）")
	_check(sparse.get("damage_per_unit", "x") == null, "明细没有伤害列时不给编造 0")
	_check(int(sparse.get("produced", -1)) == 4 and int(sparse.get("lost", -1)) == 1,
		"已测量的列照常汇总")
	_check(int(sparse.get("alive", -1)) == 3, "存活数 = 生产 - 损失")
	# ---- 归一化过的行会把缺失键补成 null：null 不能被当成 0，也不能 int(null) 崩掉 ----
	var nulled: Dictionary = MatchReportSchema.derive_unit_stats([
		{"id": "tank", "produced": 3, "lost": null, "killed": null, "damage_dealt": null},
	])
	_check(int(nulled.get("produced", -1)) == 3, "补成 null 的行仍能汇总已测量列（produced=3）")
	_check(nulled.get("lost", "x") == null and nulled.get("alive", "x") == null,
		"损失列未测量 ⇒ 损失与存活数均为 null（不给 0）")
	_check(nulled.get("survival_rate", "x") == null, "损失列未测量 ⇒ 存活率为 null")
	_check(nulled.get("kills", "x") == null, "明细有 killed 键但值为 null 时不给编造 0")

	# ---- Demo：新增字段必须真的有值，不能只是结构占位 ----
	var demo := load("res://source/history/DemoMatchReports.gd")
	var reports: Array = demo.build()
	var blank_stats := 0
	var mismatch := 0
	var blank_peak := 0
	var blank_construction := 0
	var stats_missing := 0
	var inconsistent := 0
	for report in reports:
		var entry: Dictionary = report
		var stats: Dictionary = entry["combat"]["unit_stats"]
		if stats.size() != 11:
			stats_missing += 1
		for key in stats:
			if stats[key] == null:
				blank_stats += 1
		# 同源：汇总必须等于对同一份明细重新推导的结果（不允许出现第三套数字）
		var again: Dictionary = MatchReportSchema.derive_unit_stats(entry["combat"]["units"])
		for key in stats:
			if stats[key] != again.get(key, null):
				mismatch += 1
				break
		if entry["overview"].get("peak_army_value", null) == null:
			blank_peak += 1
		for key in ["build_started", "build_cancelled", "avg_build_time_s", "rebuild_count",
				"repair_spent", "peak_concurrent_builds"]:
			if entry["construction"].get(key, null) == null:
				blank_construction += 1
		var built: Dictionary = entry["construction"]
		if int(built.get("build_started", 0)) != int(built.get("total_built", 0)) \
				+ int(built.get("build_cancelled", 0)):
			inconsistent += 1
	_check(stats_missing == 0, "每场 Demo 都有完整的 11 项单位统计（缺项 %d 场）" % stats_missing)
	_check(blank_stats == 0, "Demo 的 11 项单位统计全部有值（空缺 %d）" % blank_stats)
	_check(mismatch == 0, "单位统计与逐类型明细表同源（重新推导不一致 %d 场）" % mismatch)
	_check(blank_peak == 0, "Demo 每场都有峰值军力")
	_check(blank_construction == 0, "Demo 建设统计新增 6 项全部有值（空缺 %d）" % blank_construction)
	_check(inconsistent == 0, "建造「开工 = 落成 + 取消」自洽（矛盾 %d 场）" % inconsistent)


## 模板叶子数：`@list` 记 1 个叶子，字典递归，其余记 1。只用于覆盖度审计。
func _count_variant_leaves(node: Variant) -> int:
	if node is String and str(node) == "@list":
		return 1
	if node is Dictionary:
		var total := 0
		for key in (node as Dictionary):
			total += _count_variant_leaves((node as Dictionary)[key])
		return total
	return 1
