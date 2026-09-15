class_name ProductionQueuePanel
extends PanelContainer

## 生产队列区（游戏内右侧生产栏）——**纯展示层 + 只读**：
## 不写任何玩法状态（不 produce / 不 cancel / 不改资源），
## "取消"与"清空"只把点击**回调给调用方**（context["cancel_callable"]）。
##
## ============================ 数据来源 ============================
##
## · 生产建筑：context["producers"] 优先；没给就从 player 的直接子节点里找
##   `"production_queue" in unit` 的（与 Match.gd:422 / :474 的单位挂载层级一致，
##   Structure.gd:24 声明了 @onready var production_queue）。
## · 队列元素：`unit.production_queue.get_elements()` → Array[ProductionQueueElement]
##   （source/match/units/traits/ProductionQueue.gd:8-24）：
##     item_id / unit_prototype / required_work / completed_work / state
##     progress()      = completed_work / required_work        （0..1）
##     time_total      = required_work / 60.0                   （秒）
##     time_left       = (required_work - completed_work)/60.0  （秒）
##   ⚠ **队列权威在 C#，GDScript 是只读镜像** ⇒ 本文件只读不写。
## · 队列上限：config/balance/demo.balance.v1.json → unitTypes[].producer.queueLimit
##   （实测 4 座建筑都是 5）。拿不到就按 5 显示并**明确标注「默认」**。
##
## ============================ 尺寸纪律 ============================
##
## 右侧栏宽约 268px 且极挤，本组件高度**硬约束 ≤ 72px**：
##   · 面板内边距 4×2；ScrollContainer 可视高 = min(HEADER_H + max_rows × ROW_H, 64)
##     ⇒ 默认 max_rows=2 时为 15 + 34 = 49，总高 57px。
##   · 只有一个 ScrollContainer，vertical_scroll_mode = SCROLL_MODE_AUTO
##     （**不用 SHOW_ALWAYS**：用户明确抱怨过常驻滚动条）；
##     队列为空时直接隐藏滚动容器，只留一行「生产队列空闲」，绝不出滚动条。
##   · 所有 Label 一律 **autowrap = OFF** + 按字符截断 + clip_text：
##     Label 开 autowrap 时 min height 按"当前宽度"算，首帧宽度为 0 ⇒
##     get_combined_minimum_size() 会爆到万 px 级（本项目已多次踩到）。
##
## ============================ 进度条 ============================
##
## 没用 ProductionTheme.bar()：它把 ColorRect 当 PanelContainer 的子节点，
## PanelContainer 会把子节点**拉伸填满**内容区（fit_child_in_rect），
## 于是 fill 的 custom_minimum_size 只影响最小尺寸、**画出来永远是满格**。
## 这里改用「PanelContainer(轨道) → HBox[ColorRect(填充) + 弹性空位]」自绘，
## 视觉语言仍与 ProductionTheme.bar() 一致（同色、同圆角、同高度口径）。

const CATALOG := preload("res://source/match/hud/production/ProductionCatalog.gd")
const THEME := preload("res://source/match/hud/production/ProductionTheme.gd")
const TIP := preload("res://source/match/hud/production/ProductionTooltip.gd")

const PANEL_WIDTH := 268.0
const PANEL_MAX_HEIGHT := 72.0
const PANEL_PADDING := 4.0
## 内容宽度刻意比面板窄 12px：给可能出现的竖向滚动条留位，避免横向溢出。
const CONTENT_WIDTH := PANEL_WIDTH - PANEL_PADDING * 2.0 - 12.0
const SCROLL_MAX_HEIGHT := PANEL_MAX_HEIGHT - PANEL_PADDING * 2.0

const DEFAULT_MAX_ROWS := 2
const ROW_H := 17.0
const HEADER_H := 15.0

const ICON_BOX := 14.0
const BAR_WIDTH := 54.0
const BAR_H := 6.0
const TIME_COLUMN := 28.0
const POS_COLUMN := 16.0
const CANCEL_W := 26.0
const CLEAR_W := 34.0

