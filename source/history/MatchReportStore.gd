extends Node

## 历史对局报告的本地持久化与查询（autoload `MatchReportStore`）。
##
## 为什么另开一份文件而不是复用 `user://match_reports.json`：
## 那份是 GrowthStore 的**画像输入缓存**（极简摘要，给 Hermes 画像算分用）。
## 详细报告字段多、结构深、还要保留 Hermes 分析状态与生成时间，混在一起会让
## "缓存被谁覆写"变成常驻故障。因此：
##   `user://match_history.json`      ← 详细报告（本 store，唯一权威）
##   `user://match_reports.json`      ← 由本 store 投影出的摘要，供 GrowthStore/画像消费
## 两边只通过 `sync_growth_store()` 单向流动，绝不双向回写。

const SAVE_PATH := "user://match_history.json"
const LEGACY_PATH := "user://match_reports.json"
const MAX_REPORTS := 200
## 旧版 GrowthStore 里的占位 Demo（已被本系统的 Demo 数据取代）。迁移时跳过，
## 否则列表里会出现两套 Demo。注意：这是**明确的占位 id 名单**，不是"猜"。
const PLACEHOLDER_LEGACY_IDS := ["demo-001", "demo-002", "demo-003", "demo-004"]

signal reports_changed

var reports: Array = []
## 可覆盖的存储路径：测试/探针必须能把数据写进临时文件，绝不污染玩家真实档案。
var save_path := SAVE_PATH
var legacy_path := LEGACY_PATH
## 最近一次加载的体检结果，UI 的"数据来源"行直接读它。
var last_load: Dictionary = {
	"ok": true, "source": "none", "migrated": 0, "skipped_placeholder": 0,
	"seeded_demo": 0, "dropped": 0, "errors": [],
}


## 把存储路径改到临时文件（测试/探针专用），并立即重新加载。
func configure_paths(next_save: String, next_legacy: String) -> void:
	save_path = next_save
	legacy_path = next_legacy
	load_all()


func _ready() -> void:
	load_all()


## 挂上真实对局的记录钩子。**默认关闭**（`FeatureFlags.record_match_history`）：
## 对局层目前还没有 difficulty / 副官类型 / 权威伤害数字，打开后生成的是
## "诚实的稀疏报告"（缺失字段为 null、完整度很低）。等玩法系统愿意用
## `MatchReportRecorder.contribute()` 推进权威数字之后再默认打开。
##
## 用 `flags.get("...")` 而不是直接写属性名：老版本 tscn 里没有这个字段时
## 也能安全降级成关闭，而不是脚本加载失败。
func _install_match_hook() -> void:
	var flags := get_node_or_null("/root/FeatureFlags")
	if flags == null or not bool(flags.get("record_match_history")):
		return
	var hook: Node = MatchHistoryHook.new()
	hook.name = "MatchHistoryHook"
	add_child(hook)


# ==================== 加载 / 保存 ====================

## 读取本地报告。首次运行时播种 Demo 数据，并迁移旧版对局档案。
func load_all() -> Dictionary:
	var result := {
		"ok": true, "source": "none", "migrated": 0, "skipped_placeholder": 0,
		"seeded_demo": 0, "dropped": 0, "errors": [],
	}
	var errors: Array = []
	if FileAccess.file_exists(save_path):
		var parsed = _read_json(save_path, errors)
		var raw: Array = []
		if parsed is Array:
			raw = parsed
		elif parsed is Dictionary and parsed.get("reports", null) is Array:
			raw = parsed["reports"]
		elif parsed != null:
			errors.append("报告文件结构异常（既不是数组也没有 reports 字段），已按空列表处理")
		reports = _sanitize(raw, result)
		result["source"] = "local"
	else:
		# 首次运行：先迁移旧版真实档案，再补足 Demo 数据。
		reports = _migrate_legacy(result)
		result["source"] = "fresh" if reports.is_empty() else "legacy"
		var demo := DemoMatchReports.build()
		var existing := {}
		for report in reports:
			existing[str((report as Dictionary).get("report_id", ""))] = true
		for report in demo:
			if not existing.has(str((report as Dictionary).get("report_id", ""))):
				reports.append(report)
				result["seeded_demo"] = int(result["seeded_demo"]) + 1
		save()
	result["errors"] = errors
	last_load = result
	reports_changed.emit()
	return result


