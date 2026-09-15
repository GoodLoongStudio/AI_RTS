class_name ProductionTheme
extends RefCounted

## 生产面板（游戏内右侧 HUD）的统一设计令牌。
##
## 为什么要单独一份：生产面板原先自成一派（Ra3Sidebar.gd:83-94 硬编码 PANEL_BG 等
## 偏黑灰的色板），与主菜单/成长系统/玩家画像那套「深蓝黑金属 + 青蓝/琥珀」不一致。
## 用户要求"保持与成长系统、玩家画像、主菜单一致" ⇒ 这里做**薄适配层**：
## 语义命名（生产面板用得上）指向 SystemUIStyle 的同一批数值，
## 但**不重复定义颜色值**，改 SystemUIStyle 一处即可全局跟随。
##
## 用法：生产面板相关组件只从这里取色/取样式，不要再各写一套 Color(...)。

# ---------- 从主菜单体系继承的基础色 ----------
const BG := SystemUIStyle.PANEL                    # 面板底
const BG_DEEP := SystemUIStyle.GLASS_DEEP          # 更实的深底（卡片）
const LINE := SystemUIStyle.LINE
const LINE_SOFT := SystemUIStyle.LINE_SOFT
const TEXT := SystemUIStyle.TEXT
const MUTED := SystemUIStyle.MUTED
const DIM := SystemUIStyle.DIM

## 语义色（用户口径）：
## 青蓝 = 可用/友军系统；橙金 = 资源/价格/警告；绿 = 已完成/可部署；红 = 禁用/不足/危险
const CYAN := SystemUIStyle.CYAN
const AMBER := SystemUIStyle.AMBER
const AMBER_HI := SystemUIStyle.AMBER_HI
const GREEN := SystemUIStyle.GREEN
const RED := SystemUIStyle.RED

# ---------- 生产卡片状态 ----------
## 与 ProductionCatalog.state_of() 的 state 取值一一对应。
const STATE_READY := "ready"
const STATE_INSUFFICIENT := "insufficient_resource"
const STATE_ENERGY := "insufficient_energy"
const STATE_LOCKED := "unlocked_off"
const STATE_QUEUE_FULL := "queue_full"
const STATE_PRODUCING := "producing"
const STATE_MAXED := "maxed"
const STATE_DAMAGED := "damaged"

## 状态 → (描边色, 角标色, 角标字形, 中文短标签)
## 角标字形刻意用 ASCII：项目主题字体不保证含 ✔ ✕ ⚠ 等符号。
const STATE_TABLE := {
	STATE_READY: {"edge": CYAN, "badge": CYAN, "glyph": "+", "label": "可生产"},
	STATE_INSUFFICIENT: {"edge": AMBER, "badge": AMBER, "glyph": "!", "label": "资源不足"},
	STATE_ENERGY: {"edge": AMBER, "badge": AMBER, "glyph": "!", "label": "能源不足"},
	STATE_LOCKED: {"edge": SystemUIStyle.LINE_SOFT, "badge": DIM, "glyph": "L", "label": "未解锁"},
	STATE_QUEUE_FULL: {"edge": AMBER, "badge": AMBER, "glyph": "F", "label": "队列已满"},
	STATE_PRODUCING: {"edge": GREEN, "badge": GREEN, "glyph": ">", "label": "生产中"},
	STATE_MAXED: {"edge": GREEN, "badge": GREEN, "glyph": "=", "label": "已满"},
	STATE_DAMAGED: {"edge": RED, "badge": RED, "glyph": "#", "label": "受损"},
}

# ---------- 几何 ----------
const RADIUS := 5
const BORDER_NORMAL := 1
const BORDER_ACTIVE := 2


static func state_edge(state: String) -> Color:
	return STATE_TABLE.get(state, STATE_TABLE[STATE_READY])["edge"]


static func state_glyph(state: String) -> String:
	return STATE_TABLE.get(state, STATE_TABLE[STATE_READY])["glyph"]


static func state_label(state: String) -> String:
	return STATE_TABLE.get(state, STATE_TABLE[STATE_READY])["label"]


static func state_color(state: String) -> Color:
	return STATE_TABLE.get(state, STATE_TABLE[STATE_READY])["badge"]


## 卡片底 + 状态描边（生产卡片的唯一入口）。
static func card_style(state: String, hovered := false, active := false) -> StyleBoxFlat:
	var edge := state_edge(state)
	var bg := BG_DEEP if not hovered else Color(0.075, 0.169, 0.216, 0.96)
	if active:
		bg = Color(0.106, 0.290, 0.365, 0.96)
	var width := BORDER_ACTIVE if (hovered or active) else BORDER_NORMAL
	var style := SystemUIStyle.rounded(bg, edge, width, RADIUS)
	style.content_margin_left = 3
	style.content_margin_right = 3
	style.content_margin_top = 3
	style.content_margin_bottom = 3
	if active:
		style.shadow_color = Color(edge.r, edge.g, edge.b, 0.40)
		style.shadow_size = 4
	return style


## 小键帽（快捷键提示统一用它渲染，不要把字母直接写进正文）。
## 返回的 Control 自己画圆角方块 + 居中字母，不依赖字体是否含方框字符。
##
## ⚠️ 宽度必须随**文本长度**自适应：字号若按盒子尺寸固定（早期写法 `box * 0.68`），
## 多字符键位（"Esc" / "Ctrl"）字宽会超过盒子宽度 ⇒ PanelContainer 被撑宽、视觉变胖。
static func keycap(text: String, accent: Color = CYAN, box := 16.0) -> Control:
	var chars := maxi(text.length(), 1)
	var width := maxf(box, box * 0.62 * float(chars) + 6.0)
	var cap := PanelContainer.new()
	cap.custom_minimum_size = Vector2(width, box)
	cap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var style := SystemUIStyle.rounded(
		Color(0.043, 0.114, 0.153, 0.95), accent, 1, 3)
	style.content_margin_left = 0
	style.content_margin_right = 0
	style.content_margin_top = 0
	style.content_margin_bottom = 0
	cap.add_theme_stylebox_override("panel", style)
	var label := Label.new()
	label.text = text
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", int(box * 0.60))
	label.add_theme_color_override("font_color", accent)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cap.add_child(label)
	return cap


## 横向条形图（单位对比用；数值 0..1）。
##
## ⚠️ 不能用「PanelContainer 轨道 + ColorRect 填充」实现：Container 会把子节点**拉伸填满**，
## `custom_minimum_size` 只影响最小尺寸、不限制实际尺寸 ⇒ 填充永远 100%（实测 bar(0.25,w=40)
## 画出来是满格）。这里改成自绘：`draw` 信号 + `draw_rect`，宽度完全由 value 决定。
static func bar(value: float, accent: Color, width := 90.0, height := 8.0) -> Control:
	var bar_control := Control.new()
	bar_control.custom_minimum_size = Vector2(width, height)
	bar_control.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bar_control.draw.connect(
		_draw_bar.bind(bar_control, clampf(value, 0.0, 1.0), accent)
	)
	return bar_control


static func _draw_bar(bar_control: Control, value: float, accent: Color) -> void:
	var full := bar_control.size
	if full.x <= 0.0 or full.y <= 0.0:
		return
	# 轨道
	bar_control.draw_rect(
		Rect2(Vector2.ZERO, full), Color(0.024, 0.063, 0.086, 0.9), true
	)
	# 填充（宽度 = value 比例，这才是"部分进度"）
	var filled := Vector2(full.x * value, full.y)
	if filled.x > 0.0:
		bar_control.draw_rect(Rect2(Vector2.ZERO, filled), accent, true)
