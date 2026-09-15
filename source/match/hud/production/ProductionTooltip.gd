class_name ProductionTooltip
extends PanelContainer

## 生产面板悬停提示（Tooltip）——**纯展示层**：不写状态、不发信号、不吃鼠标。
##
## 配对对象：Ra3Sidebar 的生产格子（hover 时调用 show_for()，leave 时 hide_tip()）。
## 数据来源：ProductionCatalog（唯一条目 / 状态 / AI 建议来源）
##          ProductionTheme（唯一视觉令牌，颜色与主菜单同源）
##
## ============================ 三条硬规则 ============================
##
## 1) **值缺失一律画 "—"，绝不把 null 当 0。**
##    ProductionCatalog 对项目里不存在的概念返回 null（不是 0），例如
##    description / energy_cost / tech_level / unlock_condition / max_count /
##    adjutant_tags / stats.armor。本文件所有取值都要过 fmt_num()/fmt_text()，
##    它们对 null 返回 NO_VALUE（"—"）。缺失的行会带一枚 "缺" 角标，
##    角标判据来自条目自己的 missing_fields（不是自己猜的）；
##    推导值（build_time / role / counters）带 "推导" 角标，判据来自 derived_fields。
##
## 2) **真实单位数据 与 Hermes AI 建议视觉分区。**
##    AI 建议独占一块琥珀色子卡片，标题固定 "AI 建议"，并附
##    source（cache/live/none）/ generated_at / model_version / basis。
##    available == false 时只写 "暂无 AI 建议"，**绝不编造任何建议文本**。
##    真实属性区里**不会**出现任何自然语言建议；建议区里**不会**出现属性值。
##
## 3) **定位：优先贴 anchor 左侧。** 放不下才依次退到「左上 / 上方 / 右侧 / 下方」。
##    任何被采纳的位置都必须同时满足：
##      · 不与 anchor_rect 相交（= 不遮住 anchor 所在的右侧生产面板区域）；
##      · 落在 viewport_size 内（留 EDGE_MARGIN 边距）。
##    规则实现在 _resolve_position()，纯计算部分抽成静态
##    resolve_position_for_size()，可以不建树直接单测。
##
## 快捷键约定：提示里**不把字母写进正文**。若调用方在 context 里给了 "hotkey"，
## 用 ProductionTheme.keycap() 渲染成键帽放在标题行。

## 用 preload 而不是 class_name 引用：headless/首次加载时 .godot 的全局类名缓存
## 不一定已经收录新脚本（ProductionTheme 当前就**不在** global_script_class_cache.cfg 里），
## 按路径 preload 与缓存无关，稳定得多。
const CATALOG := preload("res://source/match/hud/production/ProductionCatalog.gd")
const THEME := preload("res://source/match/hud/production/ProductionTheme.gd")

const NO_VALUE := "—"
const MIN_WIDTH := 304.0
## 定位与夹取时保留的屏幕边距。
const EDGE_MARGIN := 8.0
## 卡片与 anchor 之间的间隙。
const GAP := 8.0
const ICON_BOX := 42.0
## 正文列宽：把内层 VBox 钉死在 MIN_WIDTH - 2*面板内边距，换行标签才有确定的换行宽度。
const PANEL_PADDING := 14.0
const BODY_WIDTH := MIN_WIDTH - PANEL_PADDING * 2.0
## 属性行的键列宽度。
const KEY_COLUMN := 74.0
## 右侧角标（「缺」「推导」）预留宽度，避免折行时把角标挤出去。
const TAG_RESERVE := 34.0
## AI 建议子卡片的内边距与其正文可用宽度。
const AI_PADDING := 10.0
const AI_INNER_WIDTH := BODY_WIDTH - AI_PADDING * 2.0
## 属性值列可用宽度。
const VALUE_WIDTH := BODY_WIDTH - KEY_COLUMN - 8.0

## 真实数据区里要展示的关键属性：(stats 键, 中文名, 单位后缀)
const STAT_ROWS := [
	["hp", "生命值", ""],
	["speed", "移动速度", " m/s"],
	["range", "射程", " m"],
	["damage", "伤害", ""],
	["attack_interval", "攻击间隔", " s"],
	["sight", "视野", " m"],
]