const ICON_DIR_RA3 := "res://source/match/hud/ra3/icons"
const ICON_DIR_UI := "res://assets/ui/icons"

## 队列上限兜底值：与 C# Domain/Production/Production.cs:74 的默认值一致
## （也是 ProductionCatalog.QUEUE_LIMIT_DEFAULT 的取值）。
const QUEUE_LIMIT_DEFAULT := 5

var _body: VBoxContainer = null
var _scroll: ScrollContainer = null
var _content: VBoxContainer = null
var _empty: Label = null
var _cancel_callable := Callable()

static var _limit_cache: Dictionary = {}


# ------------------------------------------------------------------ 公开 API

## 绑定一份上下文并重建队列区（面板每 0.4s 调一次，剩余时间 / 进度每次重算）。
##
## context 约定字段（**全部可缺**，缺了不报错）：
##   "player":          Node     —— 玩家节点，用它枚举生产建筑
##   "producers":       Array    —— 可选：直接给生产建筑列表（优先于 player 枚举）
##   "cancel_callable": Callable —— 取消回调。**本组件绝不自己取消**，只回调：
##                                  · 取消单项 → call(building, element)
##                                  · 清空整队 → call(building, null)
##   "max_rows":        int      —— 滚动区可视行数（默认 2）
func bind(context: Dictionary) -> void:
	_ensure_built()
	_cancel_callable = _extract_callable(context.get("cancel_callable", null))
	_render(context)
	# 每次 bind 都重建了行控件，必须重新打豁免标记：父级若调 SystemUIStyle.apply()
	# 会用 glass()（内边距 22/18）和 44px 按钮高覆盖掉本组件的紧凑样式，直接冲破 72px。
	SystemUIStyle.skip_subtree(self)


## 当前绑定的取消回调是否可用（不可用时"取消/清空"按钮会置灰，不假装能点）。
func can_cancel() -> bool:
	return _cancel_callable.is_valid()


# ------------------------------------------------------------------ 构建

func _ensure_built() -> void:
	if _body != null:
		return
	add_theme_stylebox_override("panel", _panel_style())
	custom_minimum_size = Vector2(PANEL_WIDTH, 0)

	_body = VBoxContainer.new()
	_body.add_theme_constant_override("separation", 0)
	add_child(_body)

	_scroll = ScrollContainer.new()
	# AUTO：内容放得下就不显示滚动条（用户明确抱怨过 SHOW_ALWAYS 的常驻条）。
	_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.custom_minimum_size = Vector2(
		CONTENT_WIDTH, HEADER_H + float(DEFAULT_MAX_ROWS) * ROW_H
	)
	_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_body.add_child(_scroll)

	_content = VBoxContainer.new()
	_content.custom_minimum_size = Vector2(CONTENT_WIDTH, 0)
	_content.add_theme_constant_override("separation", 1)
	_scroll.add_child(_content)

	_empty = SystemUIStyle.make_label("生产队列空闲", 10, THEME.MUTED)
	_empty.custom_minimum_size = Vector2(CONTENT_WIDTH, ROW_H)
	_empty.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_empty.visible = false
	_body.add_child(_empty)


func _ready() -> void:
	_ensure_built()


func _panel_style() -> StyleBoxFlat:
	var style := SystemUIStyle.rounded(THEME.BG_DEEP, THEME.LINE, 1, THEME.RADIUS)
	style.content_margin_left = PANEL_PADDING
	style.content_margin_right = PANEL_PADDING
	style.content_margin_top = PANEL_PADDING
	style.content_margin_bottom = PANEL_PADDING
	return style


# ------------------------------------------------------------------ 渲染

