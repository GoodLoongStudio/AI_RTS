extends Control

## 资源时间曲线：库存 / 采集速度 / 消耗速度三条线 + 重大事件标记。
##
## 为什么用 `_draw` + 子 Label 而不是 draw_string：本项目的中文在 `draw_string`
## 的 fallback 字体下极易出方框（ProfileRadar.gd 里已经踩过）。这里只画几何图形，
## 所有文字（图例 / 时间轴 / 空状态）都用子 Label，继承主题字体。
##
## 缺失纪律：`series` 为空时只画网格并显示「本局未记录资源曲线」；某条线整段为 null
## 时那条线不画，图例上直接显示 "—"，**绝不用 0 补出一条贴着底边的假曲线**。

const STOCK_COLOR := Color("#f3c77b")
const GATHER_COLOR := Color("#49c99b")
const SPEND_COLOR := Color("#e05b47")
const GRID_COLOR := Color(0.36, 0.52, 0.60, 0.22)
const AXIS_COLOR := Color(0.36, 0.52, 0.60, 0.45)

const LEGEND_HEIGHT := 34.0
const TICK_ROWS := 4

var points: Array = []
var events: Array = []
var empty_message := "本局未记录资源曲线"

var _stock_visible := false
var _gather_visible := false
var _spend_visible := false
var _stock_peak: Variant = null
var _gather_peak: Variant = null
var _spend_peak: Variant = null
var _duration: Variant = null

var _empty_label: Label
var _legend: HFlowContainer


func _ready() -> void:
	custom_minimum_size = Vector2(0, 200)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_empty_label = Label.new()
	_empty_label.add_theme_font_size_override("font_size", 12)
	_empty_label.add_theme_color_override("font_color", Color("#5d757d"))
	_empty_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_empty_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_empty_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_empty_label)
	_legend = HFlowContainer.new()
	_legend.add_theme_constant_override("h_separation", 16)
	_legend.add_theme_constant_override("v_separation", 2)
	_legend.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_legend)
	resized.connect(_relayout)
	_relayout()


func set_data(next_points: Array, next_events: Array) -> void:
	points = next_points if next_points is Array else []
	events = next_events if next_events is Array else []
	_recompute()
	_relayout()
	queue_redraw()


func _recompute() -> void:
	_stock_visible = false
	_gather_visible = false
	_spend_visible = false
	_stock_peak = null
	_gather_peak = null
	_spend_peak = null
	_duration = null
	for sample in points:
		if not (sample is Dictionary):
			continue
		var entry: Dictionary = sample
		if entry.get("t", null) != null:
			_duration = entry["t"] if _duration == null else maxf(float(_duration), float(entry["t"]))
		if entry.get("stock", null) != null:
			_stock_visible = true
			_stock_peak = float(entry["stock"]) if _stock_peak == null \
				else maxf(float(_stock_peak), float(entry["stock"]))
		if entry.get("gather_rate", null) != null:
			_gather_visible = true
			_gather_peak = float(entry["gather_rate"]) if _gather_peak == null \
				else maxf(float(_gather_peak), float(entry["gather_rate"]))
		if entry.get("spend_rate", null) != null:
			_spend_visible = true
			_spend_peak = float(entry["spend_rate"]) if _spend_peak == null \
				else maxf(float(_spend_peak), float(entry["spend_rate"]))


func _relayout() -> void:
	if _empty_label == null:
		return
	_empty_label.visible = points.is_empty()
	_empty_label.text = empty_message
	var plot_height := size.y - LEGEND_HEIGHT
	_empty_label.position = Vector2(0, 0)
	_empty_label.size = Vector2(size.x, maxf(plot_height, 10.0))
	_legend.position = Vector2(0, maxf(plot_height, 10.0))
	_legend.size = Vector2(size.x, LEGEND_HEIGHT)
	_rebuild_legend()


func _rebuild_legend() -> void:
	for child in _legend.get_children():
		child.queue_free()
	if points.is_empty():
		return
	_legend.add_child(_legend_item("库存（A+B）", STOCK_COLOR,
		"—" if _stock_peak == null else MatchReportSchema.number_text(_stock_peak)))
	_legend.add_child(_legend_item("采集速度/min", GATHER_COLOR,
		"—" if _gather_peak == null else MatchReportSchema.number_text(_gather_peak, 1)))
	_legend.add_child(_legend_item("消耗速度/min", SPEND_COLOR,
		"—" if _spend_peak == null else MatchReportSchema.number_text(_spend_peak, 1)))
	var marked := PackedStringArray()
	for event in events:
		if event is Dictionary and not str((event as Dictionary).get("label", "")).is_empty():
			marked.append(str((event as Dictionary)["label"]))
	var marker_text := "事件标记：—" if marked.is_empty() else "事件标记：" + "、".join(marked)
	_legend.add_child(ReportWidgets.label(marker_text, 11, Color("#8ea7ad")))


