class_name MatchReportSchema
extends RefCounted

## 详细历史对局报告（MatchReport）的结构化契约。
##
## 三条铁律（用户 2026-09-14 明确要求）：
## 1. **缺数据就写 null，绝不编造**。所有叶子字段在 `normalize()` 里被显式标注为
##    "缺失"，并由 `completeness()` 汇总成数据完整度；UI 端遇到 null 一律渲染 "—"。
## 2. **Hermes 的自然语言只能待在 `hermes_analysis.observations` / `.suggestions`**，
##    且每条都必须带 `evidence` 字段追溯到本报告内的具体数据路径。
##    任何会影响 UI / 匹配 / 未来推荐的字段（`performance_score`、`profile_updates`、
##    `memory_delta`、`adjutant_impact`…）必须是结构化的，不得是自然语言。
## 3. **版本可演进**。`normalize()` 接受任何 `schema_version <= SCHEMA_VERSION` 的输入：
##    低版本按新增字段全部缺失处理，高版本保留未知字段（前向兼容，不丢数据）。

const SCHEMA_VERSION := 2
const MIN_SUPPORTED_VERSION := 1

const OUTCOMES := ["victory", "defeat", "aborted", "unknown"]
const OUTCOME_LABEL := {
	"victory": "胜利",
	"defeat": "失败",
	"aborted": "中止",
	"unknown": "未知",
}

const MODES := ["custom", "online", "skirmish", "campaign", "unknown"]
const MODE_LABEL := {
	"custom": "自定义对局",
	"online": "在线匹配",
	"skirmish": "遭遇战",
	"campaign": "战役",
	"unknown": "未知",
}

const DIFFICULTIES := ["easy", "normal", "hard", "brutal", "unknown"]
const DIFFICULTY_LABEL := {
	"easy": "简单",
	"normal": "普通",
	"hard": "困难",
	"brutal": "残酷",
	"unknown": "未知",
}

## Hermes 分析状态。`cached` 表示 Hermes 不可用、展示的是最近一次缓存结果。
const HERMES_STATUSES := ["completed", "running", "failed", "cached", "none"]
const HERMES_STATUS_LABEL := {
	"completed": "已完成",
	"running": "分析中",
	"failed": "分析失败",
	"cached": "使用缓存",
	"none": "尚未分析",
}

## 评分维度（顺序即 UI 展示顺序）。
const SCORE_DIMENSIONS := ["combat", "economy", "construction", "operations", "risk", "objectives"]
const SCORE_DIMENSION_LABEL := {
	"combat": "战斗表现",
	"economy": "经济表现",
	"construction": "建设表现",
	"operations": "运营表现",
	"risk": "风险控制",
	"objectives": "目标完成度",
}
## 总分权重（归一化后使用；缺维度时按可用维度重新配权并标记 partial）。
const SCORE_WEIGHTS := {
	"combat": 0.26,
	"economy": 0.20,
	"construction": 0.16,
	"operations": 0.16,
	"risk": 0.12,
	"objectives": 0.10,
}

## 时间线事件类型 → 中文标签 / 强调色 / 分组（筛选按钮按分组生成）。
const TIMELINE_TYPES := {
	"match_start": {"label": "游戏开始", "color": "26c9e8", "group": "开局"},
	"match_aborted": {"label": "对局中止", "color": "e05b47", "group": "结算"},
	"first_resource_node": {"label": "首个资源点", "color": "38c9ee", "group": "经济"},
	"first_unit_produced": {"label": "首个单位生产", "color": "38c9ee", "group": "生产"},
	"first_structure_built": {"label": "首个建筑建成", "color": "49c99b", "group": "建设"},
	"first_scout": {"label": "首次侦察", "color": "8ea7ad", "group": "侦察"},
	"first_contact": {"label": "首次接敌", "color": "e4a452", "group": "战斗"},
	"first_attack": {"label": "首次攻击", "color": "e4a452", "group": "战斗"},
	"first_defense": {"label": "首次防守", "color": "e4a452", "group": "战斗"},
	"first_expansion": {"label": "首次扩张", "color": "49c99b", "group": "建设"},
	"resource_drought": {"label": "资源断档", "color": "e05b47", "group": "经济"},
	"tech_unlocked": {"label": "科技解锁", "color": "26c9e8", "group": "科技"},
	"hermes_advice": {"label": "Hermes 建议", "color": "f3c77b", "group": "Hermes"},
	"hermes_advice_adopted": {"label": "建议被采纳", "color": "49c99b", "group": "Hermes"},
	"hermes_advice_ignored": {"label": "建议被忽略", "color": "e05b47", "group": "Hermes"},
	"key_unit": {"label": "关键单位", "color": "38c9ee", "group": "生产"},
	"key_structure": {"label": "关键建筑", "color": "49c99b", "group": "建设"},
	"objective_completed": {"label": "目标完成", "color": "49c99b", "group": "目标"},
	"objective_failed": {"label": "目标失败", "color": "e05b47", "group": "目标"},
	"major_battle": {"label": "大规模战斗", "color": "e05b47", "group": "战斗"},
	"base_damaged": {"label": "基地受损", "color": "e05b47", "group": "战斗"},
	"base_destroyed": {"label": "基地被摧毁", "color": "e05b47", "group": "战斗"},
	"victory": {"label": "胜利", "color": "49c99b", "group": "结算"},
	"defeat": {"label": "失败", "color": "e05b47", "group": "结算"},
}

## 资源种类（与 C# EconomyRuntime 的 ResourceKind.A/B 一致）。
const RESOURCE_KEYS := ["resource_a", "resource_b"]
const RESOURCE_LABEL := {"resource_a": "资源 A（资金）", "resource_b": "资源 B（电力）"}