## 角色定位（ProductionCatalog.role，机械推导）→ 中文短标签。
## **共享词表**：UnitDetailPanel 也 preload 本脚本复用这两个常量，避免两处分叉。
const ROLE_LABELS := {
	"production_structure": "生产建筑",
	"gatherer": "资源采集",
	"builder": "建造/维修",
	"multi_domain": "对地+对空",
	"anti_air": "对空",
	"anti_ground": "对地",
	"unarmed_mobile": "无武装机动",
}

## 角色定位 → 推荐使用场景（**只是 role 这个推导字段的中文化改写**，
## 不是策略建议；策略建议只出现在 AI 建议区）。
const ROLE_SCENARIOS := {
	"production_structure": "作为生产基地，为前线补充单位",
	"gatherer": "开采资源，维持经济",
	"builder": "建造与维修建筑",
	"multi_domain": "同时应对地面与空中目标",
	"anti_air": "拦截空中单位",
	"anti_ground": "打击地面单位",
	"unarmed_mobile": "非武装机动单位，需要护卫",
}

## 主武器 targetDomains → 中文（"能打什么"）。
const DOMAIN_LABELS := {
	"terrain": "地面",
	"air": "空中",
}

var _body: VBoxContainer = null
var _last_item: Dictionary = {}


# ------------------------------------------------------------------ 公开 API

## 显示某个生产条目的提示卡。
##
## item           ← ProductionCatalog.entry(unit_id) 的返回值（空 Dictionary 也接受，
##                  此时只画一行"无该条目的数据"，不画假卡片）。
## anchor_rect    ← 触发悬停的格子/按钮在**屏幕坐标**下的矩形。
## viewport_size  ← 视口尺寸（一般 get_viewport_rect().size）。
## context        ← 可选，透传给 ProductionCatalog.state_of() / hermes_advice()：
##                  { player, producer, queue_items, has_worker, queue_limit }
##                  额外支持两个 UI 侧键：
##                    "hermes_profile": Dictionary  → 直接指定画像（否则走 GrowthStore 快照）
##                    "hotkey": String              → 用键帽渲染的快捷键
func show_for(
	item: Dictionary, anchor_rect: Rect2, viewport_size: Vector2, context: Dictionary = {}
) -> void:
	_ensure_built()
	_clear_body()
	if item.is_empty():
		# 未知条目也要能解释：明说"没有该条目的数据"，而不是画一张全是 "—" 的卡。
		_body.add_child(_section_title("无该条目的数据", THEME.DIM))
		_body.add_child(
			_paragraph("ProductionCatalog.entry() 没有返回该 unit_id 的条目，无法展示属性。", THEME.MUTED)
		)
		_last_item = {}
		_finish_layout(anchor_rect, viewport_size)
		return

	_last_item = item.duplicate(true)
	_body.add_child(_header(item, context))
	_body.add_child(_divider())
	_body.add_child(_section_title("真实单位数据", THEME.CYAN))
	_body.add_child(_data_rows(item))
	_body.add_child(_missing_footer(item))
	_body.add_child(_divider())
	_body.add_child(_state_block(item, context))
	_body.add_child(_ai_block(context))
	_finish_layout(anchor_rect, viewport_size)


func hide_tip() -> void:
	visible = false
	_last_item = {}


func is_showing() -> bool:
	return visible


## 最近一次 show_for() 传入的条目（未显示时为空 Dictionary）。
func last_item() -> Dictionary:
	return _last_item.duplicate(true)


## 提示卡当前占据的屏幕矩形（放在 _resolve_position 之后才有意义）。
func tip_rect() -> Rect2:
	return Rect2(position, size)


# ------------------------------------------------------------------ 定位规则

## 硬规则入口：优先左侧 → 左上 → 上方 → 右侧 → 下方，取第一个
## 「不与 anchor_rect 相交且能塞进 viewport」的候选。
func _resolve_position(anchor_rect: Rect2, viewport_size: Vector2) -> Vector2:
	var minimum := get_combined_minimum_size()
	var want := Vector2(maxf(minimum.x, MIN_WIDTH), minimum.y)
	return resolve_position_for_size(want, anchor_rect, viewport_size)