func _legend_item(text: String, color: Color, value_text: String) -> Label:
	var node := ReportWidgets.label("%s %s" % [text, value_text], 11, color)
	return node


func _draw() -> void:
	var plot := Rect2(Vector2.ZERO, Vector2(size.x, maxf(size.y - LEGEND_HEIGHT, 10.0)))
	if plot.size.x <= 4.0 or plot.size.y <= 4.0:
		return
	draw_rect(plot, Color(0.016, 0.043, 0.067, 0.55), true)
	draw_rect(plot, AXIS_COLOR, false, 1.0)
	for index in range(1, TICK_ROWS + 1):
		var y := plot.position.y + plot.size.y * float(index) / float(TICK_ROWS + 1)
		draw_line(Vector2(plot.position.x, y), Vector2(plot.end.x, y), GRID_COLOR, 1.0)
	for index in range(1, 6):
		var x := plot.position.x + plot.size.x * float(index) / 6.0
		draw_line(Vector2(x, plot.position.y), Vector2(x, plot.end.y), GRID_COLOR, 1.0)
	if points.is_empty():
		return

	var max_t := 0.0
	for sample in points:
		if sample is Dictionary and (sample as Dictionary).get("t", null) != null:
			max_t = maxf(max_t, float((sample as Dictionary)["t"]))
	if max_t <= 0.0:
		max_t = 1.0

	if _stock_visible and _stock_peak != null and float(_stock_peak) > 0.0:
		_draw_series(plot, "stock", float(_stock_peak), max_t, STOCK_COLOR, 2.0)
	var rate_peak := 0.0
	if _gather_peak != null:
		rate_peak = maxf(rate_peak, float(_gather_peak))
	if _spend_peak != null:
		rate_peak = maxf(rate_peak, float(_spend_peak))
	if rate_peak > 0.0:
		if _gather_visible:
			_draw_series(plot, "gather_rate", rate_peak, max_t, GATHER_COLOR, 1.6)
		if _spend_visible:
			_draw_series(plot, "spend_rate", rate_peak, max_t, SPEND_COLOR, 1.6)

	# 事件标记：竖虚线 + 顶部三角。标签统一放在图例行里，避免图内文字互相压。
	for event in events:
		if not (event is Dictionary):
			continue
		var entry: Dictionary = event
		if entry.get("t", null) == null:
			continue
		var x := plot.position.x + clampf(float(entry["t"]) / max_t, 0.0, 1.0) * plot.size.x
		var color := Color(str(entry.get("color", "8ea7ad")))
		var y := plot.position.y
		while y < plot.end.y:
			draw_line(Vector2(x, y), Vector2(x, minf(y + 5.0, plot.end.y)),
				Color(color.r, color.g, color.b, 0.75), 1.0)
			y += 9.0
		var tip := Vector2(x, plot.position.y)
		draw_colored_polygon(PackedVector2Array([
			tip, tip + Vector2(-4.0, -7.0), tip + Vector2(4.0, -7.0),
		]), color)


func _draw_series(plot: Rect2, key: String, peak: float, max_t: float, color: Color,
		width: float) -> void:
	var line := PackedVector2Array()
	for sample in points:
		if not (sample is Dictionary):
			continue
		var entry: Dictionary = sample
		if entry.get("t", null) == null or entry.get(key, null) == null:
			# 断点：不补 0，直接把折线打断成两段。
			if line.size() >= 2:
				draw_polyline(line, color, width, true)
			line = PackedVector2Array()
			continue
		var x := plot.position.x + clampf(float(entry["t"]) / max_t, 0.0, 1.0) * plot.size.x
		var ratio := clampf(float(entry[key]) / peak, 0.0, 1.0)
		var y := plot.end.y - ratio * (plot.size.y - 8.0) - 4.0
		line.append(Vector2(x, y))
	if line.size() >= 2:
		draw_polyline(line, color, width, true)
	elif line.size() == 1:
		draw_circle(line[0], 2.0, color)
