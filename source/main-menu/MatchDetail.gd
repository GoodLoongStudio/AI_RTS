extends "res://source/ui/MenuPage.gd"

## 对局详情页：6 个标签页（总览 / 经济 / 生产与建设 / 战斗 / 时间线 / 成长与 Hermes）。
##
## 三条纪律（对应"数据真实性"要求）：
## 1. **事实与推断分区**。结构化数字（经济/生产/建设/战斗/时间线）与 Hermes 的自然语言
##    观察/建议**分在不同标签页的分区卡里**，后者每条都强制带出 `依据：…`（evidence）。
## 2. **null 一律显示 "—"**，并在每个分区顶部列出该分区的缺失项。不把缺失写成 0。
## 3. **页面自己不推算任何统计**。所有数字直接来自 `MatchReportStore` 的报告；
##    评分也来自报告里的 `performance_score`（写入时由 `MatchReportScoring` 算好）。

const ROOT := "CenterContainer/PanelContainer/MarginContainer/VBoxContainer"
const FRAME := "CenterContainer/PanelContainer"
const LIST_SCENE := "res://source/main-menu/MatchHistory.tscn"

const TABS := ["总览", "经济", "生产与建设", "战斗", "时间线", "成长与 Hermes"]
const TIMELINE_GROUPS := ["开局", "经济", "生产", "建设", "侦察", "科技", "战斗", "目标", "Hermes", "结算"]

var _report: Dictionary = {}
var _tab_bar: TabBar
var _tab_host: Control
var _pages: Array = []
var _timeline_filter := ""
var _timeline_body: VBoxContainer
var _missing: PackedStringArray = PackedStringArray()


func _ready() -> void:
	SystemUIStyle.apply(self)
	_style_frame()
	_tab_bar = get_node_or_null(ROOT + "/TabBar") as TabBar
	_tab_host = get_node_or_null(ROOT + "/Content/TabHost") as Control
	_report = _load_report()
	_missing = _collect_missing()
	if _tab_bar != null:
		for title in TABS:
			_tab_bar.add_tab(title)
		# 只有 `tab_changed`：`TabBar` **没有** `tab_focus` 信号（那是 `TabContainer` 的东西），
		# 连它会抛 "Invalid access to property or key 'tab_focus'"，`_ready` 就此中断
		# ⇒ 6 个标签页一个都建不出来（页面全白）。
		_tab_bar.tab_changed.connect(_select_tab)
		_tab_bar.custom_minimum_size = Vector2(0, 30)
	if _report.is_empty():
		_build_unavailable()
	else:
		_bind_header()
		_add_page(Callable(self, "_build_overview"))
		_add_page(Callable(self, "_build_economy"))
		_add_page(Callable(self, "_build_production"))
		_add_page(Callable(self, "_build_combat"))
		_add_page(Callable(self, "_build_timeline"))
		_add_page(Callable(self, "_build_growth_hermes"))
	_select_tab(MatchHistoryNav.pending_tab)
	SystemUIStyle.skip_subtree(self)
	var back := get_node_or_null(ROOT + "/TopBar/BackButton") as Button
	if back != null:
		back.grab_focus()


func _style_frame() -> void:
	var frame := get_node_or_null(FRAME) as PanelContainer
	if frame != null:
		frame.add_theme_stylebox_override("panel", SystemUIStyle.flat(
			SystemUIStyle.GLASS_DEEP, SystemUIStyle.RADIUS_PANEL, SystemUIStyle.LINE_STRONG, 1))
	var content := get_node_or_null(ROOT + "/Content") as PanelContainer
	if content != null:
		content.add_theme_stylebox_override("panel", ReportWidgets.surface(
			ReportWidgets.SUB_BG, SystemUIStyle.LINE_SOFT, 1, 8, 10, 8))


# ==================== 载入与页头 ====================

func _load_report() -> Dictionary:
	var store := get_node_or_null("/root/MatchReportStore")
	if store == null:
		return {}
	var report_id := MatchHistoryNav.take_pending_report_id()
	if not report_id.is_empty():
		var found: Dictionary = store.get_report(report_id)
		if not found.is_empty():
			return found
	# 没有指定报告（例如直接打开详情场景）→ 退回最近一场，而不是空白报错。
	var newest: Array = store.query({"sort": "date_desc"})
	if newest.is_empty():
		return {}
	var first = newest[0]
	return first if first is Dictionary else {}


## 缺失项：把"这个报告缺了什么"按分区暴露给界面。
func _collect_missing() -> PackedStringArray:
	var out := PackedStringArray()
	var completeness = _report.get("data_completeness", {})
	if completeness is Dictionary and (completeness as Dictionary).get("missing", null) is Array:
		for path in (completeness as Dictionary)["missing"]:
			out.append(str(path))
	return out


func _missing_for(prefix: String) -> Array:
	var out: Array = []
	for path in _missing:
		if path.begins_with(prefix):
			out.append(path)
	return out


func _bind_header() -> void:
	var outcome := str(_report.get("outcome", "unknown"))
	var accent := _outcome_color(outcome)
	var duration := MatchReportSchema.duration_text(_report.get("duration_seconds", null))
	var title := get_node_or_null(ROOT + "/TopBar/Title") as Label
	if title != null:
		title.text = "%s  ·  %s  ·  %s" % [
			str(_report.get("report_id", "对局报告")), MatchReportSchema.outcome_label(outcome), duration,
		]
		title.add_theme_color_override("font_color", SystemUIStyle.CYAN)
	var chip := get_node_or_null(ROOT + "/TopBar/ResultChip") as Label
	if chip != null:
		var score = _report.get("performance_score", {})
		var total = (score as Dictionary).get("total", null) if score is Dictionary else null
		chip.text = "%s   评分 %s" % [MatchReportSchema.outcome_label(outcome),
			MatchReportSchema.number_text(total)]
		chip.add_theme_color_override("font_color", accent)
	var meta := get_node_or_null(ROOT + "/Meta") as Label
	if meta != null:
		var map: Dictionary = _section("map")
		var adjutant: Dictionary = _section("adjutant")
		var completeness: Dictionary = _section("data_completeness")
		var parts := PackedStringArray()
		parts.append("地图 %s" % _text_or_null(map.get("name", null)))
		parts.append("种子 %s" % MatchReportSchema.number_text(map.get("seed", null)))
		parts.append("难度 %s" % MatchReportSchema.difficulty_label(_report.get("difficulty", null)))
		parts.append("模式 %s" % MatchReportSchema.mode_label(_report.get("mode", null)))
		parts.append("副官 %s" % (str(adjutant.get("type", "")) if not str(adjutant.get("type", "")).is_empty() else "—"))
		parts.append("开始 %s" % (str(_report.get("created_at", "")) if _report.get("created_at", null) != null else "—"))
		parts.append("数据完整度 %s" % MatchReportSchema.percent_text(completeness.get("ratio", null)))
		if bool(_report.get("demo", false)):
			parts.append("演示数据（seed %s）" % MatchReportSchema.number_text(_report.get("demo_seed", null)))
		if bool(_report.get("migrated_from_legacy", false)):
			parts.append("由旧版档案迁移")
		meta.text = "   ·   ".join(parts)
		meta.add_theme_color_override("font_color",
			SystemUIStyle.AMBER if bool(_report.get("demo", false)) else SystemUIStyle.DIM)