func _render(context: Dictionary) -> void:
	for child in _content.get_children():
		_content.remove_child(child)
		child.queue_free()

	var max_rows := DEFAULT_MAX_ROWS
	var raw_rows = context.get("max_rows", null)
	if raw_rows is int or raw_rows is float:
		max_rows = maxi(1, int(raw_rows))

	var groups := _collect_groups(context)
	var total := 0
	for raw_group in groups:
		total += ((raw_group as Dictionary)["elements"] as Array).size()

	if total == 0:
		_scroll.visible = false
		_empty.visible = true
		return

	_empty.visible = false
	_scroll.visible = true
	for raw_group in groups:
		var group: Dictionary = raw_group
		_content.add_child(_group_header(group))
		var elements: Array = group["elements"]
		var producer = group["producer"]
		for index in elements.size():
			var element = elements[index]
			if not _valid_object(element):
				continue
			_content.add_child(_item_row(element, index, producer))

	# 可视高度卡在预算内：默认 2 行 → 15 + 34 = 49px，加内边距总高 57px ≤ 72px。
	var view_h := minf(HEADER_H + float(max_rows) * ROW_H, SCROLL_MAX_HEIGHT)
	_scroll.custom_minimum_size = Vector2(CONTENT_WIDTH, view_h)


## 按建筑分组：只收**有内容**的生产建筑；一座都没有就交给"生产队列空闲"空状态。
func _collect_groups(context: Dictionary) -> Array:
	var groups: Array = []
	for producer in _producers_of(context):
		if not _valid(producer):
			continue
		if not ("production_queue" in producer):
			continue
		var queue = producer.get("production_queue")
		if not _valid_object(queue):
			continue
		if not queue.has_method("get_elements"):
			continue
		var raw_elements = queue.get_elements()
		if not (raw_elements is Array):
			continue
		var elements: Array = []
		for element in (raw_elements as Array):
			if _valid_object(element):
				elements.append(element)
		if elements.is_empty():
			continue
		groups.append({
			"producer": producer,
			"elements": elements,
			"limit": _queue_limit_of(producer),
		})
	return groups


# ------------------------------------------------------------------ 分组小标题

func _group_header(group: Dictionary) -> Control:
	var producer = group["producer"]
	var elements: Array = group["elements"]
	var limit: Dictionary = group["limit"]

	var row := HBoxContainer.new()
	row.custom_minimum_size = Vector2(CONTENT_WIDTH, HEADER_H)
	row.add_theme_constant_override("separation", 4)
	row.clip_contents = true

	var mark := ColorRect.new()
	mark.color = THEME.CYAN
	mark.custom_minimum_size = Vector2(3, 11)
	mark.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	mark.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(mark)

	# 建筑显示名：优先 ProductionCatalog 的真实配置文案，退化到场景文件名 / 节点名。
	var name_label := SystemUIStyle.make_label(_producer_name(producer), 9, THEME.TEXT)
	name_label.clip_text = true
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(name_label)

	var count := SystemUIStyle.make_label(
		"%d/%d" % [elements.size(), int(limit["limit"])], 9, THEME.AMBER
	)
	count.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(count)

	if bool(limit["fallback"]):
		# 读不到配置上限时**必须标注**，不让用户以为 5 是这座建筑的真实上限。
		var tag := SystemUIStyle.make_label("默认", 8, THEME.DIM)
		tag.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		tag.tooltip_text = (
			"读不到该建筑的 producer.queueLimit 配置，按默认值 %d 显示" % QUEUE_LIMIT_DEFAULT
		)
		row.add_child(tag)

	var clear := _small_button("清空", THEME.MUTED, CLEAR_W)
	clear.tooltip_text = "清空「%s」的全部生产项（通过 cancel_callable 回调，第二个参数为 null）" % _producer_name(
		producer
	)
	clear.disabled = not can_cancel()
	if can_cancel():
		clear.pressed.connect(_on_clear_pressed.bind(producer))
	row.add_child(clear)

	return row


# ------------------------------------------------------------------ 队列行