## ---------- 模板 ----------
## 叶子一律为 `null`（=需要真实数据）；`"@list"` 表示数组；
## 嵌套 Dictionary 表示子结构。缺失的叶子会被 `normalize()` 记入 missing 列表。
const TEMPLATE := {
	"schema_version": SCHEMA_VERSION,
	"report_id": null,
	"player_id": null,
	"created_at": null,
	"match_id": null,
	"match_version": null,
	"demo": false,
	"demo_seed": null,
	"migrated_from_legacy": false,
	"map": {"name": null, "path": null, "seed": null, "size": null, "players": null},
	"mode": null,
	"difficulty": null,
	"duration_seconds": null,
	"outcome": null,
	"victory_condition": null,
	"defeat_reason": null,
	"commander": null,
	"adjutant": {"type": null, "level": null},
	"growth_before": {
		"levels": null,
		"available_points": null,
		"earned_total": null,
		"spent_total": null,
	},
	"growth_after": {
		"levels": null,
		"available_points": null,
		"earned_total": null,
		"spent_total": null,
	},
	"growth_spent_this_match": null,
	"performance_score": {
		"total": null,
		"method": null,
		"partial": null,
		"breakdown": {
			"combat": {"score": null, "basis": null},
			"economy": {"score": null, "basis": null},
			"construction": {"score": null, "basis": null},
			"operations": {"score": null, "basis": null},
			"risk": {"score": null, "basis": null},
			"objectives": {"score": null, "basis": null},
		},
	},
	"data_completeness": {"ratio": null, "level": null, "present": null, "total": null, "missing": "@list"},
	"overview": {
		"final_resources": {"resource_a": null, "resource_b": null},
		"total_gathered": {"resource_a": null, "resource_b": null},
		"total_spent": {"resource_a": null, "resource_b": null},
		"resource_efficiency": null,
		"structures_built": null,
		"units_produced": null,
		"damage_dealt": null,
		"damage_taken": null,
		"units_lost": null,
		"enemies_killed": null,
		"objectives_completed": "@list",
		"objectives_failed": "@list",
		"key_events": "@list",
		"final_base_value": null,
		"final_controlled_zones": null,
		"peak_army_value": null,
		"score": null,
	},
	"economy": {
		"resources": "@list",
		"totals": {"gathered": null, "spent": null, "wasted": null, "remaining": null},
		"rates": {"gather_avg_per_min": null, "gather_peak_per_min": null, "spend_avg_per_min": null},
		"utilization": null,
		"conversion_efficiency": null,
		"source_breakdown": "@list",
		"sink_breakdown": "@list",
		"series": "@list",
		"structure": {
			"gatherers": "@list",
			"producers": "@list",
			"investment_ratio": {
				"construction": null,
				"military": null,
				"technology": null,
				"defense": null,
			},
			"conversion_routes": "@list",
			"dominant_resource": null,
			"peak_time_seconds": null,
			"drought_windows": "@list",
		},
	},
	"production": {
		"units": "@list",
		"queue": {
			"wait_avg_s": null,
			"idle_total_s": null,
			"cancellations": null,
			"utilization": null,
			"earliest_production_s": null,
			"latest_production_s": null,
			"first_main_force_s": null,
		},
		"composition": {
			"type_ratio": "@list",
			"weight_class": {"light": null, "medium": null, "heavy": null},
			"role_class": {"ranged": null, "melee": null, "air": null, "support": null},
			"scout_ratio": null,
			"main_force_ratio": null,
			"sacrificed_ratio": null,
		},
		"combos": {"most_used": "@list", "most_effective": "@list", "highest_loss": "@list"},
	},
	"construction": {
		"total_built": null,
		"buildings": "@list",
		"order": "@list",
		"destroyed_count": null,
		"survival_rate": null,
		"avg_lifetime_s": null,
		"frontline_count": null,
		"economy_count": null,
		"defense_count": null,
		"tech_count": null,
		"expansions": null,
		"first_expansion_s": null,
		"farthest_building_distance_m": null,
		"density_per_km2": null,
		"defense_line_integrity": null,
		"build_started": null,
		"build_cancelled": null,
		"avg_build_time_s": null,
		"rebuild_count": null,
		"repair_spent": null,
		"peak_concurrent_builds": null,
	},
	"combat": {
		"overview": {
			"engagements": null,
			"first_contact_s": null,
			"last_contact_s": null,
			"total_contact_s": null,
			"win_rate": null,
			"offensives": null,
			"defenses": null,
			"counterattacks": null,
			"ambushes": null,
			"retreats": null,
			"turning_point": null,
			"largest_engagement": null,
			"most_important": null,
		},
		"damage": {
			"dealt": null,
			"taken": null,
			"to_structures": null,
			"to_units": null,
			"to_heroes": null,
			"physical": null,
			"energy": null,
			"explosive": null,
			"friendly_fire": null,
			"per_minute": null,
			"exchange_ratio": null,
		},
		"units": "@list",
		## 单位统计 11 项：`combat.units` 是**逐类型明细表**，这里是全局汇总口径的 11 个标量，
		## 与「伤害统计 11 项 / 战斗质量 13 项」同级。缺数据一律 null，不用 0 冒充。
		"unit_stats": {
			"produced": null,
			"lost": null,
			"alive": null,
			"survival_rate": null,
			"kills": null,
			"kill_loss_ratio": null,
			"damage_per_unit": null,
			"damage_taken_per_unit": null,
			"avg_lifetime_s": null,
			"unique_types": null,
			"scout_units": null,
		},
		"quality": {
			"focus_fire": null,
			"formation_time_s": null,
			"idle_time_s": null,
			"moving_time_s": null,
			"engagement_distance_m": null,
			"recon_coverage": null,
			"reaction_time_s": null,
			"target_selection": null,
			"retreat_timing": null,
			"abilities_used": null,
			"ability_hit_rate": null,
			"adjutant_contribution": null,
			"resource_drought_in_combat": null,
		},
		"mvp_unit": null,
		"worst_loss_unit": null,
		"most_efficient_kill_unit": null,
		"least_efficient_unit": null,
	},
	"timeline": "@list",
	"hermes_analysis": {
		"status": null,
		"generated_at": null,
		"model_version": null,
		"source_report_ids": "@list",
		"cache": {"cached_at": null, "stale": null, "source_generated_at": null},
		"observations": "@list",
		"suggestions": "@list",
		"memory_delta": "@list",
		"profile_updates": "@list",
		"adjutant_impact": {"type": null, "score": null, "recommendation_signal": null, "basis": null},
		"data_basis": "@list",
		"failure_reason": null,
	},
	"source": {"generated_by": null, "generated_at": null, "game_version": null},
}

