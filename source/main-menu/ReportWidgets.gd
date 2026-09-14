class_name ReportWidgets
extends RefCounted

## 历史对局报告页的控件工厂。
##
## 为什么单独一个文件：列表页与详情页共用同一套"分区卡 / KV 网格 / 统计表 / 占比条 /
## 徽标"外观。散在两个页面里各写一遍，很快就会分叉成两套配色。
##
## 纪律：**缺失值统一渲染成 "—"**，并由 `missing_note()` 就地说明缺口。
## 任何地方都不允许把 null 显示成 0。

const CARD_BG := Color(0.031, 0.086, 0.118, 0.92)
const SUB_BG := Color(0.024, 0.067, 0.094, 0.86)
const HEAD_BG := Color(0.055, 0.129, 0.169, 0.92)


static func surface(bg: Color, border: Color, width: int = 1, radius: int = SystemUIStyle.RADIUS_PANEL,
		pad_h: int = 14, pad_v: int = 12) -> StyleBoxFlat:
	var style := SystemUIStyle.rounded(bg, border, width, radius)
	style.content_margin_left = pad_h
	style.content_margin_right = pad_h
	style.content_margin_top = pad_v
	style.content_margin_bottom = pad_v
	style.shadow_size = 0
	return style


static func label(text: String, size: int = 13, color: Color = SystemUIStyle.TEXT) -> Label:
	var node := Label.new()
	node.text = text
	node.add_theme_font_size_override("font_size", size)
	node.add_theme_color_override("font_color", color)
	node.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return node


## 分区卡：带强调色左描边的标题 + 内容体。返回内容体（VBoxContainer）供调用方填充。
static func section(parent: Node, title: String, accent: Color = SystemUIStyle.CYAN,
		subtitle: String = "") -> VBoxContainer:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", surface(CARD_BG, accent, 1))
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(panel)
	var body := VBoxContainer.new()
	body.add_theme_constant_override("separation", 8)
	panel.add_child(body)
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 10)
	body.add_child(head)
	head.add_child(label("■", 12, accent))
	head.add_child(label(title, 14, accent))
	if not subtitle.is_empty():
		var note := label(subtitle, 11, SystemUIStyle.DIM)
		note.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		head.add_child(note)
	return body


## 无标题的次级卡（用于表格之类）。
static func card(parent: Node, bg: Color = SUB_BG, border: Color = SystemUIStyle.LINE_SOFT) -> VBoxContainer:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", surface(bg, border, 1))
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(panel)
	var body := VBoxContainer.new()
	body.add_theme_constant_override("separation", 4)
	panel.add_child(body)
	return body


## 键值网格。pairs = [[键, 值], ...]；值为 null 时自动渲染成 "—" 并标灰。
static func kv_grid(parent: Node, pairs: Array, columns: int = 2, key_color: Color = SystemUIStyle.MUTED,
		value_size: int = 13) -> GridContainer:
	var grid := GridContainer.new()
	grid.columns = columns * 2
	grid.add_theme_constant_override("h_separation", 14)
	grid.add_theme_constant_override("v_separation", 6)
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(grid)
	for pair in pairs:
		var entry: Array = pair
		var key_label := label(str(entry[0]), 11, key_color)
		key_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		grid.add_child(key_label)
		var missing: bool = entry.size() < 2 or entry[1] == null
		var text := "—" if missing else str(entry[1])
		var value_color: Color = SystemUIStyle.DIM if missing else SystemUIStyle.TEXT
		if entry.size() > 2 and entry[2] != null:
			value_color = entry[2]
		var value_label := label(text, value_size, value_color)
		value_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		grid.add_child(value_label)
	return grid


## 统计表。headers 为表头；rows 的每个元素是与 headers 等长的数组；
## weights 为列宽权重（不传则均分）。单元格值为 null 时渲染 "—"。
static func table(parent: Node, headers: Array, rows: Array, weights: Array = [],
		header_color: Color = SystemUIStyle.MUTED) -> VBoxContainer:
	var holder := VBoxContainer.new()
	holder.add_theme_constant_override("separation", 0)
	holder.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(holder)
	if rows.is_empty():
		var empty := label("无数据", 12, SystemUIStyle.DIM)
		empty.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		holder.add_child(empty)
		return holder
	var effective := weights if weights.size() == headers.size() else _uniform(headers.size())
	holder.add_child(_row(headers, effective, 11, header_color, HEAD_BG, 6, true))
	for index in range(rows.size()):
		var row: Array = rows[index]
		var bg := Color(0, 0, 0, 0) if index % 2 == 0 else Color(1, 1, 1, 0.022)
		holder.add_child(_row(row, effective, 12, SystemUIStyle.TEXT, bg, 4, false))
	return holder


static func _row(cells: Array, weights: Array, font_size: int, color: Color, bg: Color,
		pad_v: int, header: bool) -> PanelContainer:
	var panel := PanelContainer.new()
	var style := SystemUIStyle.flat(bg, 4)
	style.content_margin_left = 8
	style.content_margin_right = 8
	style.content_margin_top = pad_v
	style.content_margin_bottom = pad_v
	panel.add_theme_stylebox_override("panel", style)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	panel.add_child(row)
	for index in range(cells.size()):
		var missing: bool = cells[index] == null
		var text := "—" if missing else str(cells[index])
		var cell := label(text, font_size, SystemUIStyle.DIM if missing else color)
		cell.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		cell.size_flags_stretch_ratio = float(weights[index])
		cell.clip_text = true
		if header:
			cell.text = text
		row.add_child(cell)
	return panel


