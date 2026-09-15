class_name UnitDetailPanel
extends PanelContainer

## 选中单位 / 建筑的详情卡（游戏内右侧生产栏用）——**纯展示层**：
## 不写状态、不发信号、不碰玩法数据。
##
## 数据来源（优先级从高到低）：
##   1) **活的单位节点**（bind 传进来的 unit）：hp / hp_max / movement_speed /
##      attack_range / attack_damage / attack_interval / sight_range / attack_domains
##      —— 能读到就用活值（例如当前 HP），并给该行打 "实时" 角标；
##   2) **ProductionCatalog.entry()**：生产时间 / 资源消耗 / 能源消耗 /
##      角色定位 / 克制关系，以及活节点读不到时的属性兜底；
##   3) 都没有 → "—"。
##
## ============================ 两条硬规则 ============================
##
## 1) **游戏真实数据 与 Hermes 策略建议必须分区。**
##    · "真实单位数据"区：只有数值 / 结构化取值（含从 role 推导出的中文短标签）；
##    · "AI 建议"区：琥珀描边独立卡片，标题固定 "AI 建议"，
##      只放 Hermes 的自然语言建议 + 依据 + 生成时间 + 模型版本。
##    两边绝不混排：自然语言建议**不会**出现在属性列表里，属性值**不会**出现在建议区里。
##
## 2) **数值缺失一律 "—"，绝不显示 0 冒充真实值。**
##    ProductionCatalog 对项目里不存在的概念返回 null（不是 0）：
##    description / energy_cost / tech_level / unlock_condition / max_count /
##    adjutant_tags / stats.armor。本文件把它们一律画成 "—" 并打 "缺" 角标，
##    角标判据来自条目自己的 missing_fields。
##
## 活值读取全部走 _live_value()：`key in unit` 判存在 + `unit.get(key)`，
## 读不到就是 null，**绝不硬取属性名**（避免单位类型不同导致运行期报错）。
##
## 宽度：DETAIL_MIN_WIDTH=240，配合换行标签，实测 get_combined_minimum_size().x <= 288
## （即能塞进 Ra3Sidebar 的 288px 右侧栏）。

## 按路径 preload（而不是 class_name）：headless / 首次加载时 .godot 的全局类名缓存
## 未必收录新脚本；同时复用 ProductionTooltip 的 public static 格式化/词表，
## 保证「null → "—"」规则与 role/counters 中文词表只有一份。
const CATALOG := preload("res://source/match/hud/production/ProductionCatalog.gd")
const THEME := preload("res://source/match/hud/production/ProductionTheme.gd")
const TIP := preload("res://source/match/hud/production/ProductionTooltip.gd")

## 目标宽度：240 是"塞得进 288 栏"的下限，实际由父容器拉伸。
const DETAIL_MIN_WIDTH := 240.0
## 组件自身声明的可用宽度上限（供调用方对照，不强制裁剪）。
const DETAIL_MAX_WIDTH := 288.0
const ICON_BOX := 56.0
const KEY_COLUMN := 62.0
const PANEL_PADDING := 10.0
const BODY_WIDTH := DETAIL_MIN_WIDTH - PANEL_PADDING * 2.0
## 右侧角标（「缺」「推导」「实时」）预留宽度，避免折行时把角标挤出卡片。
const TAG_RESERVE := 40.0
## AI 建议子卡片（内边距 8）正文可用宽度。
const AI_INNER_WIDTH := BODY_WIDTH - 16.0

const TAG_MISSING := "缺"
const TAG_DERIVED := "推导"
const TAG_LIVE := "实时"
const TAG_AI_SCOPE := "策略建议·非属性"

## (caption, 活节点属性名, ProductionCatalog stats 键, 单位后缀)
## 活值读不到才退回 stats；两者都没有 → "—"。
const METRIC_ROWS := [
	["移动速度", "movement_speed", "speed", " m/s"],
	["攻击范围", "attack_range", "range", " m"],
	["伤害", "attack_damage", "damage", ""],
	["攻击间隔", "attack_interval", "attack_interval", " s"],
	["视野", "sight_range", "sight", " m"],
]