func _build_unavailable() -> void:
	var scroll := ReportWidgets.scroll(_tab_host, "Unavailable")
	scroll.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var body := ReportWidgets.column(scroll)
	var card := ReportWidgets.card(body)
	card.add_child(ReportWidgets.label("没有可展示的对局报告", 16, SystemUIStyle.MUTED))
	card.add_child(ReportWidgets.label(
		"本地档案里没有任何对局记录，或请求的报告 id 已不存在。完成一局对局后再回到这里。",
		12, SystemUIStyle.DIM))
	_pages.append(scroll)


# ==================== 页面骨架 ====================

func _add_page(builder: Callable) -> void:
	var scroll := ReportWidgets.scroll(_tab_host, "Tab%d" % _pages.size())
	scroll.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var body := ReportWidgets.column(scroll, 10)
	builder.call(body)
	scroll.visible = false
	_pages.append(scroll)


func _select_tab(index: int) -> void:
	if index < 0 or index >= _pages.size():
		return
	for position in range(_pages.size()):
		(_pages[position] as Control).visible = position == index
	if _tab_bar != null and _tab_bar.current_tab != index:
		_tab_bar.current_tab = index
	var page := _pages[index] as ScrollContainer
	page.scroll_vertical = 0


# ==================== 1. 总览 ====================

func _build_overview(body: Node) -> void:
	var overview: Dictionary = _section("overview")
	var metrics_a := HBoxContainer.new()
	metrics_a.add_theme_constant_override("separation", 8)
	body.add_child(metrics_a)
	ReportWidgets.metric(metrics_a, "对局时长",
		MatchReportSchema.duration_text(_report.get("duration_seconds", null)), "", SystemUIStyle.CYAN)
	ReportWidgets.metric(metrics_a, "建造建筑",
		_n(overview.get("structures_built", null)), "座", SystemUIStyle.GREEN)
	ReportWidgets.metric(metrics_a, "生产单位",
		_n(overview.get("units_produced", null)), "个", SystemUIStyle.GREEN)
	ReportWidgets.metric(metrics_a, "造成伤害",
		_n(overview.get("damage_dealt", null)), "", SystemUIStyle.AMBER)
	ReportWidgets.metric(metrics_a, "承受伤害",
		_n(overview.get("damage_taken", null)), "", SystemUIStyle.RED)
	var metrics_b := HBoxContainer.new()
	metrics_b.add_theme_constant_override("separation", 8)
	body.add_child(metrics_b)
	ReportWidgets.metric(metrics_b, "单位损失",
		_n(overview.get("units_lost", null)), "个", SystemUIStyle.RED)
	ReportWidgets.metric(metrics_b, "敌方击杀",
		_n(overview.get("enemies_killed", null)), "个", SystemUIStyle.GREEN)
	ReportWidgets.metric(metrics_b, "总采集资源",
		_amounts(overview.get("total_gathered", null)), "", SystemUIStyle.AMBER)
	ReportWidgets.metric(metrics_b, "总消耗资源",
		_amounts(overview.get("total_spent", null)), "", SystemUIStyle.AMBER)
	ReportWidgets.metric(metrics_b, "本局评分",
		_n(overview.get("score", null)), "", SystemUIStyle.AMBER_HI)

	var info := ReportWidgets.section(body, "对局信息", SystemUIStyle.CYAN)
	var map: Dictionary = _section("map")
	var adjutant: Dictionary = _section("adjutant")
	ReportWidgets.kv_grid(info, [
		["地图名称", _text_or_null(map.get("name", null))],
		["地图种子", MatchReportSchema.number_text(map.get("seed", null))],
		["地图规模", _text_or_null(map.get("size", null))],
		["地图人数", _text_or_null(map.get("players", null))],
		["难度", MatchReportSchema.difficulty_label(_report.get("difficulty", null))],
		["游戏模式", MatchReportSchema.mode_label(_report.get("mode", null))],
		["Hermes 副官", _text_or_null(adjutant.get("type", null))],
		["副官等级", _text_or_null(adjutant.get("level", null))],
		["指挥官", _text_or_null(_report.get("commander", null))],
		["对局版本", _text_or_null(_report.get("match_version", null))],
		["开始时间", _text_or_null(_report.get("created_at", null))],
		["数据来源", _text_or_null(_section("source").get("generated_by", null))],
	], 2)
	ReportWidgets.missing_note(info, _missing_for("map") + _missing_for("adjutant") + _missing_for("commander"))

	var result := ReportWidgets.section(body, "胜负与关键目标",
		_outcome_color(str(_report.get("outcome", "unknown"))))
	var condition := _text_or_null(_report.get("victory_condition", null))
	var reason := _text_or_null(_report.get("defeat_reason", null))
	ReportWidgets.kv_grid(result, [
		["胜负结果", MatchReportSchema.outcome_label(str(_report.get("outcome", "unknown")))],
		["胜利条件", condition],
		["失败原因", reason],
	], 1)
	var done: Array = overview.get("objectives_completed", []) if overview.get("objectives_completed", []) is Array else []
	var failed: Array = overview.get("objectives_failed", []) if overview.get("objectives_failed", []) is Array else []
	result.add_child(ReportWidgets.label("已完成目标（%d）" % done.size(), 12, SystemUIStyle.GREEN))
	if done.is_empty():
		result.add_child(ReportWidgets.label("—", 12, SystemUIStyle.DIM))
	for item in done:
		var entry: Dictionary = item if item is Dictionary else {}
		result.add_child(ReportWidgets.label("✔ %s   完成于 %s" % [
			str(entry.get("title", "")), MatchReportSchema.duration_text(entry.get("completed_at_s", null))],
			12, SystemUIStyle.TEXT))
	result.add_child(ReportWidgets.label("未完成目标（%d）" % failed.size(), 12, SystemUIStyle.RED))
	if failed.is_empty():
		result.add_child(ReportWidgets.label("—", 12, SystemUIStyle.DIM))
	for item in failed:
		var entry: Dictionary = item if item is Dictionary else {}
		result.add_child(ReportWidgets.label("✘ %s   失败于 %s   %s" % [
			str(entry.get("title", "")), MatchReportSchema.duration_text(entry.get("failed_at_s", null)),
			str(entry.get("reason", ""))], 12, SystemUIStyle.TEXT))

	var economy := ReportWidgets.section(body, "资源与效率", SystemUIStyle.AMBER)
	ReportWidgets.kv_grid(economy, [
		["最终资源", _amounts(overview.get("final_resources", null))],
		["总采集资源", _amounts(overview.get("total_gathered", null))],
		["总消耗资源", _amounts(overview.get("total_spent", null))],
		["资源效率", _pct(overview.get("resource_efficiency", null), 1)],
		["最终基地价值", _n(overview.get("final_base_value", null), 2)],
		["最终控制区域", _text_or_null(overview.get("final_controlled_zones", null))],
	], 2)

	_build_score_block(body)

	var events := ReportWidgets.section(body, "关键事件", SystemUIStyle.AMBER_HI)
	var key_events: Array = overview.get("key_events", []) if overview.get("key_events", []) is Array else []
	if key_events.is_empty():
		events.add_child(ReportWidgets.label("本局未记录关键事件", 12, SystemUIStyle.DIM))
	for item in key_events:
		var entry: Dictionary = item if item is Dictionary else {}
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 10)
		events.add_child(row)
		var stamp := ReportWidgets.label(MatchReportSchema.duration_text(entry.get("t", null)), 11,
			SystemUIStyle.AMBER)
		stamp.custom_minimum_size = Vector2(56, 0)
		row.add_child(stamp)
		row.add_child(ReportWidgets.label(str(entry.get("title", "")), 12, SystemUIStyle.TEXT))
		var detail := ReportWidgets.label(str(entry.get("detail", "")), 11, SystemUIStyle.DIM)
		detail.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		detail.clip_text = true
		row.add_child(detail)

	var completeness := ReportWidgets.section(body, "数据完整度", SystemUIStyle.MUTED)
	var info_dict: Dictionary = _section("data_completeness")
	ReportWidgets.bar(completeness, "完整度", info_dict.get("ratio", null),
		_pct(info_dict.get("ratio", null)), SystemUIStyle.CYAN, 90)
	ReportWidgets.kv_grid(completeness, [
		["已记录字段", _text_or_null(info_dict.get("present", null))],
		["应有字段", _text_or_null(info_dict.get("total", null))],
		["完整度等级", _text_or_null(info_dict.get("level", null))],
	], 3)
	ReportWidgets.missing_note(completeness, _missing, 10)