## _resolve_position 的纯函数版本（无节点状态，可直接断言）。
##
## 候选顺序与判据（size 是卡片尺寸，margin = EDGE_MARGIN）：
##   1 左侧    x = anchor.left - GAP - size.x             接受条件 x >= margin
##   2 上方    x 夹进视口, y = anchor.top - GAP - size.y   接受条件 y >= margin
##   3 右侧    x = anchor.right + GAP                     接受条件 x + size.x <= vw - margin
##   4 下方    y = anchor.bottom + GAP                    接受条件 y + size.y <= vh - margin
## 1 的 x 使卡片右缘恒在 anchor 左缘之外 ⇒ 不会盖住右侧生产面板；
## 2/4 完全在 anchor 上方/下方 ⇒ 与 anchor 无交集；3 整块在 anchor 右侧。
## 四个候选全不满足（视口比卡片还小等退化情况）时，退化为「贴左 + 纵向夹取」，
## 宁可右溢出，也不左右同时溢出。
static func resolve_position_for_size(
	size: Vector2, anchor_rect: Rect2, viewport_size: Vector2
) -> Vector2:
	var left_x := anchor_rect.position.x - GAP - size.x
	var above_y := anchor_rect.position.y - GAP - size.y
	var below_y := anchor_rect.end.y + GAP
	var right_x := anchor_rect.end.x + GAP
	var clamped_y := _clamp_axis(anchor_rect.position.y, size.y, viewport_size.y)
	var clamped_x := _clamp_axis(anchor_rect.position.x, size.x, viewport_size.x)

	# 1) 左侧（首选）
	if left_x >= EDGE_MARGIN:
		return Vector2(left_x, clamped_y)
	# 2) 上方
	if above_y >= EDGE_MARGIN:
		return Vector2(clamped_x, above_y)
	# 3) 右侧
	if right_x + size.x <= viewport_size.x - EDGE_MARGIN:
		return Vector2(right_x, clamped_y)
	# 4) 下方
	if below_y + size.y <= viewport_size.y - EDGE_MARGIN:
		return Vector2(clamped_x, below_y)
	# 退化：贴左 + 纵向夹取。
	return Vector2(EDGE_MARGIN, clamped_y)


## 把 value 夹进 [EDGE_MARGIN, limit - EDGE_MARGIN - size]；
## 可用空间比 size 还小时返回 EDGE_MARGIN（贴起画）。
static func _clamp_axis(value: float, size: float, limit: float) -> float:
	var maximum := limit - EDGE_MARGIN - size
	if maximum < EDGE_MARGIN:
		return EDGE_MARGIN
	return clampf(value, EDGE_MARGIN, maximum)


# ------------------------------------------------------------------ 构建

func _ensure_built() -> void:
	if _body != null:
		return
	# 不吃鼠标：卡片压在格子上也不能影响格子点击。
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	clip_contents = false
	add_theme_stylebox_override("panel", _panel_style())
	_body = VBoxContainer.new()
	_body.custom_minimum_size = Vector2(BODY_WIDTH, 0)
	_body.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_body.add_theme_constant_override("separation", 6)
	add_child(_body)


func _ready() -> void:
	_ensure_built()


func _finish_layout(anchor_rect: Rect2, viewport_size: Vector2) -> void:
	# 先让 PanelContainer 收缩到内容尺寸（换行标签已在 _ensure_built 里钉死宽度）。
	reset_size()
	position = _resolve_position(anchor_rect, viewport_size)
	visible = true
	_ignore_mouse(self)


func _panel_style() -> StyleBoxFlat:
	var style := SystemUIStyle.rounded(THEME.BG_DEEP, THEME.LINE, 1, THEME.RADIUS)
	style.content_margin_left = PANEL_PADDING
	style.content_margin_right = PANEL_PADDING
	style.content_margin_top = 12
	style.content_margin_bottom = 12
	style.shadow_color = Color(0, 0, 0, 0.55)
	style.shadow_size = 8
	return style


func _clear_body() -> void:
	if _body == null:
		return
	for child in _body.get_children():
		_body.remove_child(child)
		child.queue_free()