## 数组元素模板（按完整点路径索引）。值为 null 表示"元素是标量，原样保留"。
const LIST_RECORDS := {
	"data_completeness.missing": null,
	"overview.objectives_completed": {"id": null, "title": null, "completed_at_s": null, "note": null},
	"overview.objectives_failed": {"id": null, "title": null, "failed_at_s": null, "reason": null},
	"overview.key_events": {"t": null, "title": null, "detail": null},
	"economy.resources": {
		"key": null, "label": null, "initial": null, "gathered": null, "spent": null,
		"wasted": null, "remaining": null, "gather_avg_per_min": null,
		"gather_peak_per_min": null, "utilization": null,
	},
	"economy.source_breakdown": {"key": null, "label": null, "amount": null, "share": null},
	"economy.sink_breakdown": {"key": null, "label": null, "amount": null, "share": null},
	"economy.series": {
		"t": null, "stock": null, "gathered_cum": null, "spent_cum": null,
		"gather_rate": null, "spend_rate": null, "event": null,
	},
	"economy.structure.gatherers": {"t": null, "count": null},
	"economy.structure.producers": {"t": null, "count": null},
	"economy.structure.conversion_routes": {"from": null, "to": null, "amount": null, "share": null},
	"economy.structure.drought_windows": {"start_s": null, "end_s": null, "cause": null},
	"production.units": {
		"id": null, "label": null, "category": null, "weight_class": null, "role_class": null,
		"produced": null, "batches": null, "avg_interval_s": null, "resource_cost": null,
		"killed": null, "lost": null, "damage_dealt": null, "damage_taken": null,
		"avg_lifetime_s": null, "first_seen_s": null, "last_alive_s": null,
	},
	"production.composition.type_ratio": {"key": null, "label": null, "count": null, "share": null},
	"production.combos.most_used": {"units": "@list", "count": null, "win_rate": null},
	"production.combos.most_effective": {"units": "@list", "count": null, "win_rate": null},
	"production.combos.highest_loss": {"units": "@list", "count": null, "win_rate": null},
	"production.combos.most_used.units": null,
	"production.combos.most_effective.units": null,
	"production.combos.highest_loss.units": null,
	"construction.buildings": {
		"id": null, "label": null, "role": null, "count": null, "cost": null,
		"first_built_s": null, "destroyed": null, "survival_rate": null, "avg_lifetime_s": null,
	},
	"construction.order": {"t": null, "building": null, "position": null, "cost": null, "note": null},
	"combat.units": {
		"id": null, "label": null, "produced": null, "alive": null, "killed": null, "lost": null,
		"damage_dealt": null, "damage_taken": null, "avg_lifetime_s": null,
		"first_seen_s": null, "last_alive_s": null,
	},
	"timeline": {
		"t": null, "type": null, "title": null, "detail": null, "subject": null,
		"resources_delta": null, "combat_impact": null, "hermes_tagged": null,
	},
	"hermes_analysis.source_report_ids": null,
	"hermes_analysis.data_basis": null,
	"hermes_analysis.observations": {"text": null, "evidence": "@list"},
	"hermes_analysis.suggestions": {"text": null, "evidence": "@list", "adopted": null, "outcome": null},
	"hermes_analysis.memory_delta": {"key": null, "label": null, "value": null, "source": null},
	"hermes_analysis.profile_updates": {"dimension": null, "before": null, "after": null, "basis": null},
	"hermes_analysis.observations.evidence": null,
	"hermes_analysis.suggestions.evidence": null,
}

## 完整度统计时跳过的子树（自身是元数据或由完整度反推，参与计算会自引用）。
const COMPLETENESS_SKIP := ["schema_version", "data_completeness", "source"]


# ==================== 公开 API ====================

## 生成一份全字段为空的报告骨架（用于"半途退出/数据不足"等场景）。
static func blank(overrides: Dictionary = {}) -> Dictionary:
	var report: Dictionary = normalize({})["report"]
	for key in overrides:
		report[key] = overrides[key]
	return report