func _build_score_block(body: Node) -> void:
	var score: Dictionary = _section("performance_score")
	var panel := ReportWidgets.section(body, "对局表现评分", SystemUIStyle.AMBER_HI,
		"评分依据逐条列出，可对照上方原始数据")
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 12)
	panel.add_child(head)
	head.add_child(ReportWidgets.label(_n(score.get("total", null)), 30, SystemUIStyle.AMBER_HI))
	head.add_child(ReportWidgets.label("/ 100", 13, SystemUIStyle.DIM))
	head.add_child(ReportWidgets.label("算法 %s" % _text_or_null(score.get("method", null)), 11,
		SystemUIStyle.DIM))
	if bool(score.get("partial", false)):
		var missing_dims: Array = score.get("missing_dimensions", [])
		var names := PackedStringArray()
		for dimension in missing_dims:
			names.append(str(MatchReportSchema.SCORE_DIMENSION_LABEL.get(str(dimension), str(dimension))))
		head.add_child(ReportWidgets.chip("部分依据缺失：%s" % "、".join(names), SystemUIStyle.RED))
	if score.get("total", null) == null:
		panel.add_child(ReportWidgets.label(
			"本局报告缺少可用的评分输入，因此不给总分（不会用 0 分冒充）。", 12, SystemUIStyle.RED))
	var breakdown: Dictionary = score.get("breakdown", {}) if score.get("breakdown", {}) is Dictionary else {}
	for dimension in MatchReportSchema.SCORE_DIMENSIONS:
		var entry: Dictionary = breakdown.get(dimension, {}) if breakdown.get(dimension, {}) is Dictionary else {}
		var value = entry.get("score", null)
		ReportWidgets.bar(panel, str(MatchReportSchema.SCORE_DIMENSION_LABEL.get(dimension, dimension)),
			null if value == null else float(value) / 100.0,
			"— / 100" if value == null else "%s / 100" % _n(value),
			_color_for_dimension(str(dimension)), 110)
		var basis := ReportWidgets.label("依据：%s" % _text_or_null(entry.get("basis", null)), 11,
			SystemUIStyle.MUTED)
		basis.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		basis.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		panel.add_child(basis)


func _color_for_dimension(dimension: String) -> Color:
	match dimension:
		"combat":
			return SystemUIStyle.RED
		"economy":
			return SystemUIStyle.AMBER
		"construction":
			return SystemUIStyle.GREEN
		"operations":
			return SystemUIStyle.CYAN
		"risk":
			return Color("#d500f9")
		_:
			return SystemUIStyle.AMBER_HI


# ==================== 2. 经济 ====================

func _build_economy(body: Node) -> void:
	var economy: Dictionary = _section("economy")
	var totals: Dictionary = economy.get("totals", {}) if economy.get("totals", {}) is Dictionary else {}
	ReportWidgets.missing_note(body, _missing_for("economy"), 6)

	var overview_block := ReportWidgets.section(body, "资源总览", SystemUIStyle.AMBER)
	var rows: Array = []
	var resources: Array = economy.get("resources", []) if economy.get("resources", []) is Array else []
	for item in resources:
		var entry: Dictionary = item if item is Dictionary else {}
		rows.append([
			_text_or_null(entry.get("label", null)),
			_n(entry.get("initial", null)), _n(entry.get("gathered", null)),
			_n(entry.get("gather_avg_per_min", null), 1), _n(entry.get("gather_peak_per_min", null), 1),
			_n(entry.get("spent", null)), _n(entry.get("wasted", null)),
			_n(entry.get("remaining", null)), _pct(entry.get("utilization", null)),
		])
	ReportWidgets.table(overview_block, ["资源", "初始", "采集", "采集均速", "峰值", "消耗", "浪费",
		"剩余", "利用率"], rows, [1.5, 0.8, 0.9, 1.0, 0.8, 0.9, 0.8, 0.9, 0.8])

	var rate_block := ReportWidgets.section(body, "总量与速率", SystemUIStyle.AMBER)
	var rates: Dictionary = economy.get("rates", {}) if economy.get("rates", {}) is Dictionary else {}
	ReportWidgets.kv_grid(rate_block, [
		["采集总量", _n(totals.get("gathered", null))],
		["消耗总量", _n(totals.get("spent", null))],
		["浪费资源", _n(totals.get("wasted", null))],
		["当前剩余", _n(totals.get("remaining", null))],
		["平均采集速度", "%s /min" % _n(rates.get("gather_avg_per_min", null), 1)],
		["峰值采集速度", "%s /min" % _n(rates.get("gather_peak_per_min", null), 1)],
		["平均消耗速度", "%s /min" % _n(rates.get("spend_avg_per_min", null), 1)],
		["资源利用率", _pct(economy.get("utilization", null), 1)],
		["资源转化效率", "%s 伤害/资源" % _n(economy.get("conversion_efficiency", null), 2)],
	], 2)

	var curve_block := ReportWidgets.section(body, "资源时间曲线", SystemUIStyle.CYAN,
		"库存 / 采集速度 / 消耗速度，竖虚线为重大事件")
	var chart: Control = load("res://source/main-menu/ResourceCurveChart.gd").new()
	curve_block.add_child(chart)
	var series: Array = economy.get("series", []) if economy.get("series", []) is Array else []
	var markers: Array = []
	for sample in series:
		if not (sample is Dictionary):
			continue
		var entry: Dictionary = sample
		if str(entry.get("event", "")).is_empty():
			continue
		markers.append({"t": entry.get("t", null), "label": str(entry.get("event", "")),
			"color": _event_color(str(entry.get("event", "")))})
	chart.set_data(series, markers)

	var source_block := ReportWidgets.section(body, "资源来源分类", SystemUIStyle.GREEN)
	ReportWidgets.table(source_block, ["来源", "数量", "占比"], _breakdown_rows(
		economy.get("source_breakdown", [])), [2.0, 1.0, 1.0])
	var sink_block := ReportWidgets.section(body, "资源消耗分类", SystemUIStyle.RED)
	ReportWidgets.table(sink_block, ["用途", "数量", "占比"], _breakdown_rows(
		economy.get("sink_breakdown", [])), [2.0, 1.0, 1.0])

	var structure: Dictionary = economy.get("structure", {}) if economy.get("structure", {}) is Dictionary else {}
	var structure_block := ReportWidgets.section(body, "经济结构", SystemUIStyle.CYAN)
	var ratio: Dictionary = structure.get("investment_ratio", {}) if structure.get("investment_ratio", {}) is Dictionary else {}
	var ratio_labels := {"construction": "建造投入", "military": "军事投入",
		"technology": "科技投入", "defense": "防御投入"}
	var ratio_colors := {"construction": SystemUIStyle.GREEN, "military": SystemUIStyle.RED,
		"technology": SystemUIStyle.CYAN, "defense": SystemUIStyle.AMBER}
	for key in ["construction", "military", "technology", "defense"]:
		var value = ratio.get(key, null)
		ReportWidgets.bar(structure_block, str(ratio_labels[key]), value,
			_pct(value, 0), ratio_colors[key], 96)
	ReportWidgets.kv_grid(structure_block, [
		["最常使用资源", _resource_label(structure.get("dominant_resource", null))],
		["经济高峰时间", MatchReportSchema.duration_text(structure.get("peak_time_seconds", null))],
	], 2)
	structure_block.add_child(ReportWidgets.label("资源转化路线", 12, SystemUIStyle.MUTED))
	ReportWidgets.table(structure_block, ["从", "到", "数量", "占比"], _route_rows(
		structure.get("conversion_routes", [])), [1.4, 1.6, 1.0, 0.8])

	var drought_block := ReportWidgets.section(body, "经济断档", SystemUIStyle.RED)
	var droughts: Array = structure.get("drought_windows", []) if structure.get("drought_windows", []) is Array else []
	if droughts.is_empty():
		drought_block.add_child(ReportWidgets.label("本局未记录资源断档", 12, SystemUIStyle.DIM))
	var drought_rows: Array = []
	for item in droughts:
		var entry: Dictionary = item if item is Dictionary else {}
		drought_rows.append([MatchReportSchema.duration_text(entry.get("start_s", null)),
			MatchReportSchema.duration_text(entry.get("end_s", null)),
			_text_or_null(entry.get("cause", null))])
	ReportWidgets.table(drought_block, ["开始", "结束", "起因"], drought_rows, [1.0, 1.0, 3.0])

	_build_unit_curves(body, structure)