var _body: VBoxContainer = null
var _bound_unit: Node = null
var _last_unit_id := ""
var _last_context: Dictionary = {}


# ------------------------------------------------------------------ 公开 API

## 绑定一个单位 / 建筑节点。
##
## unit == null（或节点已失效）→ 显示空状态 "未选择单位"，不报错、不残留上一条数据。
## context 可选字段：
##   · 传给 ProductionCatalog.hermes_advice()：
##       "hermes_profile": Dictionary（不传则用 GrowthStore 画像快照）
##       "hermes_advice": Array（调用方提供的实时建议，source 会标成 live）
##   · "category": String —— 活节点查不到目录条目时的分类兜底（可留空）
func bind(unit: Node, context: Dictionary = {}) -> void:
	_ensure_built()
	_clear_body()
	_bound_unit = null
	_last_unit_id = ""
	# 记住 context：refresh() 要按同一份上下文重读活值。
	_last_context = context.duplicate(true)

	if not _valid(unit):
		_build_empty_state()
		return

	_bound_unit = unit
	var item := _entry_for_unit(unit)
	_last_unit_id = str(item.get("unit_id", ""))

	_body.add_child(_header(unit, item))
	_body.add_child(_paragraph(_description_text(item), 11, THEME.MUTED))
	_body.add_child(_divider())
	_body.add_child(_section_title("真实单位数据", THEME.CYAN))
	_body.add_child(_metrics(unit, item))
	_body.add_child(_data_note(item))
	_body.add_child(_divider())
	_body.add_child(_ai_block(context))


## 清空为 "未选择单位" 空状态。
func clear() -> void:
	_ensure_built()
	_clear_body()
	_bound_unit = null
	_last_unit_id = ""
	_build_empty_state()


## 重新读一遍活单位的当前值（HP 这类会变的属性需要它）。
##
## ⚠ 必须先判有效性：`bind(unit: Node, ...)` 的参数是**强类型 Node**，
## 传一个"已 free 的实例"进去会在运行期直接报
## `Invalid type in function 'bind' ... (previously freed) is not a subclass of ...`。
## 所以单位阵亡后 refresh() 只能转成 clear()（空状态），不能把它再喂给 bind()。
func refresh() -> void:
	if not _valid(_bound_unit):
		clear()
		return
	bind(_bound_unit, _last_context)


## 当前绑定的单位是否仍然有效。
func has_unit() -> bool:
	return _valid(_bound_unit)


## 当前绑定的条目 id（未绑定或查不到目录条目时为空串）。
func bound_unit_id() -> String:
	return _last_unit_id


# ------------------------------------------------------------------ 构建

func _ensure_built() -> void:
	if _body != null:
		return
	add_theme_stylebox_override("panel", _panel_style())
	custom_minimum_size = Vector2(DETAIL_MIN_WIDTH, 0)
	_body = VBoxContainer.new()
	_body.custom_minimum_size = Vector2(BODY_WIDTH, 0)
	_body.add_theme_constant_override("separation", 6)
	add_child(_body)


func _ready() -> void:
	_ensure_built()


func _panel_style() -> StyleBoxFlat:
	var style := SystemUIStyle.rounded(THEME.BG_DEEP, THEME.LINE, 1, THEME.RADIUS)
	style.content_margin_left = PANEL_PADDING
	style.content_margin_right = PANEL_PADDING
	style.content_margin_top = PANEL_PADDING
	style.content_margin_bottom = PANEL_PADDING
	return style


func _clear_body() -> void:
	if _body == null:
		return
	for child in _body.get_children():
		_body.remove_child(child)
		child.queue_free()


func _build_empty_state() -> void:
	_body.add_child(_section_title("未选择单位", THEME.DIM))
	_body.add_child(
		_paragraph("在生产面板或战场上选中一个单位，这里会显示它的真实属性与 AI 建议。", 11, THEME.MUTED)
	)