## 把任意输入（旧版本 / 残缺 / 被别处改过的 JSON）归一化为当前版本结构。
## 返回：{"report": Dictionary, "missing": PackedStringArray,
##        "version_in": int, "version_out": int, "errors": PackedStringArray}
static func normalize(raw: Variant) -> Dictionary:
	var value: Dictionary = raw if raw is Dictionary else {}
	var errors := PackedStringArray()
	if not (raw is Dictionary):
		errors.append("输入不是 Dictionary（实际 %s），已按空报告处理" % type_string(typeof(raw)))
	var version_in := int(value.get("schema_version", 0))
	if version_in > SCHEMA_VERSION:
		errors.append("报告版本 %d 高于当前支持的 %d：未知字段原样保留，新字段按缺失处理"
			% [version_in, SCHEMA_VERSION])
	var missing := PackedStringArray()
	var report: Dictionary = _fill(value, TEMPLATE, "", missing)
	# 未知字段（前向兼容）原样保留，绝不丢数据。
	for key in value:
		if not report.has(key):
			report[key] = value[key]
	report["schema_version"] = SCHEMA_VERSION
	if version_in > 0 and version_in < SCHEMA_VERSION:
		report["upgraded_from"] = version_in
	var completeness := _compute_completeness(missing)
	report["data_completeness"] = {
		"ratio": completeness["ratio"],
		"level": completeness["level"],
		"present": completeness["present"],
		"total": completeness["total"],
		"missing": Array(missing),
	}
	return {
		"report": report,
		"missing": missing,
		"version_in": version_in,
		"version_out": SCHEMA_VERSION,
		"errors": errors,
	}


## 结构校验。返回 [{level, path, message}]，level ∈ {error, warning}。
## 只检查"报告自身是否自洽"，不判断好坏。
static func validate(report: Dictionary) -> Array:
	var issues: Array = []
	if not report.get("report_id", null) is String or str(report.get("report_id", "")).is_empty():
		issues.append(_issue("error", "report_id", "缺少 report_id：报告无法被去重或追溯"))
	var outcome := str(report.get("outcome", ""))
	if not OUTCOMES.has(outcome):
		issues.append(_issue("error", "outcome", "outcome 非法（%s），允许值：%s"
			% [outcome, ", ".join(OUTCOMES)]))
	var duration = report.get("duration_seconds", null)
	if duration != null and float(duration) < 0.0:
		issues.append(_issue("error", "duration_seconds", "对局时长不能为负"))
	if duration == null:
		issues.append(_issue("warning", "duration_seconds", "缺少对局时长：每分钟速率类指标不可计算"))
	var map_data: Dictionary = report.get("map", {}) if report.get("map", {}) is Dictionary else {}
	var map_name: Variant = map_data.get("name", null)
	if (map_name == null or str(map_name).is_empty()) and map_data.get("seed", null) == null:
		issues.append(_issue("warning", "map", "缺少地图名与种子"))
	if bool(report.get("demo", false)) and report.get("demo_seed", null) == null:
		issues.append(_issue("warning", "demo_seed", "Demo 数据必须带 demo_seed 以便复现"))

	# 交叉一致性：总览数字与分区明细必须同源，否则 UI 上会出现两套数字。
	var overview: Dictionary = report.get("overview", {}) if report.get("overview", {}) is Dictionary else {}
	var combat: Dictionary = report.get("combat", {}) if report.get("combat", {}) is Dictionary else {}
	var damage: Dictionary = combat.get("damage", {}) if combat.get("damage", {}) is Dictionary else {}
	issues.append_array(_cross_check(overview, "damage_dealt", damage, "dealt", "总览/战斗伤害"))
	issues.append_array(_cross_check(overview, "damage_taken", damage, "taken", "总览/战斗承伤"))
	var econ: Dictionary = report.get("economy", {}) if report.get("economy", {}) is Dictionary else {}
	var totals: Dictionary = econ.get("totals", {}) if econ.get("totals", {}) is Dictionary else {}
	issues.append_array(_cross_check(overview, "total_gathered", totals, "gathered", "总览/经济采集"))
	issues.append_array(_cross_check(overview, "total_spent", totals, "spent", "总览/经济消耗"))

	# Hermes：自然语言必须带证据；状态必须合法。
	var hermes: Dictionary = report.get("hermes_analysis", {}) if report.get("hermes_analysis", {}) is Dictionary else {}
	var status := str(hermes.get("status", "none"))
	if not HERMES_STATUSES.has(status):
		issues.append(_issue("error", "hermes_analysis.status", "Hermes 状态非法：%s" % status))
	for section in ["observations", "suggestions"]:
		var items = hermes.get(section, [])
		if not (items is Array):
			issues.append(_issue("error", "hermes_analysis.%s" % section, "必须是数组"))
			continue
		for index in range(items.size()):
			var item: Dictionary = items[index] if items[index] is Dictionary else {}
			if str(item.get("text", "")).is_empty():
				issues.append(_issue("warning", "hermes_analysis.%s[%d].text" % [section, index], "分析文本为空"))
			var evidence = item.get("evidence", [])
			if not (evidence is Array) or (evidence as Array).is_empty():
				issues.append(_issue("error", "hermes_analysis.%s[%d].evidence" % [section, index],
					"Hermes 结论必须能追溯到具体对局数据（evidence 不能为空）"))
	if status == "cached" and hermes.get("cache", {}) is Dictionary:
		var cache: Dictionary = hermes.get("cache", {})
		if cache.get("cached_at", null) == null:
			issues.append(_issue("error", "hermes_analysis.cache.cached_at",
				"缓存状态必须给出缓存生成时间，否则玩家无法判断结论时效"))
	return issues