func _build_unit_curves(body: Node, structure: Dictionary) -> void:
	var block := ReportWidgets.section(body, "采集 / 生产单位数量变化", SystemUIStyle.GREEN)
	var gatherers: Array = structure.get("gatherers", []) if structure.get("gatherers", []) is Array else []
	var producers: Array = structure.get("producers", []) if structure.get("producers", []) is Array else []
	if gatherers.is_empty() and producers.is_empty():
		block.add_child(ReportWidgets.label("本局未记录单位数量曲线", 12, SystemUIStyle.DIM))
		return
	var rows: Array = []
	var step := maxi(1, gatherers.size() / 6)
	for index in range(0, gatherers.size(), step):
		var gatherer: Dictionary = gatherers[index] if gatherers[index] is Dictionary else {}
		var producer: Dictionary = producers[index] if index < producers.size() and producers[index] is Dictionary else {}
		rows.append([MatchReportSchema.duration_text(gatherer.get("t", null)),
			_text_or_null(gatherer.get("count", null)), _text_or_null(producer.get("count", null))])
	ReportWidgets.table(block, ["时间", "采集单位", "累计生产单位"], rows, [1.0, 1.0, 1.0])


# ==================== 3. 生产与建设 ====================

func _build_production(body: Node) -> void:
	var production: Dictionary = _section("production")
	var construction: Dictionary = _section("construction")
	ReportWidgets.missing_note(body, _missing_for("production") + _missing_for("construction"), 6)

	var queue: Dictionary = production.get("queue", {}) if production.get("queue", {}) is Dictionary else {}
	var queue_block := ReportWidgets.section(body, "生产队列", SystemUIStyle.CYAN)
	ReportWidgets.kv_grid(queue_block, [
		["平均队列等待时间", MatchReportSchema.duration_text(queue.get("wait_avg_s", null))],
		["队列空转总时长", MatchReportSchema.duration_text(queue.get("idle_total_s", null))],
		["取消生产次数", _text_or_null(queue.get("cancellations", null))],
		["生产建筑利用率", _pct(queue.get("utilization", null), 0)],
		["最早生产时间", MatchReportSchema.duration_text(queue.get("earliest_production_s", null))],
		["最晚生产时间", MatchReportSchema.duration_text(queue.get("latest_production_s", null))],
		["首支主力部队形成", MatchReportSchema.duration_text(queue.get("first_main_force_s", null))],
	], 2)

	var units_block := ReportWidgets.section(body, "单位生产统计", SystemUIStyle.GREEN)
	var unit_rows: Array = production.get("units", []) if production.get("units", []) is Array else []
	var rows: Array = []
	for item in unit_rows:
		var entry: Dictionary = item if item is Dictionary else {}
		rows.append([
			_text_or_null(entry.get("label", null)),
			_n(entry.get("produced", null)),
			_n(entry.get("batches", null)),
			MatchReportSchema.duration_text(entry.get("avg_interval_s", null)),
			_n(entry.get("resource_cost", null)),
			_n(entry.get("killed", null)),
			_n(entry.get("lost", null)),
			MatchReportSchema.duration_text(entry.get("avg_lifetime_s", null)),
			MatchReportSchema.duration_text(entry.get("first_seen_s", null)),
			MatchReportSchema.duration_text(entry.get("last_alive_s", null)),
		])
	ReportWidgets.table(units_block, ["单位", "生产", "批次", "平均间隔", "资源消耗", "击杀", "损失",
		"平均存活", "首次出场", "最后存活"], rows,
		[1.3, 0.7, 0.6, 0.9, 1.0, 0.7, 0.7, 0.9, 0.9, 0.9])

	var composition: Dictionary = production.get("composition", {}) if production.get("composition", {}) is Dictionary else {}
	var comp_block := ReportWidgets.section(body, "单位构成", SystemUIStyle.CYAN)
	comp_block.add_child(ReportWidgets.label("单位类型占比", 12, SystemUIStyle.MUTED))
	var type_ratio: Array = composition.get("type_ratio", []) if composition.get("type_ratio", []) is Array else []
	if type_ratio.is_empty():
		comp_block.add_child(ReportWidgets.label("—", 12, SystemUIStyle.DIM))
	for item in type_ratio:
		var entry: Dictionary = item if item is Dictionary else {}
		ReportWidgets.bar(comp_block, "%s（%s）" % [_text_or_null(entry.get("label", null)),
			_n(entry.get("count", null))], entry.get("share", null),
			_pct(entry.get("share", null), 0), SystemUIStyle.CYAN, 150)
	var weight: Dictionary = composition.get("weight_class", {}) if composition.get("weight_class", {}) is Dictionary else {}
	var role: Dictionary = composition.get("role_class", {}) if composition.get("role_class", {}) is Dictionary else {}
	comp_block.add_child(ReportWidgets.label("重量级占比", 12, SystemUIStyle.MUTED))
	ReportWidgets.bar(comp_block, "轻型", weight.get("light", null), _pct(weight.get("light", null)), SystemUIStyle.GREEN, 150)
	ReportWidgets.bar(comp_block, "中型", weight.get("medium", null), _pct(weight.get("medium", null)), SystemUIStyle.CYAN, 150)
	ReportWidgets.bar(comp_block, "重型", weight.get("heavy", null), _pct(weight.get("heavy", null)), SystemUIStyle.AMBER, 150)
	comp_block.add_child(ReportWidgets.label("职能占比", 12, SystemUIStyle.MUTED))
	ReportWidgets.bar(comp_block, "远程", role.get("ranged", null), _pct(role.get("ranged", null)), SystemUIStyle.AMBER, 150)
	ReportWidgets.bar(comp_block, "近战", role.get("melee", null), _pct(role.get("melee", null)), SystemUIStyle.RED, 150)
	ReportWidgets.bar(comp_block, "空中", role.get("air", null), _pct(role.get("air", null)), SystemUIStyle.CYAN, 150)
	ReportWidgets.bar(comp_block, "支援", role.get("support", null), _pct(role.get("support", null)), SystemUIStyle.GREEN, 150)
	ReportWidgets.kv_grid(comp_block, [
		["侦察单位占比", _pct(composition.get("scout_ratio", null), 0)],
		["主力单位占比", _pct(composition.get("main_force_ratio", null), 0)],
		["牺牲单位占比", _pct(composition.get("sacrificed_ratio", null), 0)],
	], 3)

	var combos: Dictionary = production.get("combos", {}) if production.get("combos", {}) is Dictionary else {}
	var combo_block := ReportWidgets.section(body, "单位组合", SystemUIStyle.AMBER)
	_combo_table(combo_block, "最常使用", combos.get("most_used", []))
	_combo_table(combo_block, "最有效", combos.get("most_effective", []))
	_combo_table(combo_block, "失败率最高", combos.get("highest_loss", []))

	var build_block := ReportWidgets.section(body, "建设统计", SystemUIStyle.GREEN)
	ReportWidgets.kv_grid(build_block, [
		["建造建筑总数", _text_or_null(construction.get("total_built", null))],
		["建筑被摧毁数量", _text_or_null(construction.get("destroyed_count", null))],
		["建筑存活率", _pct(construction.get("survival_rate", null), 0)],
		["建筑平均存活时间", MatchReportSchema.duration_text(construction.get("avg_lifetime_s", null))],
		["前线建筑数量", _text_or_null(construction.get("frontline_count", null))],
		["经济建筑数量", _text_or_null(construction.get("economy_count", null))],
		["防御建筑数量", _text_or_null(construction.get("defense_count", null))],
		["科技建筑数量", _text_or_null(construction.get("tech_count", null))],
		["扩张次数", _text_or_null(construction.get("expansions", null))],
		["首次扩张时间", MatchReportSchema.duration_text(construction.get("first_expansion_s", null))],
		["最远建筑距离", "%s m" % _n(construction.get("farthest_building_distance_m", null))],
		["建筑密度", "%s /km²" % _n(construction.get("density_per_km2", null), 1)],
		["防线完整度", _pct(construction.get("defense_line_integrity", null), 0)],
	], 2)

	var detail_block := ReportWidgets.section(body, "建筑明细", SystemUIStyle.CYAN)
	var buildings: Array = construction.get("buildings", []) if construction.get("buildings", []) is Array else []
	var building_rows: Array = []
	for item in buildings:
		var entry: Dictionary = item if item is Dictionary else {}
		building_rows.append([
			_text_or_null(entry.get("label", null)), _text_or_null(entry.get("role", null)),
			_n(entry.get("count", null)), _n(entry.get("cost", null)),
			MatchReportSchema.duration_text(entry.get("first_built_s", null)),
			_n(entry.get("destroyed", null)), _pct(entry.get("survival_rate", null), 0),
			MatchReportSchema.duration_text(entry.get("avg_lifetime_s", null)),
		])
	ReportWidgets.table(detail_block, ["建筑", "角色", "数量", "成本", "首次建造", "被摧毁",
		"存活率", "平均存活"], building_rows, [1.4, 0.8, 0.6, 0.8, 1.0, 0.8, 0.8, 1.0])

	var order_block := ReportWidgets.section(body, "建造顺序", SystemUIStyle.MUTED)
	var order: Array = construction.get("order", []) if construction.get("order", []) is Array else []
	var order_rows: Array = []
	for item in order:
		var entry: Dictionary = item if item is Dictionary else {}
		order_rows.append([
			MatchReportSchema.duration_text(entry.get("t", null)),
			_text_or_null(entry.get("building", null)),
			_text_or_null(entry.get("position", null)),
			_amounts(entry.get("cost", null)),
			_text_or_null(entry.get("note", null)),
		])
	ReportWidgets.table(order_block, ["时间", "建筑", "位置", "成本", "备注"], order_rows,
		[0.8, 1.3, 1.2, 1.2, 1.6])