func save() -> bool:
	var payload := {
		"schema_version": MatchReportSchema.SCHEMA_VERSION,
		"saved_at": Time.get_datetime_string_from_system(),
		"reports": reports,
	}
	var file := FileAccess.open(save_path, FileAccess.WRITE)
	if file == null:
		push_warning("无法写入历史对局报告：%s" % save_path)
		return false
	file.store_string(JSON.stringify(payload, "  "))
	return true


# ==================== 写入 ====================

## 写入或更新一条报告。**去重是这里负责的**，调用方不需要自己判重。
## 返回 {"ok", "action": "inserted"|"replaced", "reason"}
func upsert(raw_report: Dictionary) -> Dictionary:
	var normalized: Dictionary = MatchReportSchema.normalize(raw_report)["report"]
	var report_id := str(normalized.get("report_id", ""))
	if report_id.is_empty():
		return {"ok": false, "action": "rejected", "reason": "报告缺少 report_id"}
	normalized["performance_score"] = MatchReportScoring.evaluate(normalized)
	normalized["overview"]["score"] = normalized["performance_score"]["total"]
	normalized = MatchReportSchema.normalize(normalized)["report"]
	var duplicate_index := _find_duplicate(normalized)
	if duplicate_index < 0:
		reports.append(normalized)
		_trim()
		save()
		reports_changed.emit()
		return {"ok": true, "action": "inserted", "reason": ""}
	# 同一局被重复上报：保留信息更完整的那一份，并在结果里说明，避免"统计翻倍"。
	var existing: Dictionary = reports[duplicate_index]
	var keep_new := _richness(normalized) >= _richness(existing)
	if keep_new:
		reports[duplicate_index] = normalized
		save()
		reports_changed.emit()
	return {
		"ok": true,
		"action": "replaced" if keep_new else "kept_existing",
		"reason": "检测到同一局（match_id=%s）重复上报，按数据完整度择优保留"
			% str(normalized.get("match_id", "")),
	}


func remove(report_id: String) -> bool:
	for index in range(reports.size()):
		if str((reports[index] as Dictionary).get("report_id", "")) == report_id:
			reports.remove_at(index)
			save()
			reports_changed.emit()
			return true
	return false


## 清除全部 Demo 数据（用户要求"演示数据必须明确标记"，同时也要能一键清干净）。
func purge_demo() -> int:
	var kept: Array = []
	var removed := 0
	for report in reports:
		if bool((report as Dictionary).get("demo", false)):
			removed += 1
			continue
		kept.append(report)
	if removed > 0:
		reports = kept
		save()
		reports_changed.emit()
	return removed


## 清空全部报告（含真实档案）。调用方必须自己先做确认。
func clear_all() -> void:
	reports = []
	save()
	reports_changed.emit()


func seed_demo(force: bool = false) -> int:
	if not force:
		for report in reports:
			if bool((report as Dictionary).get("demo", false)):
				return 0
	var existing := {}
	for report in reports:
		existing[str((report as Dictionary).get("report_id", ""))] = true
	var added := 0
	for report in DemoMatchReports.build():
		if not existing.has(str((report as Dictionary).get("report_id", ""))):
			reports.append(report)
			added += 1
	if added > 0:
		_trim()
		save()
		reports_changed.emit()
	return added


# ==================== 查询 ====================

## 按条件筛选 + 排序。filters 见 `MatchReportSchema.matches_filter`，
## 另支持 `sort` ∈ {date_desc, date_asc, score_desc, duration_desc}。
func query(filters: Dictionary = {}) -> Array:
	var out: Array = []
	for report in reports:
		if report is Dictionary and MatchReportSchema.matches_filter(report, filters):
			out.append(report)
	var sort_key := str(filters.get("sort", "date_desc"))
	out.sort_custom(func(a, b): return MatchReportSchema.compare(a, b, sort_key))
	return out


func get_report(report_id: String) -> Dictionary:
	for report in reports:
		if report is Dictionary and str((report as Dictionary).get("report_id", "")) == report_id:
			return (report as Dictionary).duplicate(true)
	return {}


