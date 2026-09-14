extends "res://source/ui/MenuPage.gd"

## 历史对局列表页。
##
## 数据源只有 `MatchReportStore`（详细报告，唯一权威）。投影给玩家画像的摘要走
## `MatchReportStore.sync_growth_store()`，本页不碰 GrowthStore 的对局数组。
##
## 空状态分两种，措辞必须不同 —— 玩家要能分辨"真的没有对局"和"筛选太窄"：
##   - 库里一条都没有 → "暂无历史对局记录" + 说明如何产生记录
##   - 有记录但筛选后为空 → "没有符合当前筛选条件的对局" + 一键清除筛选
##
## 样式时序与 PlayerProfile 一致：`_ready` 里先建控件、后 `skip_subtree(self)`，
## 避免 MenuPage 基类延迟执行的通用 apply 把行内配色刷平。

const ROOT := "CenterContainer/PanelContainer/MarginContainer/VBoxContainer"
const FRAME := "CenterContainer/PanelContainer"
const DETAIL_SCENE := "res://source/main-menu/MatchDetail.tscn"
const ROW_HEIGHT := 70.0

const SORT_OPTIONS := [
	["日期 ↓（新→旧）", "date_desc"],
	["日期 ↑（旧→新）", "date_asc"],
	["评分 ↓", "score_desc"],
	["时长 ↓", "duration_desc"],
]
const OUTCOME_OPTIONS := [
	["全部结果", "all"],
	["胜利", "victory"],
	["失败", "defeat"],
	["中止", "aborted"],
]

var _filters := {
	"sort": "date_desc", "outcome": "all", "map": "all",
	"mode": "all", "adjutant": "all", "search": "",
}

var _filter_row: HBoxContainer
var _rows: VBoxContainer
var _stats: Label
var _list_scroll: ScrollContainer
var _option_buttons: Array = []
var _search_edit: LineEdit
var _filter_signature := ""


func _ready() -> void:
	SystemUIStyle.apply(self)
	_style_frame()
	_filter_row = get_node_or_null(ROOT + "/FilterRow") as HBoxContainer
	_rows = get_node_or_null(ROOT + "/ListPanel/ListScroll/Rows") as VBoxContainer
	_stats = get_node_or_null(ROOT + "/Header/Stats") as Label
	_list_scroll = get_node_or_null(ROOT + "/ListPanel/ListScroll") as ScrollContainer
	var title := get_node_or_null(ROOT + "/Header/Title") as Label
	if title != null:
		title.add_theme_color_override("font_color", SystemUIStyle.CYAN)
	if _stats != null:
		_stats.add_theme_color_override("font_color", SystemUIStyle.MUTED)
	var hint := get_node_or_null(ROOT + "/Footer/Hint") as Label
	if hint != null:
		hint.add_theme_color_override("font_color", SystemUIStyle.DIM)
	var back := get_node_or_null(ROOT + "/Footer/BackButton") as Button
	if back != null:
		back.text = "返回玩家画像" if MatchHistoryNav.return_scene.contains("PlayerProfile") else "返回成长指挥"
	_build_filters()
	var store := _store()
	if store != null and store.has_signal("reports_changed"):
		store.reports_changed.connect(_refresh)
	_refresh()
	SystemUIStyle.skip_subtree(self)
	if _rows != null and _rows.get_child_count() > 0:
		var first := _rows.get_child(0) as Control
		if first != null and first is Button:
			first.grab_focus()
	elif back != null:
		back.grab_focus()


func _style_frame() -> void:
	var frame := get_node_or_null(FRAME) as PanelContainer
	if frame != null:
		frame.add_theme_stylebox_override("panel", SystemUIStyle.flat(
			SystemUIStyle.GLASS_DEEP, SystemUIStyle.RADIUS_PANEL, SystemUIStyle.LINE_STRONG, 1))
	var list_panel := get_node_or_null(ROOT + "/ListPanel") as PanelContainer
	if list_panel != null:
		var style := ReportWidgets.surface(ReportWidgets.SUB_BG, SystemUIStyle.LINE_SOFT, 1, 8, 6, 6)
		list_panel.add_theme_stylebox_override("panel", style)


# ---------------- 筛选栏 ----------------