## 递归把所有子节点设成不吃鼠标。
func _ignore_mouse(node: Node) -> void:
	if node is Control:
		(node as Control).mouse_filter = Control.MOUSE_FILTER_IGNORE
	for child in node.get_children():
		_ignore_mouse(child)


# ------------------------------------------------------------------ 头部

func _header(item: Dictionary, context: Dictionary) -> Control:
	var row := HBoxContainer.new()
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_theme_constant_override("separation", 10)
	row.add_child(_icon_control(item.get("icon", null)))

	var column := VBoxContainer.new()
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	column.add_theme_constant_override("separation", 2)

	var title_row := HBoxContainer.new()
	title_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	title_row.add_theme_constant_override("separation", 6)
	var name_label := _wrapped_label(
		fmt_text(item.get("display_name", null)), 15, THEME.TEXT, BODY_WIDTH - ICON_BOX - 10.0
	)
	title_row.add_child(name_label)
	# 快捷键统一走键帽，不把字母混进正文。
	var hotkey = context.get("hotkey", null)
	if hotkey is String and not (hotkey as String).is_empty():
		title_row.add_child(THEME.keycap(str(hotkey), THEME.AMBER, 16.0))
	column.add_child(title_row)

	var subtitle := "%s · %s" % [
		category_name(str(item.get("category", ""))),
		role_label(item.get("role", null)),
	]
	column.add_child(
		_wrapped_label(subtitle, 11, THEME.MUTED, BODY_WIDTH - ICON_BOX - 10.0)
	)

	row.add_child(column)
	return row


# ------------------------------------------------------------------ 真实数据区

func _data_rows(item: Dictionary) -> Control:
	var column := VBoxContainer.new()
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_theme_constant_override("separation", 3)

	column.add_child(
		_kv_row("资源消耗", cost_text(item.get("cost", null)), THEME.AMBER, is_missing(item, "cost"))
	)
	column.add_child(
		_kv_row(
			"能源消耗",
			fmt_num(item.get("energy_cost", null)),
			THEME.TEXT,
			is_missing(item, "energy_cost")
		)
	)
	column.add_child(
		_kv_row(
			"生产时间",
			fmt_num(item.get("build_time", null), " s"),
			THEME.TEXT,
			is_missing(item, "build_time"),
			is_derived(item, "build_time")
		)
	)
	for stat_row in STAT_ROWS:
		var key := str(stat_row[0])
		var caption := str(stat_row[1])
		var suffix := str(stat_row[2])
		column.add_child(
			_kv_row(
				caption,
				fmt_num(stat_at(item, key), suffix),
				THEME.TEXT,
				is_missing(item, "stats.%s" % key)
			)
		)
	# 护甲：全仓库没有"单位护甲"概念，stats.armor 恒为 null → 画 "—"，不画 0。
	column.add_child(
		_kv_row(
			"护甲",
			fmt_num(stat_at(item, "armor")),
			THEME.TEXT,
			is_missing(item, "stats.armor")
		)
	)
	column.add_child(
		_kv_row(
			"克制关系",
			fmt_domains(item.get("counters", null)),
			THEME.TEXT,
			is_missing(item, "counters"),
			is_derived(item, "counters")
		)
	)
	column.add_child(
		_kv_row(
			"解锁条件",
			fmt_text(item.get("unlock_condition", null)),
			THEME.TEXT,
			is_missing(item, "unlock_condition")
		)
	)
	column.add_child(
		_kv_row(
			"生产来源",
			fmt_text(source_caption(item)),
			THEME.TEXT,
			false
		)
	)
	return column


func _state_block(item: Dictionary, context: Dictionary) -> Control:
	var result := CATALOG.state_of(str(item.get("unit_id", "")), context)
	var state := str(result.get("state", THEME.STATE_READY))
	var column := VBoxContainer.new()
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_theme_constant_override("separation", 2)

	var caption_row := HBoxContainer.new()
	caption_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	caption_row.add_theme_constant_override("separation", 6)
	caption_row.add_child(_section_title("当前状态", THEME.state_color(state)))
	caption_row.add_child(_tag(THEME.state_label(state), THEME.state_color(state)))
	column.add_child(caption_row)

	# reason 是 ProductionCatalog 的原话，UI 不改写（含"未提供 xx：未知"这类诚实说明）。
	column.add_child(_paragraph(fmt_text(result.get("reason", null)), THEME.MUTED))

	var actions := string_list(result.get("available_actions", null))
	if not actions.is_empty():
		column.add_child(_paragraph("可用操作：%s" % "、".join(PackedStringArray(actions)), THEME.DIM))
	return column