# ------------------------------------------------------------------ 头部

func _header(unit, item: Dictionary) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	row.add_child(_icon_control(item, unit))

	var column := VBoxContainer.new()
	column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	column.add_theme_constant_override("separation", 2)

	var name_label := _wrapped_label(
		_unit_name(unit, item), 15, THEME.TEXT, BODY_WIDTH - ICON_BOX - 10.0
	)
	column.add_child(name_label)

	var subtitle := "%s · %s" % [
		TIP.category_name(str(item.get("category", ""))),
		TIP.role_label(item.get("role", null)),
	]
	column.add_child(_wrapped_label(subtitle, 11, THEME.MUTED, BODY_WIDTH - ICON_BOX - 10.0))

	if item.is_empty():
		# 查不到目录条目要明说，别让用户以为"所有属性都是未知"是单位本身的性质。
		column.add_child(
			_paragraph("ProductionCatalog 无此单位的条目：下面只剩活节点能读到的值。", 10, THEME.DIM)
		)
	row.add_child(column)
	return row


func _unit_name(unit, item: Dictionary) -> String:
	var display := TIP.fmt_text(item.get("display_name", null))
	if display != TIP.NO_VALUE:
		return display
	var raw_type = _live_value(unit, "unit_type_id")
	if raw_type is String and not (raw_type as String).is_empty():
		return str(raw_type)
	if unit is Node:
		var scene := str((unit as Node).scene_file_path)
		if not scene.is_empty():
			return scene.get_file().get_basename()
		return str((unit as Node).name)
	return TIP.NO_VALUE


func _description_text(item: Dictionary) -> String:
	# description 在 ProductionCatalog 里恒为 null（项目没有单位文字描述），
	# 所以这里走的就是"暂无描述"分支；**不编造**任何介绍文字。
	var text := TIP.fmt_text(item.get("description", null))
	if text == TIP.NO_VALUE:
		return "暂无描述"
	return text


# ------------------------------------------------------------------ 真实数据区

func _metrics(unit, item: Dictionary) -> Control:
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 8)
	grid.add_theme_constant_override("v_separation", 3)

	_metric(grid, "生命值", _hp_text(unit, item), _hp_is_live(unit), false, item, "stats.hp")
	# 护甲：全仓库没有"单位护甲"概念，stats.armor 恒为 null → "—"，不是 0。
	_metric(grid, "护甲", _metric_text(unit, null, item, "armor", ""), false, false, item, "stats.armor")
	for metric_row in METRIC_ROWS:
		var caption := str(metric_row[0])
		var live_key := str(metric_row[1])
		var stat_key := str(metric_row[2])
		var suffix := str(metric_row[3])
		var live = _live_value(unit, live_key)
		var live_used := live is int or live is float
		_metric(
			grid,
			caption,
			_metric_text(unit, live, item, stat_key, suffix),
			live_used,
			false,
			item,
			"stats.%s" % stat_key
		)

	_metric(grid, "生产时间", TIP.fmt_num(item.get("build_time", null), " s"), false, true, item, "build_time")
	_metric(grid, "资源消耗", TIP.cost_text(item.get("cost", null)), false, false, item, "cost")
	_metric(grid, "能源消耗", TIP.fmt_num(item.get("energy_cost", null)), false, false, item, "energy_cost")
	# 维护费用：ProductionCatalog 的 schema 里**根本没有**这个字段，也不是 0——
	# 项目没有"单位维护费/ upkeep"概念，所以画 "—" 并标注"无此字段"。
	_metric_no_field(grid, "维护费用")

	var role = item.get("role", null)
	_metric(grid, "角色定位", TIP.role_label(role), false, true, item, "role")
	_metric(
		grid,
		"克制关系",
		_counters_text(unit, item),
		false,
		true,
		item,
		"counters"
	)
	# 推荐使用场景：**只是 role 这个推导字段的中文化改写**（不是策略建议；
	# 策略建议只出现在下面的 AI 建议区）。
	_metric(grid, "推荐使用场景", _scenario_text(role), false, true, item, "role")
	return grid