func _combo_table(parent: Node, title: String, items: Array) -> void:
	parent.add_child(ReportWidgets.label(title, 12, SystemUIStyle.MUTED))
	if items.is_empty():
		parent.add_child(ReportWidgets.label("—", 12, SystemUIStyle.DIM))
		return
	var rows: Array = []
	for item in items:
		var entry: Dictionary = item if item is Dictionary else {}
		var units: Array = entry.get("units", []) if entry.get("units", []) is Array else []
		var names := PackedStringArray()
		for unit in units:
			names.append(str(unit))
		rows.append([" + ".join(names), _text_or_null(entry.get("count", null)),
			_pct(entry.get("win_rate", null), 0)])
	ReportWidgets.table(parent, ["单位组合", "次数", "胜率"], rows, [3.0, 0.8, 0.8])


# ==================== 4. 战斗 ====================

func _build_combat(body: Node) -> void:
	var combat: Dictionary = _section("combat")
	ReportWidgets.missing_note(body, _missing_for("combat"), 6)
	var overview: Dictionary = combat.get("overview", {}) if combat.get("overview", {}) is Dictionary else {}
	var overview_block := ReportWidgets.section(body, "战斗总览", SystemUIStyle.RED)
	ReportWidgets.kv_grid(overview_block, [
		["总战斗次数", _text_or_null(overview.get("engagements", null))],
		["首次交战时间", MatchReportSchema.duration_text(overview.get("first_contact_s", null))],
		["最后一次交战", MatchReportSchema.duration_text(overview.get("last_contact_s", null))],
		["交战持续时间", MatchReportSchema.duration_text(overview.get("total_contact_s", null))],
		["战斗胜率", _pct(overview.get("win_rate", null), 0)],
		["进攻次数", _text_or_null(overview.get("offensives", null))],
		["防守次数", _text_or_null(overview.get("defenses", null))],
		["反攻次数", _text_or_null(overview.get("counterattacks", null))],
		["伏击次数", _text_or_null(overview.get("ambushes", null))],
		["撤退次数", _text_or_null(overview.get("retreats", null))],
		["战斗转折点", _text_or_null(overview.get("turning_point", null))],
		["最大规模交战", "%s 个单位" % _n(overview.get("largest_engagement", null))],
		["最重要的一场战斗", _text_or_null(overview.get("most_important", null))],
	], 2)

	var damage: Dictionary = combat.get("damage", {}) if combat.get("damage", {}) is Dictionary else {}
	var damage_block := ReportWidgets.section(body, "伤害统计", SystemUIStyle.AMBER)
	ReportWidgets.kv_grid(damage_block, [
		["总造成伤害", _n(damage.get("dealt", null))],
		["总承受伤害", _n(damage.get("taken", null))],
		["对建筑伤害", _n(damage.get("to_structures", null))],
		["对单位伤害", _n(damage.get("to_units", null))],
		["对核心目标伤害", _n(damage.get("to_heroes", null))],
		["物理伤害", _n(damage.get("physical", null))],
		["能量伤害", _n(damage.get("energy", null))],
		["爆炸伤害", _n(damage.get("explosive", null))],
		["友军误伤", _n(damage.get("friendly_fire", null))],
		["每分钟伤害", _n(damage.get("per_minute", null), 1)],
		["伤害交换效率", _n(damage.get("exchange_ratio", null), 2)],
	], 2)

	var units_block := ReportWidgets.section(body, "单位战斗统计", SystemUIStyle.CYAN)
	var unit_rows: Array = combat.get("units", []) if combat.get("units", []) is Array else []
	var rows: Array = []
	for item in unit_rows:
		var entry: Dictionary = item if item is Dictionary else {}
		rows.append([
			_text_or_null(entry.get("label", null)), _n(entry.get("produced", null)),
			_n(entry.get("killed", null)), _n(entry.get("lost", null)),
			_n(entry.get("damage_dealt", null)), _n(entry.get("damage_taken", null)),
			MatchReportSchema.duration_text(entry.get("avg_lifetime_s", null)),
			MatchReportSchema.duration_text(entry.get("first_seen_s", null)),
			MatchReportSchema.duration_text(entry.get("last_alive_s", null)),
		])
	ReportWidgets.table(units_block, ["单位", "生产", "击杀", "损失", "造成伤害", "承受伤害",
		"平均存活", "首次出场", "最后存活"], rows, [1.3, 0.7, 0.7, 0.7, 1.1, 1.1, 0.9, 0.9, 0.9])

	var key_block := ReportWidgets.section(body, "最有价值 / 最差表现", SystemUIStyle.AMBER_HI)
	ReportWidgets.kv_grid(key_block, [
		["最有价值单位", _text_or_null(combat.get("mvp_unit", null))],
		["损失最严重单位", _text_or_null(combat.get("worst_loss_unit", null))],
		["击杀效率最高单位", _text_or_null(combat.get("most_efficient_kill_unit", null))],
		["低效单位", _text_or_null(combat.get("least_efficient_unit", null))],
	], 2)

	var quality: Dictionary = combat.get("quality", {}) if combat.get("quality", {}) is Dictionary else {}
	var quality_block := ReportWidgets.section(body, "战斗质量", SystemUIStyle.CYAN)
	var ratio_metrics := [
		["focus_fire", "集火效率"], ["target_selection", "目标选择质量"],
		["retreat_timing", "战斗撤退时机"], ["ability_hit_rate", "技能命中率"],
		["recon_coverage", "侦察覆盖率"], ["adjutant_contribution", "副官技能贡献"],
	]
	for pair in ratio_metrics:
		var value = quality.get(str(pair[0]), null)
		ReportWidgets.bar(quality_block, str(pair[1]), value, _pct(value, 0), SystemUIStyle.AMBER, 120)
	ReportWidgets.kv_grid(quality_block, [
		["阵型保持时间", MatchReportSchema.duration_text(quality.get("formation_time_s", null))],
		["部队闲置时间", MatchReportSchema.duration_text(quality.get("idle_time_s", null))],
		["部队移动时间", MatchReportSchema.duration_text(quality.get("moving_time_s", null))],
		["平均交战距离", "%s m" % _n(quality.get("engagement_distance_m", null))],
		["平均反应时间", "%s s" % _n(quality.get("reaction_time_s", null), 1)],
		["关键技能使用次数", _text_or_null(quality.get("abilities_used", null))],
		["战斗中资源断档", "%s 次" % _n(quality.get("resource_drought_in_combat", null))],
	], 2)