func _missing_footer(item: Dictionary) -> Control:
	var missing := string_list(item.get("missing_fields", null))
	var derived := string_list(item.get("derived_fields", null))
	var lines: Array[String] = []
	if not missing.is_empty():
		lines.append(
			"缺失字段 %d 项：%s" % [missing.size(), "、".join(PackedStringArray(missing))]
		)
	if not derived.is_empty():
		lines.append("推导字段：%s" % "、".join(PackedStringArray(derived)))
	if lines.is_empty():
		return null
	var column := VBoxContainer.new()
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_theme_constant_override("separation", 1)
	for line in lines:
		column.add_child(_paragraph(line, THEME.DIM))
	column.add_child(
		_paragraph(
			"「—」= 该项目配置里没有此数据（源自 missing_fields），不以 0 冒充真实数值。",
			THEME.DIM
		)
	)
	return column


# ------------------------------------------------------------------ AI 建议区（独立分区）

## Hermes 建议区。与真实数据区**视觉上完全分开**：琥珀描边子卡片 + 固定标题 "AI 建议"。
func _ai_block(context: Dictionary) -> Control:
	var advice := CATALOG.hermes_advice(_profile_from(context), context)
	var panel := PanelContainer.new()
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var style := SystemUIStyle.rounded(
		Color(0.055, 0.078, 0.094, 0.95), THEME.AMBER, 1, THEME.RADIUS
	)
	style.content_margin_left = 10
	style.content_margin_right = 10
	style.content_margin_top = 8
	style.content_margin_bottom = 8
	panel.add_theme_stylebox_override("panel", style)

	var box := VBoxContainer.new()
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_theme_constant_override("separation", 3)
	var title_row := HBoxContainer.new()
	title_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	title_row.add_theme_constant_override("separation", 6)
	title_row.add_child(_section_title("AI 建议", THEME.AMBER))
	title_row.add_child(_tag("Hermes 策略建议，不是单位属性", THEME.AMBER))
	box.add_child(title_row)

	var available := bool(advice.get("available", false))
	if not available:
		_append(box, _paragraph("暂无 AI 建议", THEME.MUTED, AI_INNER_WIDTH))
	else:
		for raw in advice_list(advice.get("recommendations", null)):
			var row: Dictionary = raw
			var title := fmt_text(row.get("title", null))
			_append(box, _paragraph("· %s" % title, THEME.TEXT, AI_INNER_WIDTH))
			var reason := fmt_text(row.get("reason", null))
			if reason != NO_VALUE:
				_append(box, _paragraph("    %s" % reason, THEME.MUTED, AI_INNER_WIDTH))

	var basis := fmt_text(advice.get("basis", null))
	_append(box, _paragraph("依据：%s" % basis, THEME.DIM, AI_INNER_WIDTH))
	_append(
		box,
		_paragraph(
			"来源 %s · 生成时间 %s · 模型版本 %s"
			% [
				source_label(advice.get("source", null)),
				fmt_text(advice.get("generated_at", null)),
				fmt_text(advice.get("model_version", null)),
			],
			THEME.DIM,
			AI_INNER_WIDTH
		)
	)
	panel.add_child(box)
	return panel


# ------------------------------------------------------------------ 小控件

func _section_title(text: String, accent: Color) -> Control:
	var holder := HBoxContainer.new()
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
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


func _paragraph(text: String, color: Color, width := -1.0) -> Control:
	return _wrapped_label(text, 11, color, BODY_WIDTH if width <= 0.0 else width)