## 下拉筛选项（只列真实出现过的值，不预先编造选项）。
func facets() -> Dictionary:
	var maps := {}
	var modes := {}
	var adjutants := {}
	var difficulties := {}
	var outcomes := {}
	for report in reports:
		var entry: Dictionary = report
		var map_name := _filter_key((entry.get("map", {}) as Dictionary).get("name", null)) \
			if entry.get("map", {}) is Dictionary else ""
		if not map_name.is_empty():
			maps[map_name] = true
		var mode := _filter_key(entry.get("mode", null))
		if not mode.is_empty():
			modes[MatchReportSchema.mode_label(mode)] = mode
		# Dictionary.get() 返回 Variant，这里必须显式标注类型：
		# 本工程把 "从 Variant 推断类型" 的告警当成错误。
		var adjutant: Variant = entry.get("adjutant", {})
		if adjutant is Dictionary:
			var kind := str((adjutant as Dictionary).get("type", ""))
			if not kind.is_empty():
				adjutants[kind] = kind
		var difficulty := _filter_key(entry.get("difficulty", null))
		if not difficulty.is_empty():
			difficulties[MatchReportSchema.difficulty_label(difficulty)] = difficulty
		var outcome_key := _filter_key(entry.get("outcome", null))
		if not outcome_key.is_empty():
			outcomes[outcome_key] = true
	var map_list: Array = maps.keys()
	map_list.sort()
	var mode_list: Array = modes.keys()
	mode_list.sort()
	var adjutant_list: Array = adjutants.keys()
	adjutant_list.sort()
	var difficulty_list: Array = difficulties.keys()
	difficulty_list.sort()
	return {
		"maps": map_list,
		"modes": mode_list,
		"adjutants": adjutant_list,
		"difficulties": difficulty_list,
		"outcomes": outcomes.keys(),
	}


## 汇总统计（列表页顶部那行数字）。
func stats() -> Dictionary:
	var summary := {
		"total": reports.size(), "demo": 0, "real": 0, "analyzed": 0,
		"victory": 0, "defeat": 0, "aborted": 0, "unknown": 0,
	}
	for report in reports:
		var entry: Dictionary = report
		if bool(entry.get("demo", false)):
			summary["demo"] = int(summary["demo"]) + 1
		else:
			summary["real"] = int(summary["real"]) + 1
		if MatchReportSchema.is_analyzed(entry):
			summary["analyzed"] = int(summary["analyzed"]) + 1
		var outcome := str(entry.get("outcome", "unknown"))
		if summary.has(outcome):
			summary[outcome] = int(summary[outcome]) + 1
		else:
			summary["unknown"] = int(summary["unknown"]) + 1
	return summary


# ==================== 与画像 / Hermes 的桥 ====================

## 投影成 GrowthStore / MatchReportAdapter 消费的摘要数组。
func profile_summaries() -> Array:
	var out: Array = []
	for report in reports:
		out.append(MatchReportSchema.profile_summary(report))
	return out


## 把摘要同步进 GrowthStore，触发画像快照重算。
## 这是"玩家画像读取多场 MatchReport"的唯一入口；详细报告仍是唯一权威数据源。
func sync_growth_store() -> Dictionary:
	# 用节点路径而不是 autoload 全局名取 GrowthStore：本函数可能在测试场景里被
	# 单独驱动，节点路径查找不会因为脚本被独立实例化而炸掉。
	var growth := get_node_or_null("/root/GrowthStore")
	if growth == null:
		return {}
	return growth.ingest_match_reports(profile_summaries())


## 供 Hermes 读取的第 N 份报告（含结构化字段与自然语言分析分区）。
func read_for_hermes(report_id: String) -> Dictionary:
	var report := get_report(report_id)
	if report.is_empty():
		return {}
	return {
		"report_id": str(report.get("report_id", "")),
		"facts": {
			"outcome": report.get("outcome"),
			"duration_seconds": report.get("duration_seconds"),
			"map": report.get("map"),
			"mode": report.get("mode"),
			"difficulty": report.get("difficulty"),
			"adjutant": report.get("adjutant"),
			"overview": report.get("overview"),
			"economy": report.get("economy"),
			"production": report.get("production"),
			"construction": report.get("construction"),
			"combat": report.get("combat"),
			"timeline": report.get("timeline"),
		},
		"performance_score": report.get("performance_score"),
		"data_completeness": report.get("data_completeness"),
		"previous_analysis": report.get("hermes_analysis"),
	}