# ==================== 5. 时间线 ====================

func _build_timeline(body: Node) -> void:
	var header := ReportWidgets.section(body, "时间线", SystemUIStyle.AMBER_HI,
		"按事件类型筛选；Hermes 标记的事件用琥珀色标出")
	var filter_bar := HFlowContainer.new()
	filter_bar.add_theme_constant_override("h_separation", 6)
	filter_bar.add_theme_constant_override("v_separation", 6)
	header.add_child(filter_bar)
	var all_button := SystemUIStyle.make_button("全部", 26)
	all_button.custom_minimum_size = Vector2(64, 26)
	all_button.add_theme_font_size_override("font_size", 11)
	all_button.pressed.connect(func() -> void: _set_timeline_filter(""))
	filter_bar.add_child(all_button)
	for group in TIMELINE_GROUPS:
		var button := SystemUIStyle.make_button(group, 26)
		button.custom_minimum_size = Vector2(72, 26)
		button.add_theme_font_size_override("font_size", 11)
		button.pressed.connect(func() -> void: _set_timeline_filter(group))
		filter_bar.add_child(button)
	_timeline_body = VBoxContainer.new()
	_timeline_body.add_theme_constant_override("separation", 6)
	_timeline_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.add_child(_timeline_body)
	_render_timeline()


func _set_timeline_filter(group: String) -> void:
	_timeline_filter = group
	_render_timeline()


func _render_timeline() -> void:
	if _timeline_body == null:
		return
	for child in _timeline_body.get_children():
		child.queue_free()
	var timeline: Array = _report.get("timeline", []) if _report.get("timeline", []) is Array else []
	var shown := 0
	for item in timeline:
		if not (item is Dictionary):
			continue
		var entry: Dictionary = item
		var type_key := str(entry.get("type", ""))
		var meta: Dictionary = MatchReportSchema.TIMELINE_TYPES.get(type_key, {})
		var group := str(meta.get("group", "其它"))
		if not _timeline_filter.is_empty() and group != _timeline_filter:
			continue
		shown += 1
		_timeline_body.add_child(_timeline_row(entry, type_key))
	if shown == 0:
		var note := ReportWidgets.label(
			"该类型下没有事件" if not _timeline_filter.is_empty() else "本局未记录时间线事件",
			12, SystemUIStyle.DIM)
		_timeline_body.add_child(note)
	else:
		var summary := ReportWidgets.label("共 %d 条事件%s" % [
			shown, "" if _timeline_filter.is_empty() else "（筛选：%s）" % _timeline_filter], 11,
			SystemUIStyle.MUTED)
		_timeline_body.add_child(summary)