func _hp_text(unit, item: Dictionary) -> String:
	var current = _live_value(unit, "hp")
	var maximum = _live_value(unit, "hp_max")
	if (current is int or current is float) and (maximum is int or maximum is float):
		return "%s / %s" % [TIP.fmt_num(current), TIP.fmt_num(maximum)]
	if current is int or current is float:
		return TIP.fmt_num(current)
	return TIP.fmt_num(TIP.stat_at(item, "hp"))


func _hp_is_live(unit) -> bool:
	var current = _live_value(unit, "hp")
	return current is int or current is float


## 活值优先、目录兜底、都没有 → "—"。live 参数由调用方先读好（便于判"是否实时"）。
func _metric_text(unit, live, item: Dictionary, stat_key: String, suffix: String) -> String:
	if live is int or live is float:
		return TIP.fmt_num(live, suffix)
	return TIP.fmt_num(TIP.stat_at(item, stat_key), suffix)


func _counters_text(unit, item: Dictionary) -> String:
	var domains = _live_value(unit, "attack_domains")
	if domains is Array and not (domains as Array).is_empty():
		return TIP.fmt_domains(domains)
	return TIP.fmt_domains(item.get("counters", null))


func _scenario_text(role) -> String:
	if not (role is String):
		return TIP.NO_VALUE
	var key := str(role)
	if TIP.ROLE_SCENARIOS.has(key):
		return str(TIP.ROLE_SCENARIOS[key])
	return TIP.NO_VALUE


## 一行属性：键 + 值 + 角标（实时 / 推导 / 缺）。
func _metric(
	grid: GridContainer,
	caption: String,
	value_text: String,
	live: bool,
	derived_hint: bool,
	item: Dictionary,
	missing_key: String
) -> void:
	var missing := TIP.is_missing(item, missing_key) and value_text == TIP.NO_VALUE
	var tag := ""
	var accent := THEME.DIM
	if missing:
		tag = TAG_MISSING
	elif live:
		tag = TAG_LIVE
		accent = THEME.GREEN
	elif derived_hint and TIP.is_derived(item, missing_key):
		tag = TAG_DERIVED
		accent = THEME.CYAN
	_add_metric(grid, caption, value_text, missing, tag, accent)


func _metric_no_field(grid: GridContainer, caption: String) -> void:
	_add_metric(grid, caption, TIP.NO_VALUE, true, "无此字段", THEME.DIM)


func _add_metric(
	grid: GridContainer,
	caption: String,
	value_text: String,
	missing: bool,
	tag: String,
	accent: Color
) -> void:
	var key_label := SystemUIStyle.make_label(caption, 11, THEME.MUTED)
	key_label.custom_minimum_size = Vector2(KEY_COLUMN, 0)
	grid.add_child(key_label)

	var holder := HBoxContainer.new()
	holder.add_theme_constant_override("separation", 4)
	holder.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var reserve := TAG_RESERVE if not tag.is_empty() else 0.0
	var value_label := _wrapped_label(
		value_text,
		11,
		THEME.DIM if missing else THEME.TEXT,
		maxf(BODY_WIDTH - KEY_COLUMN - 8.0 - reserve, 40.0)
	)
	holder.add_child(value_label)
	if not tag.is_empty():
		holder.add_child(_tag(tag, accent))
	grid.add_child(holder)


func _data_note(item: Dictionary) -> Control:
	var missing := TIP.string_list(item.get("missing_fields", null))
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 1)
	column.add_child(
		_paragraph(
			"「—」= 该项目配置中没有此数据（%d 项，源自 ProductionCatalog.missing_fields），"
			% missing.size()
			+ "不以 0 冒充真实数值。「实时」= 直接读自活单位节点。",
			10,
			THEME.DIM
		)
	)
	if not missing.is_empty():
		column.add_child(
			_paragraph("缺失字段：%s" % "、".join(PackedStringArray(missing)), 10, THEME.DIM)
		)
	var derived := TIP.string_list(item.get("derived_fields", null))
	if not derived.is_empty():
		column.add_child(
			_paragraph(
				"「推导」= ProductionCatalog 的派生值（%s；build_time = requiredWork/60，"
				% "、".join(PackedStringArray(derived))
				+ "role/counters 由配置结构机械映射），不是实测值。",
				10,
				THEME.DIM
			)
		)
	return column