func _item_row(element, index: int, producer) -> Control:
	var entry := _entry_for_element(element)
	var state := _state_of_element(element)
	var accent := _accent_for_state(state)

	var row := HBoxContainer.new()
	row.custom_minimum_size = Vector2(CONTENT_WIDTH, ROW_H)
	row.add_theme_constant_override("separation", 3)
	row.clip_contents = true
	row.tooltip_text = "队列第 %d 位 · 状态 %s · id %s" % [
		index + 1, state if not state.is_empty() else "未知", _item_id_of(element)
	]

	row.add_child(_icon_control(entry, element))

	var name_label := SystemUIStyle.make_label(_element_name(entry, element), 9, THEME.TEXT)
	name_label.clip_text = true
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(name_label)

	var position := SystemUIStyle.make_label("#%d" % (index + 1), 8, THEME.DIM)
	position.custom_minimum_size = Vector2(POS_COLUMN, 0)
	position.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(position)

	row.add_child(_progress_control(_progress_of(element), accent))

	var time_text: String = _time_left_text(element)
	var time_label := SystemUIStyle.make_label(time_text, 9, accent)
	time_label.custom_minimum_size = Vector2(TIME_COLUMN, 0)
	time_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	time_label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	time_label.tooltip_text = "剩余时间（秒，保留 1 位）：required_work - completed_work 再 / 60"
	row.add_child(time_label)

	var cancel := _small_button("取消", THEME.RED, CANCEL_W)
	cancel.tooltip_text = "取消这一项（通过 cancel_callable 回调给调用方执行，本面板不自己取消）"
	cancel.disabled = not can_cancel()
	if can_cancel():
		cancel.pressed.connect(_on_cancel_pressed.bind(producer, element))
	row.add_child(cancel)

	return row


## 进度条：PanelContainer(轨道) + HBox[ColorRect(填充) + 弹性空位]。
## 见文件头"进度条"一节：这样填充宽度才真的按 progress 走。
func _progress_control(value: float, accent: Color) -> Control:
	var track := PanelContainer.new()
	track.custom_minimum_size = Vector2(BAR_WIDTH, BAR_H)
	track.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	track.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if value < 0.0:
		track.tooltip_text = "进度未知（该队列元素没有 progress 数据，画空轨而不是 0%）"
	else:
		track.tooltip_text = "进度 %.0f%%" % (clampf(value, 0.0, 1.0) * 100.0)
	track.add_theme_stylebox_override(
		"panel", SystemUIStyle.flat(Color(0.024, 0.063, 0.086, 0.9), 2)
	)

	var line := HBoxContainer.new()
	line.add_theme_constant_override("separation", 0)
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if value >= 0.0:
		var fill := ColorRect.new()
		fill.color = accent
		fill.custom_minimum_size = Vector2(BAR_WIDTH * clampf(value, 0.0, 1.0), 0)
		fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
		line.add_child(fill)
	var rest := Control.new()
	rest.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rest.mouse_filter = Control.MOUSE_FILTER_IGNORE
	line.add_child(rest)

	track.add_child(line)
	return track


func _icon_control(entry: Dictionary, element) -> Control:
	var texture := _icon_texture(entry, element)
	if texture != null:
		var rect := TextureRect.new()
		rect.texture = texture
		rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		rect.custom_minimum_size = Vector2(ICON_BOX, ICON_BOX)
		rect.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		return rect
	# 图标缺失（无内嵌图标 / 文件不存在）→ 降级成首字文字，不画空框也不假装有图。
	var fallback := SystemUIStyle.make_label(_initial(entry, element), 8, THEME.DIM)
	fallback.custom_minimum_size = Vector2(ICON_BOX, 0)
	fallback.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	fallback.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	fallback.clip_text = true
	return fallback


## 图标纹理：目录 entry.icon（ProductionCatalog 已按
## source/match/hud/ra3/icons/<key>.png → assets/ui/icons/<PascalCase>.png 的顺序找过）
## → 再用 unit_prototype 的场景名反查一次。**每一步都过 ResourceLoader.exists() 守卫**，
## 缺图返回 null 由调用方降级成文字（绝不 load() 一个不存在的路径）。
static func _icon_texture(entry: Dictionary, element) -> Texture2D:
	var raw = entry.get("icon", null)
	if raw is String:
		var path := str(raw)
		if not path.is_empty() and ResourceLoader.exists(path):
			var loaded := load(path)
			if loaded is Texture2D:
				return loaded
	var scene := _prototype_path(element)
	if not scene.is_empty():
		var key := scene.get_file().get_basename().to_snake_case()
		for candidate in [
			"%s/%s.png" % [ICON_DIR_RA3, key],
			"%s/%s.png" % [ICON_DIR_UI, _pascal_case(key)],
		]:
			var candidate_path := str(candidate)
			if ResourceLoader.exists(candidate_path):
				var loaded := load(candidate_path)
				if loaded is Texture2D:
					return loaded
	return null