## 统一的正文 Label：**先用真实字体度量手动折行，再关掉 Label 自己的 autowrap**。
##
## 为什么非要自己折（2026-09-15 实测）：
##   Label 开了 autowrap 时，它的最小高度是按「当前宽度」算的，而首次 show_for() 之前
##   宽度是 0 ⇒ 一个字占一行 ⇒ get_combined_minimum_size() 高度爆到 **12651px**
##   （Tooltip 实测 304×12651，详情卡 240×9262），reset_size() 拿到的就是这坨假尺寸，
##   定位函数自然全错。手动折行后 min size 与布局顺序无关，show_for() 能同步定位。
func _wrapped_label(text: String, size: int, color: Color, width: float) -> Label:
	var label := SystemUIStyle.make_label(text, size, color)
	label.autowrap_mode = TextServer.AUTOWRAP_OFF
	label.text = wrap_text(text, width, _font_for(label), size)
	return label


func _font_for(control: Control) -> Font:
	var font: Font = null
	if control.is_inside_tree():
		font = control.get_theme_font("font")
	if font == null:
		font = ThemeDB.fallback_font
	return font


func _kv_row(
	caption: String,
	value: String,
	value_color: Color,
	missing: bool,
	derived: bool = false
) -> Control:
	var row := HBoxContainer.new()
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_theme_constant_override("separation", 8)

	var key_label := SystemUIStyle.make_label(caption, 12, THEME.MUTED)
	key_label.custom_minimum_size = Vector2(KEY_COLUMN, 0)
	row.add_child(key_label)

	var reserve := TAG_RESERVE if (missing or derived) else 0.0
	var value_label := _wrapped_label(
		value,
		12,
		THEME.DIM if missing else value_color,
		maxf(VALUE_WIDTH - reserve, 40.0)
	)
	row.add_child(value_label)

	if missing:
		row.add_child(_tag("缺", THEME.DIM))
	elif derived:
		row.add_child(_tag("推导", THEME.CYAN))
	return row


func _tag(text: String, accent: Color) -> Control:
	var holder := PanelContainer.new()
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	holder.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var style := SystemUIStyle.rounded(Color(0.043, 0.114, 0.153, 0.9), accent, 1, 3)
	style.content_margin_left = 4
	style.content_margin_right = 4
	style.content_margin_top = 0
	style.content_margin_bottom = 0
	holder.add_theme_stylebox_override("panel", style)
	holder.add_child(SystemUIStyle.make_label(text, 10, accent))
	return holder


func _icon_control(raw) -> Control:
	var frame := PanelContainer.new()
	frame.custom_minimum_size = Vector2(ICON_BOX, ICON_BOX)
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	frame.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	var style := SystemUIStyle.rounded(Color(0.027, 0.063, 0.086, 0.95), THEME.LINE_SOFT, 1, 3)
	style.content_margin_left = 2
	style.content_margin_right = 2
	style.content_margin_top = 2
	style.content_margin_bottom = 2
	frame.add_theme_stylebox_override("panel", style)
	var texture := _load_icon(raw)
	if texture != null:
		var rect := TextureRect.new()
		rect.texture = texture
		rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		frame.add_child(rect)
	else:
		# icon 缺失（missing_fields 会登记）→ 画"无图"，不放空白框假装有图。
		var label := SystemUIStyle.make_label("无图", 10, THEME.DIM)
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		frame.add_child(label)
	return frame


# -------------------------------------------------- 值格式化 / 展示词表（两组件共享）
#
# 这一节全部是 **public static**：UnitDetailPanel 也 preload 本脚本复用它们，
# 保证「null → "—"」的规则与 role/counters 的中文词表**只有一份**，不会两处分叉。
# （本次改动只允许新增这两个文件，所以共享层就落在先出现的 Tooltip 上。）

static func stat_at(item: Dictionary, key: String) -> Variant:
	var stats = item.get("stats", null)
	if not (stats is Dictionary):
		return null
	return (stats as Dictionary).get(key, null)


## 可整体断行保护字符集：这些字符组成的串（单位 id / 路径 / 数字）视为不可断的整块，
## 其余字符（CJK、全角标点）逐字可断。
const LATIN_RUN_CHARS := "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_./:+#-*@()[]{}<>=&\\|~^$"