# ------------------------------------------------------------------ AI 建议区（独立分区）

func _ai_block(context: Dictionary) -> Control:
	var advice := CATALOG.hermes_advice(_profile_from(context), context)
	var panel := PanelContainer.new()
	var style := SystemUIStyle.rounded(
		Color(0.055, 0.078, 0.094, 0.95), THEME.AMBER, 1, THEME.RADIUS
	)
	style.content_margin_left = 8
	style.content_margin_right = 8
	style.content_margin_top = 8
	style.content_margin_bottom = 8
	panel.add_theme_stylebox_override("panel", style)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 3)
	var title_row := HBoxContainer.new()
	title_row.add_theme_constant_override("separation", 6)
	title_row.add_child(_section_title("AI 建议", THEME.AMBER))
	title_row.add_child(_tag(TAG_AI_SCOPE, THEME.AMBER))
	box.add_child(title_row)

	if bool(advice.get("available", false)):
		for raw in TIP.advice_list(advice.get("recommendations", null)):
			var row: Dictionary = raw
			box.add_child(
				_paragraph("· %s" % TIP.fmt_text(row.get("title", null)), 11, THEME.TEXT, AI_INNER_WIDTH)
			)
			var reason := TIP.fmt_text(row.get("reason", null))
			if reason != TIP.NO_VALUE:
				box.add_child(_paragraph("    %s" % reason, 10, THEME.MUTED, AI_INNER_WIDTH))
	else:
		# 没有建议就写"暂无"，**绝不编造**一条看上去合理的建议。
		box.add_child(_paragraph("暂无 AI 建议", 11, THEME.MUTED, AI_INNER_WIDTH))

	box.add_child(
		_paragraph("依据：%s" % TIP.fmt_text(advice.get("basis", null)), 10, THEME.DIM, AI_INNER_WIDTH)
	)
	box.add_child(
		_paragraph(
			"来源 %s · 生成时间 %s · 模型版本 %s"
			% [
				TIP.source_label(advice.get("source", null)),
				TIP.fmt_text(advice.get("generated_at", null)),
				TIP.fmt_text(advice.get("model_version", null)),
			],
			10,
			THEME.DIM,
			AI_INNER_WIDTH
		)
	)
	panel.add_child(box)
	return panel


# ------------------------------------------------------------------ 小控件

func _section_title(text: String, accent: Color) -> Control:
	var holder := HBoxContainer.new()
	holder.add_theme_constant_override("separation", 6)
	var mark := ColorRect.new()
	mark.color = accent
	mark.custom_minimum_size = Vector2(3, 13)
	mark.mouse_filter = Control.MOUSE_FILTER_IGNORE
	holder.add_child(mark)
	holder.add_child(SystemUIStyle.make_label(text, 12, accent))
	return holder


func _divider() -> Control:
	var rule := ColorRect.new()
	rule.color = THEME.LINE_SOFT
	rule.custom_minimum_size = Vector2(0, 1)
	rule.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return rule


## 统一的正文 Label：**先用真实字体度量手动折行，再关掉 Label 的 autowrap**。
##
## 为什么非要自己折（2026-09-15 实测）：Label 开 autowrap 时最小高度按「当前宽度」算，
## 首次布局前宽度是 0 ⇒ 一个字占一行 ⇒ get_combined_minimum_size() 高度爆到 **9262px**
## （详情卡实测 240×9262）。手动折行后 min size 只取决于文本本身，与布局顺序无关。
func _paragraph(text: String, size: int, color: Color, width := -1.0) -> Control:
	return _wrapped_label(text, size, color, BODY_WIDTH if width <= 0.0 else width)


