extends Control

## 玩家画像五维雷达：战斗 / 经济 / 建设 / 进攻倾向 / 风险偏好。
##
## 轴名刻意用子 `Label` 而不是 `_draw` + `draw_string`：
## `draw_string` 走的是 fallback 字体，中文极易出方框；子 Label 会继承主题字体。
##
## 无快照时只画空网格、不画数据多边形 —— 不编造任何分析结果。

const AXIS_NAMES := ["战斗", "经济", "建设", "进攻倾向", "风险偏好"]
const RING_COUNT := 4

var values: PackedFloat32Array = PackedFloat32Array([0.0, 0.0, 0.0, 0.0, 0.0])
var has_data := false
var axis_color := Color("#38c9ee")
var grid_color := Color(0.36, 0.52, 0.60, 0.38)
var label_color := Color("#8ea7ad")

var _labels: Array[Label] = []


func _ready() -> void:
	custom_minimum_size = Vector2(0, 200)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_build_labels()
	resized.connect(_layout_labels)
	_layout_labels()
	queue_redraw()


func set_values(next: PackedFloat32Array) -> void:
	if next.size() != AXIS_NAMES.size():
		return
	values = next
	has_data = true
	queue_redraw()


func set_empty() -> void:
	values = PackedFloat32Array([0.0, 0.0, 0.0, 0.0, 0.0])
	has_data = false
	queue_redraw()


func _build_labels() -> void:
	for name in AXIS_NAMES:
		var label := Label.new()
		label.text = name
		label.add_theme_font_size_override("font_size", 12)
		label.add_theme_color_override("font_color", label_color)
		label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(label)
		_labels.append(label)


func _angle(index: int) -> float:
	## 第一根轴指向正上方，其余顺时针均分。
	return -PI * 0.5 + TAU * float(index) / float(AXIS_NAMES.size())


func _radius() -> float:
	return minf(size.x, size.y) * 0.30


func _layout_labels() -> void:
	if _labels.is_empty():
		return
	var center := size * 0.5
	var radius := _radius()
	for i in range(_labels.size()):
		var label := _labels[i]
		var extent := label.get_combined_minimum_size()
		var direction := Vector2(cos(_angle(i)), sin(_angle(i)))
		label.size = extent
		label.position = center + direction * radius * 1.30 - extent * 0.5


func _draw() -> void:
	var center := size * 0.5
	var radius := _radius()
	# 同心网格
	for ring in range(1, RING_COUNT + 1):
		var ring_radius := radius * float(ring) / float(RING_COUNT)
		var ring_points := PackedVector2Array()
		for i in range(AXIS_NAMES.size()):
			ring_points.append(center + Vector2(cos(_angle(i)), sin(_angle(i))) * ring_radius)
		ring_points.append(ring_points[0])
		draw_polyline(ring_points, grid_color, 1.0, true)
	# 轴线
	for i in range(AXIS_NAMES.size()):
		var tip := center + Vector2(cos(_angle(i)), sin(_angle(i))) * radius
		draw_line(center, tip, grid_color, 1.0, true)
	if not has_data:
		return
	# 数据多边形
	var shape := PackedVector2Array()
	for i in range(AXIS_NAMES.size()):
		var direction := Vector2(cos(_angle(i)), sin(_angle(i)))
		shape.append(center + direction * radius * clampf(values[i], 0.0, 1.0))
	draw_colored_polygon(shape, Color(axis_color.r, axis_color.g, axis_color.b, 0.28))
	var outline := shape.duplicate()
	outline.append(shape[0])
	draw_polyline(outline, axis_color, 2.0, true)
	for point in shape:
		draw_circle(point, 3.5, axis_color)