func _build_filters() -> void:
	if _filter_row == null:
		return
	_filter_row.add_child(_make_option("sort", SORT_OPTIONS, 168))
	_filter_row.add_child(_make_option("outcome", OUTCOME_OPTIONS, 118))
	var facets := _facets()
	_filter_row.add_child(_make_option("map", _facet_options("全部地图", facets["maps"]), 176))
	_filter_row.add_child(_make_option("mode", _facet_options("全部模式", facets["modes"]), 140))
	_filter_row.add_child(_make_option("adjutant", _facet_options("全部副官", facets["adjutants"]), 148))

	_search_edit = LineEdit.new()
	_search_edit.placeholder_text = "搜索对局编号 / 地图名"
	_search_edit.custom_minimum_size = Vector2(0, 30)
	_search_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_search_edit.add_theme_font_size_override("font_size", 12)
	SystemUIStyle.apply_to(_search_edit)
	_search_edit.custom_minimum_size = Vector2(0, 30)
	_search_edit.add_theme_font_size_override("font_size", 12)
	_search_edit.text_changed.connect(_on_search_changed)
	_filter_row.add_child(_search_edit)

	var clear_button := SystemUIStyle.make_button("清除筛选", 30)
	clear_button.custom_minimum_size = Vector2(104, 30)
	clear_button.add_theme_font_size_override("font_size", 12)
	clear_button.pressed.connect(_clear_filters)
	_filter_row.add_child(clear_button)


func _make_option(key: String, items: Array, width: int) -> OptionButton:
	var button := OptionButton.new()
	SystemUIStyle.apply_to(button)
	button.custom_minimum_size = Vector2(width, 30)
	button.add_theme_font_size_override("font_size", 12)
	for pair in items:
		button.add_item(str(pair[0]))
		button.set_item_metadata(button.item_count - 1, str(pair[1]))
	button.item_selected.connect(func(index: int) -> void:
		_filters[key] = str(button.get_item_metadata(index))
		_refresh())
	_option_buttons.append(button)
	# 已选值 = 当前筛选值（重建筛选栏时保持选择状态）
	var current := str(_filters.get(key, "all"))
	for index in range(button.item_count):
		if str(button.get_item_metadata(index)) == current:
			button.select(index)
			break
	return button


func _facet_options(all_label: String, values: Array) -> Array:
	var out: Array = [[all_label, "all"]]
	for value in values:
		out.append([str(value), str(value)])
	return out


func _facets() -> Dictionary:
	var store := _store()
	if store == null or not store.has_method("facets"):
		return {"maps": [], "modes": [], "adjutants": []}
	var raw: Dictionary = store.facets()
	var modes := PackedStringArray()
	for label in raw["modes"]:
		modes.append(str(label))
	return {"maps": raw["maps"], "modes": modes, "adjutants": raw["adjutants"]}


func _on_search_changed(text: String) -> void:
	_filters["search"] = text
	_refresh()


func _clear_filters() -> void:
	_filters = {"sort": _filters["sort"], "outcome": "all", "map": "all",
		"mode": "all", "adjutant": "all", "search": ""}
	if _search_edit != null:
		_search_edit.text = ""
	for button in _option_buttons:
		var option := button as OptionButton
		for index in range(option.item_count):
			if str(option.get_item_metadata(index)) == "all":
				option.select(index)
				break
	_refresh()


# ---------------- 列表 ----------------

func _store() -> Node:
	return get_node_or_null("/root/MatchReportStore")


func _refresh() -> void:
	if _rows == null:
		return
	for child in _rows.get_children():
		child.queue_free()
	var store := _store()
	if store == null:
		_show_empty("历史对局数据源不可用", "MatchReportStore 未加载，无法读取本地对局档案。")
		return
	# 筛选项跟随数据变化（新地图 / 新副官出现后要能选到）
	var signature := JSON.stringify(_facets())
	if signature != _filter_signature and not _option_buttons.is_empty():
		_filter_signature = signature
		_rebuild_filter_options()
	var reports: Array = store.query(_filters)
	_update_stats(store, reports)
	if reports.is_empty():
		if (store.reports as Array).is_empty():
			_show_empty("暂无历史对局记录",
				"完成一局对局后，详细报告会自动写入本地档案，并在这里按时间列出。")
		else:
			_show_empty("没有符合当前筛选条件的对局",
				"共 %d 条记录被当前筛选条件排除，可点「清除筛选」恢复全部。" % (store.reports as Array).size())
		return
	for report in reports:
		_rows.add_child(_build_row(report))