func _wrapped_label(text: String, size: int, color: Color, width: float) -> Label:
	var label := SystemUIStyle.make_label(text, size, color)
	label.autowrap_mode = TextServer.AUTOWRAP_OFF
	label.text = TIP.wrap_text(text, width, _font_for(label), size)
	return label


func _font_for(control: Control) -> Font:
	var font: Font = null
	if control.is_inside_tree():
		font = control.get_theme_font("font")
	if font == null:
		font = ThemeDB.fallback_font
	return font


func _tag(text: String, accent: Color) -> Control:
	var holder := PanelContainer.new()
	holder.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var style := SystemUIStyle.rounded(Color(0.043, 0.114, 0.153, 0.9), accent, 1, 3)
	style.content_margin_left = 4
	style.content_margin_right = 4
	style.content_margin_top = 0
	style.content_margin_bottom = 0
	holder.add_theme_stylebox_override("panel", style)
	holder.add_child(SystemUIStyle.make_label(text, 9, accent))
	return holder


func _icon_control(item: Dictionary, unit) -> Control:
	var frame := PanelContainer.new()
	frame.custom_minimum_size = Vector2(ICON_BOX, ICON_BOX)
	frame.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	var style := SystemUIStyle.rounded(Color(0.027, 0.063, 0.086, 0.95), THEME.LINE_SOFT, 1, THEME.RADIUS)
	style.content_margin_left = 3
	style.content_margin_right = 3
	style.content_margin_top = 3
	style.content_margin_bottom = 3
	frame.add_theme_stylebox_override("panel", style)
	var texture := _icon_texture(item, unit)
	if texture != null:
		var rect := TextureRect.new()
		rect.texture = texture
		rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		frame.add_child(rect)
	else:
		# 目录 icon 缺失时退到"按场景路径找同名图标"，再不行才画"无图"。
		var label := SystemUIStyle.make_label("无图", 10, THEME.DIM)
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		frame.add_child(label)
	return frame


func _icon_texture(item: Dictionary, unit) -> Texture2D:
	var raw = item.get("icon", null)
	if raw is String:
		var path := str(raw)
		if not path.is_empty() and ResourceLoader.exists(path):
			return load(path) as Texture2D
	if unit is Node:
		var scene := str((unit as Node).scene_file_path)
		if not scene.is_empty():
			var key := scene.get_file().get_basename().to_snake_case()
			var fallback := "res://source/match/hud/ra3/icons/%s.png" % key
			if ResourceLoader.exists(fallback):
				return load(fallback) as Texture2D
	return null


# ------------------------------------------------------------------ 活节点读取

## 目录条目：先按 unit_type_id 查，再按 scene_file_path 反查；查不到返回空 Dictionary。
static func _entry_for_unit(unit) -> Dictionary:
	var type_id := ""
	var raw_type = _live_value(unit, "unit_type_id")
	if raw_type is String:
		type_id = str(raw_type)
	if not type_id.is_empty():
		var row := CATALOG.entry(type_id)
		if not row.is_empty():
			return row
	var scene := ""
	if unit is Node:
		scene = str((unit as Node).scene_file_path)
	if scene.is_empty():
		return {}
	for raw_category in CATALOG.categories():
		var category: Dictionary = raw_category
		for raw_item in CATALOG.entries(str(category.get("id", ""))):
			var item: Dictionary = raw_item
			if str(item.get("scene_path", "")) == scene:
				return item
	return {}


## 从活单位节点读属性。属性不存在 / 节点失效 → null（**不硬取属性名**，不会报错）。
static func _live_value(unit, key: String) -> Variant:
	if not _valid(unit):
		return null
	if not (key in unit):
		return null
	return unit.get(key)


static func _valid(unit) -> bool:
	if unit == null:
		return false
	return is_instance_valid(unit)


static func _profile_from(context: Dictionary) -> Dictionary:
	var profile = context.get("hermes_profile", null)
	if profile is Dictionary:
		return profile
	return {}