# ==================== 内部实现 ====================

func _read_json(path: String, errors: Array) -> Variant:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		errors.append("无法读取 %s" % path)
		return null
	var text := file.get_as_text()
	if text.strip_edges().is_empty():
		errors.append("%s 为空文件" % path)
		return null
	var parsed = JSON.parse_string(text)
	if parsed == null:
		errors.append("%s 不是合法 JSON（旧版本/半写文件），已按空列表处理，原文件未改动" % path)
		return null
	return parsed


## 逐条归一化，坏条目丢弃但记录数量，绝不让一条坏数据拖垮整页。
func _sanitize(raw: Array, result: Dictionary) -> Array:
	var out: Array = []
	var seen := {}
	var dropped := 0
	for item in raw:
		if not (item is Dictionary):
			dropped += 1
			continue
		var normalized: Dictionary = MatchReportSchema.normalize(item)["report"]
		var report_id := str(normalized.get("report_id", ""))
		if report_id.is_empty():
			dropped += 1
			continue
		if seen.has(report_id):
			# 同 id 重复：保留信息更完整的一份（防止历史 bug 造成的重复统计）。
			var previous_index := int(seen[report_id])
			if _richness(normalized) > _richness(out[previous_index] as Dictionary):
				out[previous_index] = normalized
			dropped += 1
			continue
		seen[report_id] = out.size()
		out.append(normalized)
	result["dropped"] = dropped
	return out


func _migrate_legacy(result: Dictionary) -> Array:
	if not FileAccess.file_exists(legacy_path):
		return []
	var errors: Array = []
	var parsed = _read_json(legacy_path, errors)
	for error in errors:
		(result["errors"] as Array).append(error)
	if not (parsed is Array):
		return []
	var out: Array = []
	for index in range((parsed as Array).size()):
		var item = (parsed as Array)[index]
		if not (item is Dictionary):
			continue
		var match_id := str((item as Dictionary).get("match_id", ""))
		if PLACEHOLDER_LEGACY_IDS.has(match_id):
			result["skipped_placeholder"] = int(result["skipped_placeholder"]) + 1
			continue
		out.append(MatchReportSchema.migrate_legacy(item as Dictionary, index + 1))
		result["migrated"] = int(result["migrated"]) + 1
	return out


## 重复判定：report_id 相同，或"同一玩家同一 match_id"。
func _find_duplicate(report: Dictionary) -> int:
	var report_id := str(report.get("report_id", ""))
	var match_id := str(report.get("match_id", ""))
	var player_id := str(report.get("player_id", ""))
	for index in range(reports.size()):
		var existing: Dictionary = reports[index]
		if str(existing.get("report_id", "")) == report_id:
			return index
		if match_id.is_empty():
			continue
		if str(existing.get("match_id", "")) == match_id \
				and str(existing.get("player_id", "")) == player_id:
			return index
	return -1


## 信息量代理指标：完整度优先，其次非空字段数。用于同样本的择优保留。
func _richness(report: Dictionary) -> float:
	var completeness = report.get("data_completeness", {})
	var ratio := 0.0
	if completeness is Dictionary:
		ratio = float((completeness as Dictionary).get("ratio", 0.0))
	return ratio * 1000.0 + float(_non_null_count(report))


func _non_null_count(value: Variant) -> int:
	if value == null:
		return 0
	if value is Dictionary:
		var count := 0
		for key in (value as Dictionary):
			count += _non_null_count((value as Dictionary)[key])
		return count
	if value is Array:
		var count := 0
		for item in (value as Array):
			count += _non_null_count(item)
		return count
	return 1


func _trim() -> void:
	if reports.size() <= MAX_REPORTS:
		return
	reports.sort_custom(func(a, b):
		return MatchReportSchema.compare(a, b, "date_desc"))
	while reports.size() > MAX_REPORTS:
		reports.pop_back()


## 从字段里取"可筛选的字符串"。null 与 "unknown" 一律视为"没有这个值"：
## 直接用 `str(null)` 会得到字面量 "<null>"，在筛选项里就是一条垃圾选项；
## "unknown" 是"明确未知"，不是可筛选的分类。
func _filter_key(value: Variant) -> String:
	if value == null:
		return ""
	var text := str(value)
	return "" if text == "unknown" else text