## 按**真实字体度量**把文本折成每行不超过 width 像素的多行（返回带 \n 的文本）。
##
## 为什么要手动折：见 _wrapped_label() 的说明——Label 的 autowrap 会让最小高度依赖
## 「当前宽度」，首次布局前宽度为 0，min height 会爆成几万像素。
## 折行后配合 autowrap=OFF，Label 的 min size 就只取决于文本本身，与布局顺序无关。
static func wrap_text(text: String, width: float, font: Font, font_size: int) -> String:
	if text.is_empty() or width <= 1.0 or font == null or font_size <= 0:
		return text
	var lines: Array[String] = []
	for raw_line in text.split("\n"):
		_wrap_one_line(str(raw_line), width, font, font_size, lines)
	if lines.is_empty():
		return text
	return "\n".join(PackedStringArray(lines))


static func _wrap_one_line(
	line: String, width: float, font: Font, font_size: int, out: Array[String]
) -> void:
	if line.is_empty():
		out.append("")
		return
	var current := ""
	for raw_token in _wrap_tokens(line):
		var token := str(raw_token)
		if current.is_empty():
			# 行首不留空格。
			token = token.strip_edges(true, false)
			if token.is_empty():
				continue
		elif _text_width(current + token, font, font_size) <= width:
			current += token
			continue
		else:
			# 放不下：当前行落盘，本 token 另起一行。
			_flush_line(current, width, font, font_size, out)
			current = ""
			token = token.strip_edges(true, false)
			if token.is_empty():
				continue
		# 新行的第一个 token 自己就可能超宽（超长路径 / 无空格的西文串）→ 硬拆。
		current = _split_oversized(token, width, font, font_size, out)
	_flush_line(current, width, font, font_size, out)


## 落盘一行；这一行本身仍超宽时（超长 token 拼出来的）按像素硬拆。
static func _flush_line(
	line: String, width: float, font: Font, font_size: int, out: Array[String]
) -> void:
	var remaining := line.strip_edges(false, true)
	while _text_width(remaining, font, font_size) > width and remaining.length() > 1:
		var fit := _fit_length(remaining, width, font, font_size)
		out.append(remaining.substr(0, fit))
		remaining = remaining.substr(fit).strip_edges(true, false)
	if not remaining.is_empty():
		out.append(remaining)


## token 自己超宽时把前面的段落落盘，返回剩下的一段（留给后续 token 继续拼）。
static func _split_oversized(
	token: String, width: float, font: Font, font_size: int, out: Array[String]
) -> String:
	var remaining := token
	while _text_width(remaining, font, font_size) > width and remaining.length() > 1:
		var fit := _fit_length(remaining, width, font, font_size)
		out.append(remaining.substr(0, fit))
		remaining = remaining.substr(fit)
	return remaining


## 前缀长度：substr(0, n) 的像素宽度仍 <= width（n 至少 1，避免死循环）。
static func _fit_length(text: String, width: float, font: Font, font_size: int) -> int:
	var index := 1
	while index < text.length():
		if _text_width(text.substr(0, index + 1), font, font_size) > width:
			break
		index += 1
	return index


static func _wrap_tokens(line: String) -> Array[String]:
	var out: Array[String] = []
	var buffer := ""
	for index in line.length():
		var character := line[index]
		if character == " ":
			if not buffer.is_empty():
				out.append(buffer)
				buffer = ""
			out.append(" ")
		elif LATIN_RUN_CHARS.contains(character):
			buffer += character
		else:
			if not buffer.is_empty():
				out.append(buffer)
				buffer = ""
			out.append(character)
	if not buffer.is_empty():
		out.append(buffer)
	return out


static func _text_width(text: String, font: Font, font_size: int) -> float:
	return font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x


## 数值格式化：null / 非数值一律 "—"。整数去掉小数尾巴，小数保留 digits 位。
## **绝不**把 null 转成 0。
static func fmt_num(value, suffix := "", digits := 1) -> String:
	if value is int or value is float:
		var number := float(value)
		if is_equal_approx(number, roundf(number)) and absf(number - roundf(number)) < 0.05:
			return "%d%s" % [int(roundf(number)), suffix]
		return String.num(number, digits) + suffix
	if value is String and not (value as String).strip_edges().is_empty():
		return str(value)
	return NO_VALUE