func _rebuild_filter_options() -> void:
	var facets := _facets()
	var specs := {
		"map": _facet_options("全部地图", facets["maps"]),
		"mode": _facet_options("全部模式", facets["modes"]),
		"adjutant": _facet_options("全部副官", facets["adjutants"]),
	}
	var keys := ["sort", "outcome", "map", "mode", "adjutant"]
	for index in range(_option_buttons.size()):
		var button := _option_buttons[index] as OptionButton
		var key := str(keys[index])
		if not specs.has(key):
			continue
		var current := str(_filters.get(key, "all"))
		button.clear()
		for pair in specs[key]:
			button.add_item(str(pair[0]))
			button.set_item_metadata(button.item_count - 1, str(pair[1]))
		for item_index in range(button.item_count):
			if str(button.get_item_metadata(item_index)) == current:
				button.select(item_index)
				break


func _update_stats(store: Node, shown: Array) -> void:
	if _stats == null:
		return
	var summary: Dictionary = store.stats()
	_stats.text = "共 %d 场（Demo %d） · 胜 %d / 负 %d / 中止 %d · 已分析 %d · 当前显示 %d" % [
		int(summary["total"]), int(summary["demo"]), int(summary["victory"]),
		int(summary["defeat"]), int(summary["aborted"]), int(summary["analyzed"]), shown.size(),
	]


func _show_empty(headline: String, detail: String) -> void:
	var card := ReportWidgets.card(_rows, ReportWidgets.SUB_BG, SystemUIStyle.LINE_SOFT)
	var spacer_top := Control.new()
	spacer_top.custom_minimum_size = Vector2(0, 60)
	card.add_child(spacer_top)
	var title := ReportWidgets.label(headline, 16, SystemUIStyle.MUTED)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	card.add_child(title)
	var body := ReportWidgets.label(detail, 12, SystemUIStyle.DIM)
	body.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	card.add_child(body)
	var spacer_bottom := Control.new()
	spacer_bottom.custom_minimum_size = Vector2(0, 60)
	card.add_child(spacer_bottom)


func _build_row(report: Dictionary) -> Button:
	var outcome := str(report.get("outcome", "unknown"))
	var accent := _outcome_color(outcome)
	var button := Button.new()
	button.custom_minimum_size = Vector2(0, ROW_HEIGHT)
	button.focus_mode = Control.FOCUS_ALL
	button.text = ""
	button.add_theme_stylebox_override("normal", _row_style(accent, 0))
	button.add_theme_stylebox_override("hover", _row_style(accent, 1))
	button.add_theme_stylebox_override("pressed", _row_style(accent, 2))
	button.add_theme_stylebox_override("focus", _row_style(accent, 3))
	button.tooltip_text = "点击查看详细报告"
	var report_id := str(report.get("report_id", ""))
	button.pressed.connect(func() -> void: _open_detail(report_id))

	var box := VBoxContainer.new()
	box.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	box.offset_left = 12
	box.offset_right = -12
	box.offset_top = 6
	box.offset_bottom = -6
	box.add_theme_constant_override("separation", 3)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	button.add_child(box)

	var map: Dictionary = report.get("map", {}) if report.get("map", {}) is Dictionary else {}
	var adjutant: Dictionary = report.get("adjutant", {}) if report.get("adjutant", {}) is Dictionary else {}
	var hermes: Dictionary = report.get("hermes_analysis", {}) if report.get("hermes_analysis", {}) is Dictionary else {}

	# 第一行：结果 / 编号 / Demo 徽标 / 地图 / 种子 / 时间
	var line1 := HBoxContainer.new()
	line1.add_theme_constant_override("separation", 8)
	line1.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(line1)
	line1.add_child(ReportWidgets.chip(MatchReportSchema.outcome_label(outcome), accent, true))
	line1.add_child(ReportWidgets.label(report_id, 13, SystemUIStyle.AMBER_HI))
	if bool(report.get("demo", false)):
		line1.add_child(ReportWidgets.chip("DEMO", SystemUIStyle.AMBER))
	line1.add_child(ReportWidgets.label(str(map.get("name", "")) if map.get("name", null) != null else "未知地图",
		12, SystemUIStyle.CYAN))
	line1.add_child(ReportWidgets.label(
		"种子 %s" % MatchReportSchema.number_text(map.get("seed", null)), 11, SystemUIStyle.DIM))
	line1.add_child(_spacer())
	line1.add_child(ReportWidgets.label(str(report.get("created_at", "")) if report.get("created_at", null) != null else "时间未知",
		11, SystemUIStyle.MUTED))

	# 第二行：时长 / 难度 / 模式 / 副官 / 加点 / Hermes / 评分
	var line2 := HBoxContainer.new()
	line2.add_theme_constant_override("separation", 10)
	line2.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(line2)
	line2.add_child(ReportWidgets.label("时长 %s"
		% MatchReportSchema.duration_text(report.get("duration_seconds", null)), 12, SystemUIStyle.TEXT))
	line2.add_child(ReportWidgets.label("难度 %s"
		% MatchReportSchema.difficulty_label(report.get("difficulty", null)), 12, SystemUIStyle.MUTED))
	line2.add_child(ReportWidgets.label("模式 %s"
		% MatchReportSchema.mode_label(report.get("mode", null)), 12, SystemUIStyle.MUTED))
	line2.add_child(ReportWidgets.label("副官 %s"
		% (str(adjutant.get("type", "")) if str(adjutant.get("type", "")).length() > 0 else "—"),
		12, SystemUIStyle.MUTED))
	line2.add_child(ReportWidgets.label("加点 %s" % _growth_text(report), 12, SystemUIStyle.MUTED))
	var status := str(hermes.get("status", "none"))
	line2.add_child(ReportWidgets.chip(MatchReportSchema.hermes_status_label(status), _hermes_color(status)))
	line2.add_child(_spacer())
	var score = report.get("performance_score", {})
	var score_value = (score as Dictionary).get("total", null) if score is Dictionary else null
	line2.add_child(ReportWidgets.label("评分 %s" % MatchReportSchema.number_text(score_value),
		13, SystemUIStyle.AMBER if score_value != null else SystemUIStyle.DIM))

	# 第三行：胜利条件 / 失败原因（只有在真的有这句话时才占位）
	var reason := str(report.get("defeat_reason", "")) if report.get("defeat_reason", null) != null else ""
	var condition := str(report.get("victory_condition", "")) if report.get("victory_condition", null) != null else ""
	var reason_text := ""
	if outcome == "defeat" and not reason.is_empty():
		reason_text = "失败原因：%s" % reason
	elif outcome == "aborted":
		reason_text = "中止：%s" % (reason if not reason.is_empty() else "对局未正常结束")
	elif not condition.is_empty():
		reason_text = "胜利条件：%s" % condition
	if not reason_text.is_empty():
		var line3 := ReportWidgets.label(reason_text, 11, SystemUIStyle.DIM)
		line3.clip_text = true
		box.add_child(line3)

	return button