func _timeline_row(entry: Dictionary, type_key: String) -> PanelContainer:
	var accent := MatchReportSchema.timeline_color(type_key)
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", ReportWidgets.surface(
		ReportWidgets.CARD_BG, Color(accent.r, accent.g, accent.b, 0.45), 1, 6, 10, 8))
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 3)
	panel.add_child(box)

	var line1 := HBoxContainer.new()
	line1.add_theme_constant_override("separation", 8)
	box.add_child(line1)
	var stamp := ReportWidgets.label(MatchReportSchema.duration_text(entry.get("t", null)), 12, accent)
	stamp.custom_minimum_size = Vector2(52, 0)
	line1.add_child(stamp)
	line1.add_child(ReportWidgets.chip(MatchReportSchema.timeline_label(type_key), accent))
	line1.add_child(ReportWidgets.label(str(entry.get("title", "")), 13, SystemUIStyle.TEXT))
	if bool(entry.get("hermes_tagged", false)):
		line1.add_child(ReportWidgets.chip("HERMES 标记", SystemUIStyle.AMBER_HI))
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	line1.add_child(spacer)
	var subject := _text_or_null(entry.get("subject", null))
	if subject != "—":
		line1.add_child(ReportWidgets.label(subject, 11, SystemUIStyle.CYAN))

	var detail := _text_or_null(entry.get("detail", null))
	if detail != "—":
		var detail_label := ReportWidgets.label(detail, 11, SystemUIStyle.MUTED)
		detail_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		box.add_child(detail_label)
	var extras := PackedStringArray()
	if entry.get("resources_delta", null) != null:
		extras.append("资源变化 %s" % _amounts(entry.get("resources_delta", null)))
	if entry.get("combat_impact", null) != null:
		extras.append("战斗影响 %s" % str(entry.get("combat_impact")))
	if not extras.is_empty():
		var extra_label := ReportWidgets.label("   ·   ".join(extras), 11, SystemUIStyle.DIM)
		extra_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		box.add_child(extra_label)
	return panel


# ==================== 6. 成长与 Hermes ====================

func _build_growth_hermes(body: Node) -> void:
	var growth_block := ReportWidgets.section(body, "成长状态", SystemUIStyle.AMBER)
	var before: Dictionary = _section("growth_before")
	var after: Dictionary = _section("growth_after")
	ReportWidgets.kv_grid(growth_block, [
		["本局开始前等级", _levels_text(before.get("levels", null))],
		["本局结束后等级", _levels_text(after.get("levels", null))],
		["本局使用成长点", _text_or_null(_report.get("growth_spent_this_match", null))],
		["可用成长点", _text_or_null(after.get("available_points", null))],
		["累计获得成长点", _text_or_null(after.get("earned_total", null))],
		["累计消耗成长点", _text_or_null(after.get("spent_total", null))],
	], 2)
	var ratios := _branch_ratios(after.get("levels", null))
	growth_block.add_child(ReportWidgets.label(
		"三条成长线投入比例（按各分支已投入等级占比，本局结束时的快照）", 11, SystemUIStyle.MUTED))
	for branch in ["combat", "economy", "construction"]:
		var entry: Dictionary = ratios.get(branch, {})
		ReportWidgets.bar(growth_block, str(entry.get("label", branch)), entry.get("ratio", null),
			"%s 级（%s）" % [_n(entry.get("level", null)), _pct(entry.get("ratio", null), 0)],
			SystemUIStyle.branch_accent(branch), 120)
	growth_block.add_child(ReportWidgets.label(
		"成长选择对本局策略的影响属于 Hermes 推断，见下方「HERMES 观察」与「HERMES 建议」。",
		11, SystemUIStyle.DIM))

	var hermes: Dictionary = _section("hermes_analysis")
	var status := str(hermes.get("status", "none"))
	var status_block := ReportWidgets.section(body, "Hermes 分析状态", _hermes_color(status))
	var chips_row := HBoxContainer.new()
	chips_row.add_theme_constant_override("separation", 8)
	status_block.add_child(chips_row)
	chips_row.add_child(ReportWidgets.chip(MatchReportSchema.hermes_status_label(status),
		_hermes_color(status), true))
	chips_row.add_child(ReportWidgets.chip("模型 %s" % _text_or_null(hermes.get("model_version", null)),
		SystemUIStyle.CYAN))
	if bool(_report.get("demo", false)):
		chips_row.add_child(ReportWidgets.chip("DEMO 数据", SystemUIStyle.AMBER))
	ReportWidgets.kv_grid(status_block, [
		["生成时间", _text_or_null(hermes.get("generated_at", null))],
		["来源报告", _list_text(hermes.get("source_report_ids", null))],
		["数据依据字段", _list_text(hermes.get("data_basis", null))],
	], 1)
	var cache: Dictionary = hermes.get("cache", {}) if hermes.get("cache", {}) is Dictionary else {}
	if status == "cached":
		status_block.add_child(ReportWidgets.label(
			"⚠ Hermes 本次不可用，展示的是最近一次缓存结果。", 12, SystemUIStyle.AMBER))
		ReportWidgets.kv_grid(status_block, [
			["缓存生成时间", _text_or_null(cache.get("cached_at", null))],
			["缓存来源报告生成时间", _text_or_null(cache.get("source_generated_at", null))],
			["缓存是否过期", ("已过期" if bool(cache.get("stale", false)) else "未过期")
				if cache.get("stale", null) != null else "—"],
		], 2)
	var failure := _text_or_null(hermes.get("failure_reason", null))
	if status == "failed":
		status_block.add_child(ReportWidgets.label("失败原因：%s" % failure, 12, SystemUIStyle.RED))
	if status == "running":
		status_block.add_child(ReportWidgets.label(
			"分析进行中：本局尚未产出结论，页面不会预先显示任何推断。", 12, SystemUIStyle.CYAN))
	if status == "none":
		status_block.add_child(ReportWidgets.label(
			"本局尚未提交给 Hermes 分析，因此没有观察与建议。", 12, SystemUIStyle.DIM))

	_narrative_block(body, "HERMES 观察（自然语言，属推断）", hermes.get("observations", []), false)
	_narrative_block(body, "HERMES 建议（自然语言，属推断）", hermes.get("suggestions", []), true)

	var memory_block := ReportWidgets.section(body, "本局新增的长期记忆", SystemUIStyle.CYAN)
	var memory: Array = hermes.get("memory_delta", []) if hermes.get("memory_delta", []) is Array else []
	var memory_rows: Array = []
	for item in memory:
		var entry: Dictionary = item if item is Dictionary else {}
		memory_rows.append([_text_or_null(entry.get("key", null)), _text_or_null(entry.get("label", null)),
			_text_or_null(entry.get("value", null)), _text_or_null(entry.get("source", null))])
	ReportWidgets.table(memory_block, ["键", "说明", "值", "来源"], memory_rows, [1.6, 1.0, 1.2, 1.2])

	var profile_block := ReportWidgets.section(body, "玩家画像更新", SystemUIStyle.CYAN)
	var updates: Array = hermes.get("profile_updates", []) if hermes.get("profile_updates", []) is Array else []
	var update_rows: Array = []
	for item in updates:
		var entry: Dictionary = item if item is Dictionary else {}
		update_rows.append([_text_or_null(entry.get("dimension", null)),
			_text_or_null(entry.get("before", null)), _text_or_null(entry.get("after", null)),
			_text_or_null(entry.get("basis", null))])
	ReportWidgets.table(profile_block, ["维度", "变更前", "变更后", "依据"], update_rows,
		[1.0, 0.7, 0.7, 3.0])

	var adjutant_block := ReportWidgets.section(body, "副官影响与未来推荐", SystemUIStyle.AMBER_HI)
	var impact: Dictionary = hermes.get("adjutant_impact", {}) if hermes.get("adjutant_impact", {}) is Dictionary else {}
	# 变量名不能叫 `signal`：那是 GDScript 保留字，会直接解析失败。
	# 字典字面量 `.get()` 返回 Variant，必须显式转型，否则 `:=` 推断告警被当错误。
	var recommendation_signal := str(impact.get("recommendation_signal", ""))
	var signal_label: String = str(
		{"keep": "建议保留", "reconsider": "建议重新评估"}.get(recommendation_signal, "—"))
	ReportWidgets.kv_grid(adjutant_block, [
		["副官类型", _text_or_null(impact.get("type", null))],
		["匹配得分", _text_or_null(impact.get("score", null))],
		["推荐信号", signal_label],
		["依据", _text_or_null(impact.get("basis", null))],
	], 1)