static func _pascal_case(value: String) -> String:
	var out := ""
	for part in value.split("_", false):
		var piece := str(part)
		if piece.is_empty():
			continue
		out += piece.substr(0, 1).to_upper() + piece.substr(1)
	return out


## 一个很小的按钮：**不能用 SystemUIStyle.make_button**（它把最小高度顶到 44px，
## 一行只有 17px），这里自己套三态样式并把内边距压到最小。
func _small_button(text: String, accent: Color, width: float) -> Button:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size = Vector2(width, 14)
	button.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	button.add_theme_font_size_override("font_size", 9)
	button.focus_mode = Control.FOCUS_NONE
	button.add_theme_stylebox_override(
		"normal", _button_style(Color(0.043, 0.114, 0.153, 0.9), THEME.LINE_SOFT)
	)
	button.add_theme_stylebox_override(
		"hover", _button_style(Color(0.106, 0.290, 0.365, 0.95), accent)
	)
	button.add_theme_stylebox_override(
		"pressed", _button_style(Color(0.145, 0.376, 0.463, 0.98), accent)
	)
	button.add_theme_stylebox_override(
		"disabled", _button_style(Color(0.024, 0.063, 0.086, 0.7), THEME.LINE_SOFT)
	)
	button.add_theme_color_override("font_color", accent)
	button.add_theme_color_override("font_hover_color", Color.WHITE)
	button.add_theme_color_override("font_pressed_color", Color.WHITE)
	button.add_theme_color_override("font_disabled_color", THEME.DIM)
	return button


## SystemUIStyle.rounded() 的默认内边距是 16/10，必须压掉，否则按钮撑到 30px+。
func _button_style(bg: Color, border: Color) -> StyleBoxFlat:
	var style := SystemUIStyle.rounded(bg, border, 1, 3)
	style.content_margin_left = 2
	style.content_margin_right = 2
	style.content_margin_top = 0
	style.content_margin_bottom = 0
	return style


# ------------------------------------------------------------------ 点击 → 回调给调用方

## 取消单项：callable 的第一个参数是"建筑"，第二个是 element。
## 这两个值由 Callable.bind 在 connect 时就绑好，**不在这里现查**、更不自己调 cancel。
func _on_cancel_pressed(producer, element) -> void:
	if not _cancel_callable.is_valid():
		return
	_cancel_callable.call(producer, element)


func _on_clear_pressed(producer) -> void:
	if not _cancel_callable.is_valid():
		return
	# 约定：第二个参数传 null 表示"清空该建筑队列"。
	_cancel_callable.call(producer, null)


static func _extract_callable(raw) -> Callable:
	if raw is Callable:
		var callable: Callable = raw
		if callable.is_valid():
			return callable
	return Callable()


# ------------------------------------------------------------------ 元素读取

static func _state_of_element(element) -> String:
	if not _valid_object(element):
		return ""
	if not ("state" in element):
		return ""
	return str(element.get("state"))


static func _item_id_of(element) -> String:
	if not _valid_object(element):
		return ""
	if not ("item_id" in element):
		return ""
	return str(element.get("item_id"))


static func _progress_of(element) -> float:
	if not _valid_object(element):
		return -1.0
	if element.has_method("progress"):
		var raw = element.call("progress")
		if raw is int or raw is float:
			return clampf(float(raw), 0.0, 1.0)
	# 退化：自己按 required/completed 算（与 ProductionQueue.gd:23-24 同一公式）。
	var work := _work_pair(element)
	if work["ok"]:
		var required := float(work["required"])
		if required > 0.0:
			return clampf(float(work["completed"]) / required, 0.0, 1.0)
	# 拿不到就是"未知"，**不返回 0**（0 会被误读成"进度 0%"）。
	return -1.0