static func fmt_text(value) -> String:
	if value is String:
		var text := str(value)
		return text if not text.strip_edges().is_empty() else NO_VALUE
	if value is PackedStringArray or value is Array:
		var parts := string_list(value)
		return "、".join(PackedStringArray(parts)) if not parts.is_empty() else NO_VALUE
	return NO_VALUE


## 克制关系（weapons[].targetDomains）→ 中文；空数组 = 真的打不了任何东西，
## 这是**真实结论**（配置声明无武器），仍然写 "—" 但要说明。
static func fmt_domains(raw) -> String:
	var parts: Array[String] = []
	for entry in string_list(raw):
		parts.append(domain_label(entry))
	if parts.is_empty():
		return NO_VALUE
	return "、".join(PackedStringArray(parts))


static func domain_label(domain: String) -> String:
	var key := domain.to_lower()
	if DOMAIN_LABELS.has(key):
		return str(DOMAIN_LABELS[key])
	return domain if not domain.is_empty() else NO_VALUE


static func cost_text(raw) -> String:
	if not (raw is Dictionary):
		return NO_VALUE
	var cost: Dictionary = raw
	var parts: Array[String] = []
	# 资源 A 是本项目唯一真实货币（Ra3Sidebar 的造价文案同样是只显示 A）。
	parts.append("资源 %d" % int(cost.get("resource_a", 0)))
	var second := int(cost.get("resource_b", 0))
	if second > 0:
		parts.append("资源B %d" % second)
	return "，".join(PackedStringArray(parts))


static func role_label(raw) -> String:
	if not (raw is String):
		return NO_VALUE
	var key := str(raw)
	if key.is_empty():
		return NO_VALUE
	if ROLE_LABELS.has(key):
		return str(ROLE_LABELS[key])
	# 未知 role 原样显示（不翻译成猜的语义）。
	return key


## 生产来源：place 模式是工人建造，否则是生产建筑。
static func source_caption(item: Dictionary) -> Variant:
	var source = item.get("production_source", null)
	if not (source is Dictionary):
		return null
	var row: Dictionary = source
	if str(row.get("mode", "produce")) == "place":
		var builders := string_list(row.get("builder_unit_type_ids", null))
		return "%s 建造（蓝图放置）" % ("、".join(PackedStringArray(builders))) if not builders.is_empty() else "蓝图放置（建造者未知）"
	return row.get("producer_caption", null)


static func source_label(raw) -> String:
	var key := str(raw)
	if key == "cache":
		return "缓存快照(cache)"
	if key == "live":
		return "实时(live)"
	return "无数据(none)"


static func category_name(category_id: String) -> String:
	for row in CATALOG.categories():
		var category: Dictionary = row
		if str(category.get("id", "")) == category_id:
			var name := str(category.get("name", ""))
			return name if not name.is_empty() else category_id
	return category_id if not category_id.is_empty() else NO_VALUE


## 条目标记：判断某个 key 是否被 ProductionCatalog 登记为缺失 / 推导。
static func is_missing(item: Dictionary, key: String) -> bool:
	return string_list(item.get("missing_fields", null)).has(key)


static func is_derived(item: Dictionary, key: String) -> bool:
	return string_list(item.get("derived_fields", null)).has(key)


## PackedStringArray 没有 join()，而且它是值类型；统一先转 Array[String] 再拼。
static func string_list(raw) -> Array[String]:
	var out: Array[String] = []
	if raw is PackedStringArray:
		var packed: PackedStringArray = raw
		for entry in packed:
			out.append(str(entry))
	elif raw is Array:
		var array: Array = raw
		for entry in array:
			out.append(str(entry))
	return out


static func advice_list(raw) -> Array:
	if raw is Array:
		return raw
	return []


static func _profile_from(context: Dictionary) -> Dictionary:
	var profile = context.get("hermes_profile", null)
	if profile is Dictionary:
		return profile
	return {}


static func _load_icon(raw) -> Texture2D:
	if not (raw is String):
		return null
	var path := str(raw)
	if path.is_empty() or not ResourceLoader.exists(path):
		return null
	return load(path) as Texture2D


# ------------------------------------------------------------------ 内部

## 往容器追加一个子节点（顺带跳过 null，避免空块占位）。
func _append(parent: Node, child: Node) -> void:
	if child == null:
		return
	parent.add_child(child)