func _spacer() -> Control:
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return spacer


func _row_style(accent: Color, mode: int) -> StyleBoxFlat:
	var background := Color(0.031, 0.086, 0.118, 0.85)
	var border := Color(accent.r, accent.g, accent.b, 0.45)
	var width := 1
	match mode:
		1:
			background = Color(0.063, 0.145, 0.188, 0.95)
			border = accent
		2:
			background = Color(0.086, 0.208, 0.259, 0.96)
			border = accent
		3:
			background = Color(0.055, 0.129, 0.169, 0.96)
			border = accent
			width = 2
	var style := SystemUIStyle.flat(background, 8, border, width)
	if mode >= 1:
		style.shadow_color = Color(accent.r, accent.g, accent.b, 0.22)
		style.shadow_size = 4
	return style


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


func _growth_text(report: Dictionary) -> String:
	var growth = report.get("growth_after", {})
	if not (growth is Dictionary):
		return "—"
	var levels = (growth as Dictionary).get("levels", {})
	if not (levels is Dictionary) or (levels as Dictionary).is_empty():
		return "无"
	var labels := {"combat": "战", "economy": "经", "construction": "建"}
	var parts := PackedStringArray()
	var store_growth := get_node_or_null("/root/GrowthStore")
	var definitions: Dictionary = store_growth.DEFINITIONS if store_growth != null else {}
	for branch in ["combat", "economy", "construction"]:
		var total := 0
		for definition in definitions.get(branch, []):
			total += int((levels as Dictionary).get(str((definition as Dictionary).get("id", "")), 0))
		if total > 0:
			parts.append("%s %d" % [labels[branch], total])
	if parts.is_empty():
		return "无"
	return " ".join(parts)


# ---------------- 导航 ----------------

func _open_detail(report_id: String) -> void:
	MatchHistoryNav.open_detail(report_id)
	get_tree().change_scene_to_file(DETAIL_SCENE)


func _on_back() -> void:
	get_tree().change_scene_to_file(MatchHistoryNav.return_scene)


func _on_escape() -> bool:
	_on_back()
	return true