static func _uniform(count: int) -> Array:
	var out: Array = []
	for _i in range(count):
		out.append(1.0)
	return out


## 占比条。ratio 为 null 时整条置灰并显示 "—"。
static func bar(parent: Node, name_text: String, ratio: Variant, value_text: String = "",
		color: Color = SystemUIStyle.CYAN, name_width: int = 132) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(row)
	var name_label := label(name_text, 12, SystemUIStyle.TEXT)
	name_label.custom_minimum_size = Vector2(name_width, 0)
	name_label.clip_text = true
	row.add_child(name_label)

	var track := ProgressBar.new()
	track.custom_minimum_size = Vector2(0, 14)
	track.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	track.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	track.show_percentage = false
	track.max_value = 1.0
	track.add_theme_stylebox_override("background", SystemUIStyle.flat(Color("#0a181f"), 3,
		SystemUIStyle.LINE_SOFT, 1))
	if ratio == null:
		track.value = 0.0
		track.add_theme_stylebox_override("fill", SystemUIStyle.flat(
			Color(SystemUIStyle.DIM.r, SystemUIStyle.DIM.g, SystemUIStyle.DIM.b, 0.25), 3))
	else:
		track.value = clampf(float(ratio), 0.0, 1.0)
		track.add_theme_stylebox_override("fill", SystemUIStyle.flat(color, 3))
	row.add_child(track)

	var value_label := label(value_text if not value_text.is_empty() else "—", 12,
		SystemUIStyle.DIM if ratio == null else SystemUIStyle.TEXT)
	value_label.custom_minimum_size = Vector2(112, 0)
	value_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	row.add_child(value_label)
	return row


## 小徽标（胜负 / DEMO / Hermes 状态）。
static func chip(text: String, accent: Color, filled := false) -> Label:
	var node := Label.new()
	node.text = text
	node.add_theme_font_size_override("font_size", 11)
	node.add_theme_color_override("font_color",
		Color("#07131b") if filled else accent)
	node.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var style := SystemUIStyle.flat(
		Color(accent.r, accent.g, accent.b, 0.95) if filled else Color(accent.r, accent.g, accent.b, 0.14),
		4, Color(accent.r, accent.g, accent.b, 0.85), 1)
	style.content_margin_left = 7
	style.content_margin_right = 7
	style.content_margin_top = 2
	style.content_margin_bottom = 2
	node.add_theme_stylebox_override("normal", style)
	node.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	return node


## 自动换行的徽标行。
static func chips(parent: Node, items: Array, separation: int = 6) -> HFlowContainer:
	var flow := HFlowContainer.new()
	flow.add_theme_constant_override("h_separation", separation)
	flow.add_theme_constant_override("v_separation", separation)
	flow.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(flow)
	for item in items:
		var entry: Array = item
		flow.add_child(chip(str(entry[0]), entry[1] if entry.size() > 1 else SystemUIStyle.CYAN,
			entry.size() > 2 and bool(entry[2])))
	return flow


static func divider(parent: Node, color: Color = SystemUIStyle.LINE_SOFT) -> void:
	var line := ColorRect.new()
	line.color = color
	line.custom_minimum_size = Vector2(0, 1)
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(line)


## 缺失说明：把"这里为什么是 —"讲清楚，而不是让玩家自己猜。
static func missing_note(parent: Node, paths: Array, limit: int = 8) -> void:
	if paths.is_empty():
		return
	var shown := PackedStringArray()
	for index in range(mini(limit, paths.size())):
		shown.append(str(paths[index]))
	var text := "本页缺失 %d 项数据（%s%s）" % [
		paths.size(), "、".join(shown), "…" if paths.size() > limit else "",
	]
	var note := label(text, 11, SystemUIStyle.AMBER)
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	note.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(note)


## 一行"标签 + 数值 + 单位"的紧凑指标块，用于总览顶部那排大数字。
static func metric(parent: Node, caption: String, value_text: String, unit: String,
		accent: Color = SystemUIStyle.CYAN) -> PanelContainer:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", surface(SUB_BG, Color(accent.r, accent.g, accent.b, 0.5), 1,
		8, 12, 8))
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 1)
	panel.add_child(box)
	var caption_label := label(caption, 11, SystemUIStyle.MUTED)
	caption_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(caption_label)
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 4)
	box.add_child(row)
	row.add_child(label(value_text, 18, accent))
	if not unit.is_empty():
		var unit_label := label(unit, 11, SystemUIStyle.DIM)
		unit_label.size_flags_vertical = Control.SIZE_SHRINK_END
		row.add_child(unit_label)
	return panel


## 滚动容器。**默认 AUTO(1)**：内容不溢出时不显示滚动条，溢出才出现。
static func scroll(parent: Node, name: String = "Scroll") -> ScrollContainer:
	var scroll_node := ScrollContainer.new()
	scroll_node.name = name
	scroll_node.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	scroll_node.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll_node.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll_node.size_flags_vertical = Control.SIZE_EXPAND_FILL
	parent.add_child(scroll_node)
	return scroll_node


## 在一层"内容高度自适应、宽度撑满"的 VBox 里排内容（放进 ScrollContainer 用）。
static func column(parent: Node, separation: int = 10) -> VBoxContainer:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", separation)
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(box)
	return box