## 业务查询：按条件筛选 + 排序。filters 支持
## {outcome, map, mode, adjutant, difficulty, search, only_demo, only_analyzed, sort}
static func matches_filter(report: Dictionary, filters: Dictionary) -> bool:
	var outcome := str(filters.get("outcome", ""))
	if outcome != "" and outcome != "all" and str(report.get("outcome", "")) != outcome:
		return false
	var map_filter := str(filters.get("map", ""))
	if map_filter != "" and map_filter != "all" and str(_map_name(report)) != map_filter:
		return false
	var mode := str(filters.get("mode", ""))
	if mode != "" and mode != "all" and str(report.get("mode", "")) != mode:
		return false
	var adjutant := str(filters.get("adjutant", ""))
	if adjutant != "" and adjutant != "all" and str(_adjutant_type(report)) != adjutant:
		return false
	var difficulty := str(filters.get("difficulty", ""))
	if difficulty != "" and difficulty != "all" and str(report.get("difficulty", "")) != difficulty:
		return false
	if bool(filters.get("only_demo", false)) and not bool(report.get("demo", false)):
		return false
	if bool(filters.get("only_analyzed", false)) and not is_analyzed(report):
		return false
	var needle := str(filters.get("search", "")).strip_edges().to_lower()
	if not needle.is_empty():
		var haystack := "%s\n%s\n%s" % [
			str(report.get("report_id", "")), str(report.get("match_id", "")), str(_map_name(report)),
		]
		if not haystack.to_lower().contains(needle):
			return false
	return true


## 排序键比较。sort ∈ {date_desc, date_asc, score_desc, duration_desc}
static func compare(a: Dictionary, b: Dictionary, sort: String) -> bool:
	match sort:
		"date_asc":
			return str(a.get("created_at", "")) < str(b.get("created_at", ""))
		"score_desc":
			return _score_of(a) > _score_of(b)
		"duration_desc":
			return float(a.get("duration_seconds", 0.0)) > float(b.get("duration_seconds", 0.0))
		_:
			return str(a.get("created_at", "")) > str(b.get("created_at", ""))


## 是否已被 Hermes 分析过（有完成的分析、或明确给出缓存态）。
static func is_analyzed(report: Dictionary) -> bool:
	var hermes = report.get("hermes_analysis", {})
	if not (hermes is Dictionary):
		return false
	return HERMES_STATUSES.has(str((hermes as Dictionary).get("status", "none"))) \
		and str((hermes as Dictionary).get("status", "none")) in ["completed", "cached", "running"]


## 把详细报告投影成 `GrowthStore` / `MatchReportAdapter` 消费的精简摘要。
## 这是"一套数据、两个消费者"的桥：详细页读原始报告，玩家画像读这个投影。
static func profile_summary(report: Dictionary) -> Dictionary:
	var overview: Dictionary = report.get("overview", {}) if report.get("overview", {}) is Dictionary else {}
	var economy: Dictionary = report.get("economy", {}) if report.get("economy", {}) is Dictionary else {}
	var totals: Dictionary = economy.get("totals", {}) if economy.get("totals", {}) is Dictionary else {}
	var production: Dictionary = report.get("production", {}) if report.get("production", {}) is Dictionary else {}
	var construction: Dictionary = report.get("construction", {}) if report.get("construction", {}) is Dictionary else {}
	var combat: Dictionary = report.get("combat", {}) if report.get("combat", {}) is Dictionary else {}
	var damage: Dictionary = combat.get("damage", {}) if combat.get("damage", {}) is Dictionary else {}
	var growth_after: Dictionary = report.get("growth_after", {}) if report.get("growth_after", {}) is Dictionary else {}
	var combo: Array = production.get("combos", {}).get("most_used", []) if production.get("combos", {}) is Dictionary else []
	var routes := PackedStringArray()
	for entry in combo:
		if entry is Dictionary and (entry as Dictionary).get("units", null) is Array:
			for unit in (entry as Dictionary).get("units", []):
				routes.append(str(unit))
	var key_events := PackedStringArray()
	for event in report.get("timeline", []):
		if event is Dictionary and bool((event as Dictionary).get("hermes_tagged", false)):
			key_events.append(str((event as Dictionary).get("title", "")))
	return {
		"match_id": str(report.get("report_id", report.get("match_id", ""))),
		"outcome": str(report.get("outcome", "unknown")),
		"resources": {
			"gathered": _sum_amounts(totals.get("gathered", null), overview.get("total_gathered", null)),
			"spent": _sum_amounts(totals.get("spent", null), overview.get("total_spent", null)),
		},
		"production": {
			"units": int(overview.get("units_produced", 0)) if overview.get("units_produced", null) != null else 0,
			"routes": Array(routes),
		},
		"construction": {
			"structures": int(overview.get("structures_built", 0)) if overview.get("structures_built", null) != null else 0,
			"value": _normalize_base_value(overview.get("final_base_value", null)),
		},
		"combat": {
			"damage_dealt": float(damage.get("dealt", 0.0)) if damage.get("dealt", null) != null else 0.0,
			"damage_taken": float(damage.get("taken", 0.0)) if damage.get("taken", null) != null else 0.0,
			"units_lost": int(overview.get("units_lost", 0)) if overview.get("units_lost", null) != null else 0,
		},
		"key_events": Array(key_events),
		"growth_levels": growth_after.get("levels", {}) if growth_after.get("levels", null) is Dictionary else {},
		"demo": bool(report.get("demo", false)),
		"score": _score_of(report),
	}