static func _time_left_text(element) -> String:
	if not _valid_object(element):
		return TIP.NO_VALUE
	var seconds = null
	if "time_left" in element:
		var raw = element.get("time_left")
		if raw is int or raw is float:
			seconds = float(raw)
	if seconds == null:
		var work := _work_pair(element)
		if work["ok"]:
			seconds = (float(work["required"]) - float(work["completed"])) / 60.0
	if seconds == null:
		# 没有时间数据就画 "—"，绝不用 0.0s 冒充"已完工"。
		return TIP.NO_VALUE
	return "%.1fs" % maxf(float(seconds), 0.0)


## required_work / completed_work 的安全读取（缺字段就 ok=false）。
static func _work_pair(element) -> Dictionary:
	if not _valid_object(element):
		return {"ok": false, "required": 0, "completed": 0}
	if not ("required_work" in element) or not ("completed_work" in element):
		return {"ok": false, "required": 0, "completed": 0}
	var required = element.get("required_work")
	var completed = element.get("completed_work")
	if not (required is int or required is float) or not (completed is int or completed is float):
		return {"ok": false, "required": 0, "completed": 0}
	return {"ok": true, "required": required, "completed": completed}


static func _prototype_path(element) -> String:
	if not _valid_object(element):
		return ""
	if not ("unit_prototype" in element):
		return ""
	var prototype = element.get("unit_prototype")
	if prototype is PackedScene:
		return (prototype as PackedScene).resource_path
	if prototype is String:
		return str(prototype)
	return ""


## 场景路径 → ProductionCatalog 条目；item_id 命中就用它（可能是 C# 的稳定 id，
## 也可能不是 unit_type_id，所以必须同时保留场景路径这条路）。
static func _entry_for_element(element) -> Dictionary:
	var item_id := _item_id_of(element)
	if not item_id.is_empty():
		var row := CATALOG.entry(item_id)
		if not row.is_empty():
			return row
	var scene := _prototype_path(element)
	if scene.is_empty():
		return {}
	for raw_category in CATALOG.categories():
		var category: Dictionary = raw_category
		for raw_item in CATALOG.entries(str(category.get("id", ""))):
			var item: Dictionary = raw_item
			if str(item.get("scene_path", "")) == scene:
				return item
	return {}


static func _element_name(entry: Dictionary, element) -> String:
	var display: String = TIP.fmt_text(entry.get("display_name", null))
	if display != TIP.NO_VALUE:
		return _truncate(display, 8)
	var item_id := _item_id_of(element)
	if not item_id.is_empty():
		return _truncate(item_id, 8)
	var scene := _prototype_path(element)
	if not scene.is_empty():
		return _truncate(scene.get_file().get_basename(), 8)
	return "未知单位"


static func _initial(entry: Dictionary, element) -> String:
	var name := _element_name(entry, element)
	return name.substr(0, 1) if not name.is_empty() else "?"


func _producer_name(producer) -> String:
	var type_id := _type_id_of_node(producer)
	var row: Dictionary = {}
	if not type_id.is_empty():
		row = CATALOG.entry(type_id)
	if not row.is_empty():
		var display: String = TIP.fmt_text(row.get("display_name", null))
		if display != TIP.NO_VALUE:
			return _truncate(display, 10)
	if _valid(producer):
		var scene := str((producer as Node).scene_file_path)
		if not scene.is_empty():
			return _truncate(scene.get_file().get_basename(), 10)
		return _truncate(str((producer as Node).name), 10)
	return "未知生产建筑"


## 生产建筑的 unit_type_id：Unit.gd:64 的属性优先，空则用场景路径反查目录条目。
static func _type_id_of_node(node) -> String:
	if not _valid(node):
		return ""
	if "unit_type_id" in node:
		var type_id := str(node.get("unit_type_id"))
		if not type_id.is_empty():
			return type_id
	return _type_id_by_scene(str((node as Node).scene_file_path))