func _narrative_block(body: Node, title: String, items: Array, is_suggestion: bool) -> void:
	var block := ReportWidgets.section(body, title, SystemUIStyle.AMBER_HI)
	if items.is_empty():
		block.add_child(ReportWidgets.label("本局没有此类内容。", 12, SystemUIStyle.DIM))
		return
	for item in items:
		var entry: Dictionary = item if item is Dictionary else {}
		var card := ReportWidgets.card(block)
		var head := HBoxContainer.new()
		head.add_theme_constant_override("separation", 8)
		card.add_child(head)
		head.add_child(ReportWidgets.chip(
			"建议" if is_suggestion else "观察",
			SystemUIStyle.AMBER if is_suggestion else SystemUIStyle.CYAN))
		if is_suggestion and entry.get("adopted", null) != null:
			var adopted := bool(entry.get("adopted", false))
			head.add_child(ReportWidgets.chip("已采纳" if adopted else "未采纳",
				SystemUIStyle.GREEN if adopted else SystemUIStyle.MUTED))
		var text := ReportWidgets.label(str(entry.get("text", "")), 13, SystemUIStyle.TEXT)
		text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		head.add_child(text)
		var evidence: Array = entry.get("evidence", []) if entry.get("evidence", []) is Array else []
		var evidence_text := PackedStringArray()
		for path in evidence:
			evidence_text.append(str(path))
		var evidence_label := ReportWidgets.label(
			"依据：%s" % ("；".join(evidence_text) if not evidence_text.is_empty() else "—"),
			11, SystemUIStyle.MUTED)
		evidence_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		card.add_child(evidence_label)
		if is_suggestion and entry.get("outcome", null) != null \
				and not str(entry.get("outcome", "")).is_empty():
			var outcome := ReportWidgets.label("采纳后结果：%s" % str(entry.get("outcome")),
				11, SystemUIStyle.GREEN)
			outcome.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			card.add_child(outcome)


# ==================== 格式化工具 ====================

func _section(name: String) -> Dictionary:
	var value = _report.get(name, {})
	return value if value is Dictionary else {}


func _n(value: Variant, decimals: int = 0) -> String:
	return MatchReportSchema.number_text(value, decimals)


func _pct(value: Variant, decimals: int = 0) -> String:
	return MatchReportSchema.percent_text(value, decimals)


func _amounts(value: Variant) -> String:
	return MatchReportSchema.dict_amount_text(value)


func _text_or_null(value: Variant) -> String:
	if value == null:
		return "—"
	var text := str(value)
	return text if not text.is_empty() else "—"


func _list_text(value: Variant) -> String:
	if value == null:
		return "—"
	if not (value is Array):
		return str(value)
	var parts := PackedStringArray()
	for item in (value as Array):
		parts.append(str(item))
	return "、".join(parts) if not parts.is_empty() else "—"


func _resource_label(value: Variant) -> String:
	if value == null:
		return "—"
	return str(MatchReportSchema.RESOURCE_LABEL.get(str(value), str(value)))


func _breakdown_rows(items: Variant) -> Array:
	var rows: Array = []
	if not (items is Array):
		return rows
	for item in (items as Array):
		var entry: Dictionary = item if item is Dictionary else {}
		rows.append([_text_or_null(entry.get("label", null)), _n(entry.get("amount", null)),
			_pct(entry.get("share", null), 0)])
	return rows


func _route_rows(items: Variant) -> Array:
	var rows: Array = []
	if not (items is Array):
		return rows
	for item in (items as Array):
		var entry: Dictionary = item if item is Dictionary else {}
		rows.append([_text_or_null(entry.get("from", null)), _text_or_null(entry.get("to", null)),
			_n(entry.get("amount", null)), _pct(entry.get("share", null), 0)])
	return rows


## 成长等级文本：按 GrowthStore 的定义把节点等级汇总成三条线的等级。
func _levels_text(levels: Variant) -> String:
	if not (levels is Dictionary) or (levels as Dictionary).is_empty():
		return "—"
	var store := get_node_or_null("/root/GrowthStore")
	var definitions: Dictionary = store.DEFINITIONS if store != null else {}
	var labels := {"combat": "战斗", "economy": "经济", "construction": "建设"}
	var parts := PackedStringArray()
	var total := 0
	for branch in ["combat", "economy", "construction"]:
		var branch_total := 0
		for definition in definitions.get(branch, []):
			branch_total += int((levels as Dictionary).get(
				str((definition as Dictionary).get("id", "")), 0))
		total += branch_total
		if branch_total > 0:
			parts.append("%s %d 级" % [labels[branch], branch_total])
	if parts.is_empty():
		return "未投入成长点"
	parts.append("合计 %d 级" % total)
	return "、".join(parts)


func _branch_ratios(levels: Variant) -> Dictionary:
	var out := {"combat": {}, "economy": {}, "construction": {}}
	if not (levels is Dictionary):
		return out
	var store := get_node_or_null("/root/GrowthStore")
	var definitions: Dictionary = store.DEFINITIONS if store != null else {}
	var labels := {"combat": "战斗分支", "economy": "经济分支", "construction": "建设分支"}
	var totals := {"combat": 0, "economy": 0, "construction": 0}
	var sum := 0
	for branch in ["combat", "economy", "construction"]:
		for definition in definitions.get(branch, []):
			totals[branch] += int((levels as Dictionary).get(
				str((definition as Dictionary).get("id", "")), 0))
		sum += totals[branch]
	for branch in ["combat", "economy", "construction"]:
		out[branch] = {
			"label": labels[branch],
			"level": totals[branch],
			"ratio": null if sum <= 0 else float(totals[branch]) / float(sum),
		}
	return out


func _event_color(label: String) -> String:
	for type_key in MatchReportSchema.TIMELINE_TYPES:
		if label.contains(str(MatchReportSchema.TIMELINE_TYPES[type_key]["label"])):
			return str(MatchReportSchema.TIMELINE_TYPES[type_key]["color"])
	return "8ea7ad"


func _outcome_color(outcome: String) -> Color:
	if outcome == "victory":
		return SystemUIStyle.GREEN
	if outcome == "defeat":
		return SystemUIStyle.RED
	if outcome == "aborted":
		return SystemUIStyle.AMBER
	return SystemUIStyle.MUTED


func _hermes_color(status: String) -> Color:
	match status:
		"completed":
			return SystemUIStyle.GREEN
		"cached":
			return SystemUIStyle.AMBER
		"running":
			return SystemUIStyle.CYAN
		"failed":
			return SystemUIStyle.RED
		_:
			return SystemUIStyle.DIM


# ==================== 导航 ====================

func _on_back_to_list() -> void:
	get_tree().change_scene_to_file(LIST_SCENE)


func _on_back_to_profile() -> void:
	get_tree().change_scene_to_file(MatchHistoryNav.return_scene)


func _on_escape() -> bool:
	_on_back_to_list()
	return true