## 旧版（GrowthStore._seed_demo_profile 的极简结构）→ 当前版本。
## 只映射真实存在的字段，其余一律留空并在 missing 中体现，绝不"补"数据。
static func migrate_legacy(legacy: Dictionary, index: int = 0) -> Dictionary:
	if legacy.has("schema_version") or legacy.has("overview") or legacy.has("economy"):
		return normalize(legacy)["report"]
	var resources: Dictionary = legacy.get("resources", {}) if legacy.get("resources", {}) is Dictionary else {}
	var production: Dictionary = legacy.get("production", {}) if legacy.get("production", {}) is Dictionary else {}
	var construction: Dictionary = legacy.get("construction", {}) if legacy.get("construction", {}) is Dictionary else {}
	var combat: Dictionary = legacy.get("combat", {}) if legacy.get("combat", {}) is Dictionary else {}
	var match_id := str(legacy.get("match_id", "legacy-%d" % index))
	var gathered := float(resources.get("gathered", 0.0))
	var spent := float(resources.get("spent", 0.0))
	var routes: Array = production.get("routes", []) if production.get("routes", []) is Array else []
	var combo := PackedStringArray()
	for route in routes:
		combo.append(str(route))
	var legacy_events: Array = legacy.get("key_events", []) if legacy.get("key_events", []) is Array else []
	var key_events: Array = []
	for event in legacy_events:
		key_events.append({"t": null, "title": str(event), "detail": "由旧版对局档案迁移，时间戳缺失"})
	var source := {
		"report_id": "MR-LEGACY-%03d" % index,
		"player_id": "local_player_demo",
		"created_at": "",
		"match_id": match_id,
		"demo": false,
		"migrated_from_legacy": true,
		"outcome": str(legacy.get("outcome", "unknown")),
		"map": {"name": "", "seed": null},
		"mode": null,
		"difficulty": null,
		"adjutant": {"type": "", "level": null},
		"overview": {
			"total_gathered": {"resource_a": gathered, "resource_b": null},
			"total_spent": {"resource_a": spent, "resource_b": null},
			"units_produced": int(production.get("units", 0)),
			"structures_built": int(construction.get("structures", 0)),
			"final_base_value": float(construction.get("value", 0.0)),
			"damage_dealt": float(combat.get("damage_dealt", 0.0)),
			"damage_taken": float(combat.get("damage_taken", 0.0)),
			"units_lost": int(combat.get("units_lost", 0)),
			"key_events": key_events,
		},
		"economy": {
			"totals": {"gathered": gathered, "spent": spent},
		},
		"production": {"combos": {"most_used": [{"units": Array(combo), "count": null, "win_rate": null}]}},
		"combat": {
			"damage": {
				"dealt": float(combat.get("damage_dealt", 0.0)),
				"taken": float(combat.get("damage_taken", 0.0)),
			},
		},
		"growth_after": {"levels": legacy.get("growth_levels", {})},
		"growth_before": {"levels": {}},
		"timeline": [],
		"hermes_analysis": {"status": "none"},
	}
	return normalize(source)["report"]


## 生成一份"对局被中断"的保底报告（玩家中途退出/崩溃）。
## 明确标记 outcome=aborted，并记录已采集到的部分数据；不推断胜负。
static func aborted_report(partial: Dictionary, reason: String) -> Dictionary:
	var base := partial.duplicate(true)
	base["outcome"] = "aborted"
	base["defeat_reason"] = ""
	if base.get("victory_condition", null) == null:
		base["victory_condition"] = ""
	var note := {
		"t": base.get("duration_seconds", null),
		"type": "match_aborted",
		"title": "对局中止",
		"detail": reason,
		"subject": "",
		"resources_delta": null,
		"combat_impact": null,
		"hermes_tagged": false,
	}
	var timeline: Array = base.get("timeline", []) if base.get("timeline", []) is Array else []
	timeline.append(note)
	base["timeline"] = timeline
	return normalize(base)["report"]


# ==================== 展示辅助 ====================

## 标签函数对 null / 空串一律返回 "—"：这是"我们没有这个值"。
## 与 "unknown"（明确未知）在 UI 上必须能区分 —— 缺失不许被渲染成一个分类名。
static func _label_of(table: Dictionary, value: Variant) -> String:
	if value == null:
		return "—"
	var key := str(value)
	if key.is_empty():
		return "—"
	return str(table.get(key, table.get("unknown", "未知")))


static func outcome_label(outcome: Variant) -> String:
	return _label_of(OUTCOME_LABEL, outcome)


static func mode_label(mode: Variant) -> String:
	return _label_of(MODE_LABEL, mode)


static func difficulty_label(difficulty: Variant) -> String:
	return _label_of(DIFFICULTY_LABEL, difficulty)


static func hermes_status_label(status: String) -> String:
	return str(HERMES_STATUS_LABEL.get(status, HERMES_STATUS_LABEL["none"]))


static func timeline_label(type_key: String) -> String:
	var entry: Dictionary = TIMELINE_TYPES.get(type_key, {})
	return str(entry.get("label", type_key)) if not entry.is_empty() else "其它事件"


static func timeline_color(type_key: String) -> Color:
	var entry: Dictionary = TIMELINE_TYPES.get(type_key, {})
	return Color(str(entry.get("color", "8ea7ad"))) if not entry.is_empty() else Color("#8ea7ad")


static func duration_text(seconds: Variant) -> String:
	if seconds == null:
		return "—"
	var total := int(round(float(seconds)))
	if total < 0:
		return "—"
	return "%d:%02d" % [total / 60, total % 60]


static func number_text(value: Variant, decimals: int = 0) -> String:
	if value == null:
		return "—"
	if value is String:
		return value if not str(value).is_empty() else "—"
	if float(value) == 0.0 and decimals == 0:
		return "0"
	if decimals <= 0:
		return str(int(round(float(value))))
	return String.num(float(value), decimals)


static func percent_text(value: Variant, decimals: int = 0) -> String:
	if value == null:
		return "—"
	return "%s%%" % String.num(float(value) * 100.0, decimals)


static func dict_amount_text(value: Variant) -> String:
	if value == null:
		return "—"
	if value is float or value is int:
		return number_text(value)
	if not (value is Dictionary):
		return "—"
	var parts := PackedStringArray()
	for key in RESOURCE_KEYS:
		if (value as Dictionary).get(key, null) == null:
			continue
		parts.append("%s %s" % [str(RESOURCE_LABEL.get(key, key)).split("（")[0], number_text(value[key])])
	if parts.is_empty():
		return "—"
	return " / ".join(parts)