static func _type_id_by_scene(scene_path: String) -> String:
	if scene_path.is_empty():
		return ""
	for raw_category in CATALOG.categories():
		var category: Dictionary = raw_category
		for raw_item in CATALOG.entries(str(category.get("id", ""))):
			var item: Dictionary = raw_item
			if str(item.get("scene_path", "")) == scene_path:
				return str(item.get("unit_id", ""))
	return ""


# ------------------------------------------------------------------ 生产建筑 / 上限

func _producers_of(context: Dictionary) -> Array:
	var out: Array = []
	var raw = context.get("producers", null)
	if raw is Array and not (raw as Array).is_empty():
		for item in (raw as Array):
			if _valid(item):
				out.append(item)
		return out
	var player = context.get("player", null)
	if _valid(player):
		for child in (player as Node).get_children():
			if not _valid(child):
				continue
			if "production_queue" in child:
				out.append(child)
	return out


## 队列上限：读 config/balance/demo.balance.v1.json 的 unitTypes[].producer.queueLimit。
## 读不到 → QUEUE_LIMIT_DEFAULT 且 fallback=true（UI 会标「默认」）。
##
## ⚠ 这本来该由 ProductionCatalog 提供，但它只暴露了私有的 _queue_limit_for，
## 公开 API 里没有上限查询（见汇报）。这里按用户给的路径自己读一次。
static func _queue_limit_of(producer) -> Dictionary:
	var type_id := _type_id_of_node(producer)
	var limits := _queue_limits()
	if not type_id.is_empty() and limits.has(type_id):
		return {"limit": int(limits[type_id]), "fallback": false}
	return {"limit": QUEUE_LIMIT_DEFAULT, "fallback": true}


static func _queue_limits() -> Dictionary:
	if not _limit_cache.is_empty():
		return _limit_cache
	var config := _load_json(_balance_config_path())
	var limits: Dictionary = {}
	for raw_type in _array_of(config.get("unitTypes", null)):
		if not (raw_type is Dictionary):
			continue
		var row: Dictionary = raw_type
		var producer = row.get("producer", null)
		if not (producer is Dictionary):
			continue
		var id := str(row.get("id", ""))
		if id.is_empty():
			continue
		limits[id] = int((producer as Dictionary).get("queueLimit", QUEUE_LIMIT_DEFAULT))
	# 读不到就**不写缓存**，下次调用重试（避免把一次失败永久固化）。
	if not limits.is_empty():
		_limit_cache = limits
	return limits


static func _load_json(path: String) -> Dictionary:
	if path.is_empty() or not FileAccess.file_exists(path):
		return {}
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {}
	var text := file.get_as_text()
	file.close()
	var parsed = JSON.parse_string(text)
	if parsed is Dictionary:
		return parsed
	return {}


## 允许 --balance-config= 覆盖，保证与 ProductionCatalog / C# 读同一份数据。
static func _balance_config_path() -> String:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--balance-config="):
			return argument.substr("--balance-config=".length())
	return CATALOG.BALANCE_CONFIG_DEFAULT


# ------------------------------------------------------------------ 小工具

## 队列状态 → 语义色（原始 state 串一定写进 Tooltip，不做隐藏转换）。
static func _accent_for_state(state: String) -> Color:
	var key := state.to_lower()
	if key.contains("produc") or key.contains("active") or key.contains("progress"):
		return THEME.CYAN
	if key.contains("done") or key.contains("complete") or key.contains("finish"):
		return THEME.GREEN
	if key.contains("queue") or key.contains("pending") or key.contains("wait"):
		return THEME.AMBER
	if key.is_empty():
		return THEME.MUTED
	return THEME.MUTED


## 按字符数截断 + 调用方配合 clip_text：让 Label 的 min width 与布局顺序无关。
static func _truncate(text: String, max_chars: int) -> String:
	if max_chars <= 0 or text.length() <= max_chars:
		return text
	return text.substr(0, max_chars) + "…"


static func _array_of(value) -> Array:
	if value is Array:
		return value
	return []


static func _valid(value) -> bool:
	if value == null:
		return false
	if not is_instance_valid(value):
		return false
	return value is Node


static func _valid_object(value) -> bool:
	if value == null:
		return false
	if not is_instance_valid(value):
		return false
	return value is Object