# ==================== 内部实现 ====================

static func _issue(level: String, path: String, message: String) -> Dictionary:
	return {"level": level, "path": path, "message": message}


static func _cross_check(a: Dictionary, a_key: String, b: Dictionary, b_key: String, label: String) -> Array:
	var left = a.get(a_key, null)
	var right = b.get(b_key, null)
	if left == null or right == null:
		return []
	var left_sum := _sum_amounts(left, null)
	var right_sum := _sum_amounts(right, null)
	if left_sum < 0.0 or right_sum < 0.0:
		return []
	if not is_equal_approx(left_sum, right_sum):
		return [_issue("error", "%s" % label,
			"总览与分区不一致（%s vs %s）：同一数字必须只有一个来源" % [
				String.num(left_sum, 1), String.num(right_sum, 1)])]
	return []


## 递归填充：缺失 → null 并记入 missing；多余 → 原样保留（前向兼容）。
static func _fill(value: Variant, declared: Variant, path: String, missing: PackedStringArray) -> Variant:
	if declared is String and declared == "@list":
		if not (value is Array):
			if value != null:
				missing.append(path)
			return []
		var out: Array = []
		var record_template: Variant = LIST_RECORDS.get(path, "") if LIST_RECORDS.has(path) else ""
		for element in (value as Array):
			if record_template == null:
				out.append(element)
			elif record_template is Dictionary:
				out.append(_fill(element, record_template, path, missing))
			else:
				out.append(element)
		return out
	if declared is Dictionary:
		var source: Dictionary = value if value is Dictionary else {}
		if value != null and not (value is Dictionary):
			missing.append(path)
		var out: Dictionary = {}
		for key in (declared as Dictionary):
			var child_path := "%s.%s" % [path, key] if not path.is_empty() else str(key)
			if not source.has(key):
				# 整棵子树缺失时，要把子树里**每一个叶子**都记进缺失清单：
				# 完整度是按叶子算的，只记父路径会算出虚高的完整度。
				out[key] = _empty_like(declared[key])
				_collect_missing(declared[key], child_path, missing)
				continue
			out[key] = _fill(source[key], declared[key], child_path, missing)
		return out
	# 标量叶子
	if value == null:
		# 模板里的非 null 常量（`false` / 版本号）是**默认值**，不是"缺失的数据"：
		# `demo: false` 表示"这不是 Demo 局"，是一个合法结论。
		if declared != null:
			return declared
		missing.append(path)
		return null
	return value


## 把一棵缺失子树的全部叶子路径写进 missing。
static func _collect_missing(declared: Variant, path: String, missing: PackedStringArray) -> void:
	if declared is Dictionary:
		for key in (declared as Dictionary):
			var child := "%s.%s" % [path, key] if not path.is_empty() else str(key)
			_collect_missing((declared as Dictionary)[key], child, missing)
		return
	if declared is String and declared == "@list":
		missing.append(path)
		return
	if declared == null:
		missing.append(path)
	# 其余（非 null 常量）有模板默认值，不计入缺失。


static func _empty_like(declared: Variant) -> Variant:
	if declared is Dictionary:
		var out: Dictionary = {}
		for key in (declared as Dictionary):
			out[key] = _empty_like(declared[key])
		return out
	if declared is String and declared == "@list":
		return []
	return declared


## 统计模板叶子（跳过元数据子树），返回完整度。
static func _compute_completeness(missing: PackedStringArray) -> Dictionary:
	var missing_set := {}
	for path in missing:
		missing_set[path] = true
	# GDScript 的 int 按值传递，递归里改不动；用单元素数组当可变累加器。
	var counter: Array = [0, 0]
	_count_leaves(TEMPLATE, "", missing_set, counter)
	var total: int = int(counter[0])
	var present: int = int(counter[1])
	var ratio := float(present) / float(maxi(total, 1))
	return {
		"ratio": ratio,
		"present": present,
		"total": total,
		"level": _completeness_level(ratio),
	}


static func _count_leaves(template: Dictionary, path: String, missing_set: Dictionary, counter: Array) -> void:
	for key in template:
		var child_path := "%s.%s" % [path, key] if not path.is_empty() else str(key)
		var top := child_path.split(".")[0]
		if COMPLETENESS_SKIP.has(top):
			continue
		var declared: Variant = template[key]
		if declared is Dictionary:
			_count_leaves(declared, child_path, missing_set, counter)
			continue
		if declared is String and declared == "@list":
			continue
		# 只有"模板默认为 null"的叶子才是真正的数据字段；`false`/版本号这类
		# 模板常量不计入完整度分母（否则"不是 Demo"会被算成缺数据）。
		if declared != null:
			continue
		counter[0] += 1
		if not missing_set.has(child_path):
			counter[1] += 1


static func _completeness_level(ratio: float) -> String:
	if ratio >= 0.9:
		return "high"
	if ratio >= 0.6:
		return "medium"
	if ratio > 0.0:
		return "low"
	return "none"


static func _map_name(report: Dictionary) -> String:
	var map_data = report.get("map", {})
	if map_data is Dictionary:
		return str((map_data as Dictionary).get("name", ""))
	return ""


static func _adjutant_type(report: Dictionary) -> String:
	var adjutant = report.get("adjutant", {})
	if adjutant is Dictionary:
		return str((adjutant as Dictionary).get("type", ""))
	return ""


static func _score_of(report: Dictionary) -> float:
	var score = report.get("performance_score", {})
	if score is Dictionary and (score as Dictionary).get("total", null) != null:
		return float((score as Dictionary).get("total"))
	return -1.0


static func _sum_amounts(primary: Variant, fallback: Variant) -> float:
	var total := _sum_one(primary)
	if total < 0.0:
		total = _sum_one(fallback)
	return total


static func _sum_one(value: Variant) -> float:
	if value == null:
		return -1.0
	if value is int or value is float:
		return float(value)
	if value is Dictionary:
		var total := 0.0
		var found := false
		for key in (value as Dictionary):
			var entry = value[key]
			if entry is int or entry is float:
				total += float(entry)
				found = true
		return total if found else -1.0
	return -1.0


static func _normalize_base_value(value: Variant) -> float:
	if value == null:
		return 0.0
	if value is float or value is int:
		var number := float(value)
		return number if number <= 1.0 else number / 100.0
	return 0.0


## 侦察单位白名单。Demo 与真实对局**共用这一份**，否则"侦察单位数"在两条链路上
## 会各算一套（明细表里有的类型，汇总里不算，页面上就对不上）。
const SCOUT_UNIT_IDS := ["drone"]


## 从逐类型单位明细推导「单位统计 11 项」的汇总口径。
##
## 三条纪律：
## 1. **空明细 ⇒ 全 null**。没有单位数据时这些统计是"未测量"而不是 0；用 0 冒充会让玩家
##    看到"阵亡 0 人 / 存活率 100%"，那是编造，不是缺失。
## 2. **只从明细推导**，不额外接收总量参数 —— 保证汇总与 `combat.units` 表同源，
##    不会出现"表里加起来 37、汇总写 40"的两套数字。
## 3. **未测量的列给 null**。明细行里根本没有 `killed`（击杀没有可订阅信号）时，
##    汇总写 null 而不是 0；"测到 0"和"没测"必须能区分。
static func derive_unit_stats(rows: Variant) -> Dictionary:
	if not (rows is Array) or (rows as Array).is_empty():
		return _empty_unit_stats()
	var produced := 0
	var lost := 0
	var kills := 0
	var dealt := 0.0
	var taken := 0.0
	var lifetime_weighted := 0.0
	var lifetime_denom := 0
	var scout := 0
	var counted := 0
	var produced_measured := false
	var lost_measured := false
	var kills_measured := false
	var dealt_measured := false
	var taken_measured := false
	for item in (rows as Array):
		if not (item is Dictionary):
			continue
		var entry: Dictionary = item
		# 判定用 "键存在**且**非 null"：归一化过的行会把缺失键补成 null，
		# 直接 `has()` + `int(null)` 会炸；`int(null)` 也绝不能当成 0。
		var count := 0
		if entry.get("produced", null) != null:
			produced_measured = true
			count = int(entry.get("produced"))
		produced += count
		if entry.get("lost", null) != null:
			lost_measured = true
			lost += int(entry.get("lost"))
		if entry.get("killed", null) != null:
			kills_measured = true
			kills += int(entry.get("killed"))
		if entry.get("damage_dealt", null) != null:
			dealt_measured = true
			dealt += float(entry.get("damage_dealt"))
		if entry.get("damage_taken", null) != null:
			taken_measured = true
			taken += float(entry.get("damage_taken"))
		if entry.get("avg_lifetime_s", null) != null:
			lifetime_weighted += float(entry["avg_lifetime_s"]) * float(count)
			lifetime_denom += count
		if SCOUT_UNIT_IDS.has(str(entry.get("id", ""))):
			scout += count
		counted += 1
	if counted == 0:
		return _empty_unit_stats()
	var denom := maxf(float(produced), 1.0)
	# 先算成局部变量再塞进字典：GDScript 的 `x if c else null` 跨行要用反斜杠续行，
	# 在字典字面量里容易踩坑，拆开写更稳。
	# 逐列独立判定"是否测量过"：生产/损失两列是存活率的输入，缺任一列存活率就无法成立。
	var produced_out: Variant = produced if produced_measured else null
	var lost_out: Variant = lost if lost_measured else null
	var alive_out: Variant = null
	var survival_out: Variant = null
	if produced_measured and lost_measured:
		alive_out = maxi(0, produced - lost)
		survival_out = roundf((1.0 - float(lost) / denom) * 1000.0) / 1000.0
	var kills_out: Variant = kills if kills_measured else null
	var kill_loss_out: Variant = null
	if kills_measured:
		kill_loss_out = roundf(float(kills) / maxf(float(lost), 1.0) * 100.0) / 100.0
	var dealt_per_unit: Variant = null
	if dealt_measured:
		dealt_per_unit = roundf(dealt / denom)
	var taken_per_unit: Variant = null
	if taken_measured:
		taken_per_unit = roundf(taken / denom)
	var lifetime_avg: Variant = null
	if lifetime_denom > 0:
		lifetime_avg = roundf(lifetime_weighted / maxf(float(lifetime_denom), 1.0))
	return {
		"produced": produced_out,
		"lost": lost_out,
		"alive": alive_out,
		"survival_rate": survival_out,
		"kills": kills_out,
		"kill_loss_ratio": kill_loss_out,
		"damage_per_unit": dealt_per_unit,
		"damage_taken_per_unit": taken_per_unit,
		"avg_lifetime_s": lifetime_avg,
		"unique_types": counted,
		"scout_units": scout,
	}


static func _empty_unit_stats() -> Dictionary:
	# 键顺序与 TEMPLATE.combat.unit_stats 保持一致，便于肉眼比对。
	return {
		"produced": null, "lost": null, "alive": null, "survival_rate": null,
		"kills": null, "kill_loss_ratio": null, "damage_per_unit": null,
		"damage_taken_per_unit": null, "avg_lifetime_s": null,
		"unique_types": null, "scout_units": null,
	}
