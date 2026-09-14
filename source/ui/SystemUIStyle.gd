class_name SystemUIStyle
extends RefCounted

## 系统 UI 统一视觉：深色工业科幻 RTS。
## 约定：页面在 `_ready`（或 MenuPage 基类的 `_enter_tree`）里调用 `apply(self)`，
## 之后页面上**运行时新建**的控件再单独 `apply_to(node)`。
## 颜色只从这里取，页面不要各写一套。

# ---------- 色板 ----------
const BG := Color("#07131b")
const PANEL := Color("#0b1d27")
const PANEL_ALT := Color("#102834")
const GLASS := Color("#0c1e2ad9")        # 半透明烟熏玻璃
const GLASS_DEEP := Color("#081923e8")   # 更实的深色玻璃（主菜单中央面板）
const LINE := Color("#355463")           # 常规描边
const LINE_SOFT := Color("#22404d")      # 内衬描边
const LINE_STRONG := Color("#496875")    # 重点描边
const TEXT := Color("#e7f1f3")
const MUTED := Color("#8ea7ad")
const DIM := Color("#5d757d")
const CYAN := Color("#26c9e8")
const CYAN_DEEP := Color("#0f4a5c")
const AMBER := Color("#e4a452")
const AMBER_HI := Color("#f3c77b")
const AMBER_DEEP := Color("#3a2a12")
const GREEN := Color("#49c99b")
const RED := Color("#e05b47")
const DISABLED_BG := Color("#0a1015")
const DISABLED_LINE := Color("#1d2b32")

const RADIUS := 8
const RADIUS_PANEL := 10
const BUTTON_MIN_HEIGHT := 44.0

# 三条成长分支（战斗 / 经济 / 建设）
const BRANCH_ACCENT := {
	"combat": Color("#e05b47"),
	"economy": Color("#38c9ee"),
	"construction": Color("#49c99b"),
}

# ---------- StyleBox 工厂 ----------

static func rounded(color: Color, border: Color = Color.TRANSPARENT, width: int = 0,
		radius: int = RADIUS) -> StyleBoxFlat:
	## 基础工厂。签名与旧版保持一致（Main.gd 等已在调用）。
	var style := StyleBoxFlat.new()
	style.bg_color = color
	style.border_color = border
	style.set_border_width_all(width)
	style.set_corner_radius_all(radius)
	style.content_margin_left = 16
	style.content_margin_right = 16
	style.content_margin_top = 10
	style.content_margin_bottom = 10
	return style


static func flat(color: Color, radius: int = RADIUS, border: Color = Color.TRANSPARENT,
		width: int = 0) -> StyleBoxFlat:
	var style := rounded(color, border, width, radius)
	style.content_margin_left = 0
	style.content_margin_right = 0
	style.content_margin_top = 0
	style.content_margin_bottom = 0
	return style


static func glass(size := Vector2.ZERO) -> StyleBoxFlat:
	## 半透明烟熏玻璃面板：深底 + 细边 + 内衬 + 轻微内发光。
	var style := rounded(GLASS, LINE, 1, RADIUS_PANEL)
	style.content_margin_left = 22
	style.content_margin_right = 22
	style.content_margin_top = 18
	style.content_margin_bottom = 18
	style.shadow_color = Color(CYAN.r, CYAN.g, CYAN.b, 0.10)
	style.shadow_size = 6
	if size != Vector2.ZERO:
		style.content_margin_left = size.x
		style.content_margin_right = size.x
		style.content_margin_top = size.y
		style.content_margin_bottom = size.y
	return style


static func metal_frame(accent: Color = LINE_STRONG) -> StyleBoxFlat:
	## 轻微磨损的金属边框面板：外框略亮、内衬略暗，制造倒角层次。
	var style := rounded(GLASS_DEEP, accent, 1, RADIUS_PANEL)
	style.content_margin_left = 22
	style.content_margin_right = 22
	style.content_margin_top = 18
	style.content_margin_bottom = 18
	return style


static func accent_panel(accent: Color, alpha := 0.9) -> StyleBoxFlat:
	## 带强调色的玻璃卡片（成长分支、功能卡）。
	var style := rounded(Color(PANEL.r, PANEL.g, PANEL.b, alpha), accent, 2, RADIUS_PANEL)
	style.content_margin_left = 18
	style.content_margin_right = 18
	style.content_margin_top = 14
	style.content_margin_bottom = 14
	return style


static func branch_style(branch: String) -> StyleBoxFlat:
	return accent_panel(branch_accent(branch))


static func branch_accent(branch: String) -> Color:
	return BRANCH_ACCENT.get(branch, CYAN)


static func focus_ring(accent: Color) -> StyleBoxFlat:
	## 明显的焦点态：2px 强调色描边 + 外发光，绝不"只改一点点颜色"。
	var style := rounded(Color("#0f2632"), accent, 2, RADIUS)
	style.content_margin_left = 16
	style.content_margin_right = 16
	style.content_margin_top = 10
	style.content_margin_bottom = 10
	style.shadow_color = Color(accent.r, accent.g, accent.b, 0.38)
	style.shadow_size = 4
	return style


# ---------- 统一入口 ----------

static func add_scrim(root: Control, alpha := 0.45) -> ColorRect:
	## 统一深色遮罩：压在背景图之上、UI 之下，保证文字可读。
	## 只加一次（按节点名去重），并插到 Background 之后，避免重复叠背景。
	if root == null:
		return null
	var existing := root.get_node_or_null("SystemScrim")
	if existing is ColorRect:
		return existing
	var scrim := ColorRect.new()
	scrim.name = "SystemScrim"
	scrim.color = Color(0.016, 0.043, 0.067, alpha)
	scrim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	scrim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_child(scrim)
	var bg := root.get_node_or_null("Background")
	if bg != null:
		root.move_child(scrim, bg.get_index() + 1)
	return scrim


static func skip_subtree(node: Node) -> void:
	## 给「页面自己按强调色打扮过」的运行时子树打豁免标记。
	## 为什么必须要：MenuPage 基类在 `_enter_tree` 里 `call_deferred` 了 apply(self)，
	## 而 call_deferred 的刷新时机在 `_ready` **之后** —— 页面 `_ready` 里新建的
	## 分支面板 / 强调色标题 / 节点卡片会被通用 PanelContainer、Label 样式整片覆盖
	## （表现为"三栏成长树的分支配色全没了"）。打了标记的节点及其子孙都会被跳过。
	## 页面在 `_ready` 里构建完自建控件后立刻调用本函数即可。
	if node == null:
		return
	node.set_meta("ui_skip", true)
	for child in node.get_children():
		skip_subtree(child)


static func apply(root: Node) -> void:
	## 遍历已有 Control 并套用统一主题。运行时新建的节点请再调 apply_to()。
	if root == null:
		return
	if root is Control:
		apply_to(root)
	for node in root.find_children("*", "Control", true, false):
		apply_to(node)


static func apply_to(node: Node) -> void:
	if node == null or not (node is Control):
		return
	# 显式豁免：调用方若给节点打了 ui_skip 元数据，就不要覆盖它的样式。
	if node.has_meta("ui_skip"):
		return
	# 注意：CheckBox / OptionButton 都继承 Button，必须先判子类再判基类。
	if node is CheckBox:
		_style_check_box(node)
	elif node is OptionButton:
		_style_option_button(node)
	elif node is Button:
		_style_button(node)
	elif node is PanelContainer:
		node.add_theme_stylebox_override("panel", glass())
	elif node is Panel:
		# Panel 在本项目只用作 Label 背后的"标题带"（Play 页的 Map / Players）。
		# 这里只给一层很淡的填充，**不要描边** —— 描边会把标题带变成两条突兀的黑条。
		node.add_theme_stylebox_override("panel", flat(Color(0.043, 0.114, 0.153, 0.55), 6))
	elif node is ItemList:
		_style_item_list(node)
	elif node is RichTextLabel:
		_style_rich_text(node)
	elif node is Label:
		_style_label(node)
	elif node is LineEdit:
		_style_line_edit(node)
	elif node is HSlider:
		_style_h_slider(node)
	elif node is TabBar:
		_style_tab_bar(node)
	elif node is ScrollBar:
		_style_scroll_bar(node)


# ---------- 各控件 ----------

static func _style_label(label: Label) -> void:
	label.add_theme_color_override("font_color", TEXT)
	label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.7))
	label.add_theme_constant_override("shadow_offset_x", 1)
	label.add_theme_constant_override("shadow_offset_y", 2)


static func _style_rich_text(rich: RichTextLabel) -> void:
	rich.add_theme_color_override("default_color", TEXT)
	rich.add_theme_stylebox_override("normal", flat(Color(0, 0, 0, 0)))


static func _style_button(button: Button) -> void:
	button.custom_minimum_size.y = maxf(button.custom_minimum_size.y, BUTTON_MIN_HEIGHT)
	# 只设字号下限（16），不强行放大会把 Play 页 16 个 OptionButton 的网格撑爆。
	button.add_theme_font_size_override("font_size", max(16, button.get_theme_font_size("font_size")))
	button.add_theme_color_override("font_color", TEXT)
	button.add_theme_color_override("font_hover_color", Color.WHITE)
	button.add_theme_color_override("font_pressed_color", Color.WHITE)
	button.add_theme_color_override("font_focus_color", AMBER_HI)
	button.add_theme_color_override("font_disabled_color", DIM)
	button.add_theme_stylebox_override("normal", rounded(Color("#101f28"), LINE_SOFT, 1, RADIUS))
	button.add_theme_stylebox_override("hover", rounded(Color("#173847"), CYAN, 1, RADIUS))
	button.add_theme_stylebox_override("pressed", rounded(Color("#1c5361"), CYAN, 2, RADIUS))
	button.add_theme_stylebox_override("focus", focus_ring(AMBER))
	button.add_theme_stylebox_override("disabled",
		rounded(DISABLED_BG, DISABLED_LINE, 1, RADIUS))


static func _style_check_box(box: CheckBox) -> void:
	_style_button(box)
	box.add_theme_color_override("font_color", TEXT)
	box.add_theme_color_override("font_hover_color", Color.WHITE)
	box.add_theme_color_override("font_focus_color", AMBER_HI)
	box.add_theme_color_override("font_disabled_color", DIM)
	box.add_theme_stylebox_override("normal", flat(Color(0, 0, 0, 0)))
	box.add_theme_stylebox_override("hover", flat(Color(0, 0, 0, 0)))
	box.add_theme_stylebox_override("pressed", flat(Color(0, 0, 0, 0)))
	box.add_theme_stylebox_override("disabled", flat(Color(0, 0, 0, 0)))
	box.add_theme_stylebox_override("focus", focus_ring(AMBER))


static func _style_option_button(option: OptionButton) -> void:
	_style_button(option)
	option.add_theme_stylebox_override("normal", rounded(Color("#101f28"), LINE_SOFT, 1, RADIUS))
	option.add_theme_stylebox_override("hover", rounded(Color("#173847"), CYAN, 1, RADIUS))
	option.add_theme_stylebox_override("pressed", rounded(Color("#1c5361"), CYAN, 2, RADIUS))
	option.add_theme_stylebox_override("focus", focus_ring(AMBER))
	option.add_theme_stylebox_override("disabled", rounded(DISABLED_BG, DISABLED_LINE, 1, RADIUS))
	option.add_theme_color_override("font_color", TEXT)
	option.add_theme_color_override("font_hover_color", Color.WHITE)
	option.add_theme_color_override("font_focus_color", AMBER_HI)
	option.add_theme_color_override("font_disabled_color", DIM)
	# 下拉弹窗（PopupMenu）也要跟着走，否则一展开就回到系统默认灰。
	var popup := option.get_popup()
	if popup != null:
		_style_popup(popup)


static func _style_popup(popup: PopupMenu) -> void:
	popup.add_theme_stylebox_override("panel", flat(GLASS_DEEP, RADIUS, LINE, 1))
	popup.add_theme_stylebox_override("hover", flat(Color("#173847"), 4))
	popup.add_theme_stylebox_override("separator", flat(LINE_SOFT, 0))
	popup.add_theme_color_override("font_color", TEXT)
	popup.add_theme_color_override("font_hover_color", Color.WHITE)
	popup.add_theme_color_override("font_disabled_color", DIM)


static func _style_item_list(list: ItemList) -> void:
	list.add_theme_stylebox_override("panel", rounded(GLASS_DEEP, LINE, 1, RADIUS))
	list.add_theme_stylebox_override("focus", focus_ring(CYAN))
	list.add_theme_stylebox_override("selected", flat(Color("#17505f"), 4, CYAN, 1))
	list.add_theme_stylebox_override("selected_focus", flat(Color("#1c5f70"), 4, CYAN, 1))
	list.add_theme_stylebox_override("hovered", flat(Color("#123040", 4)))
	list.add_theme_stylebox_override("cursor", flat(Color(0, 0, 0, 0)))
	list.add_theme_stylebox_override("cursor_unfocused", flat(Color(0, 0, 0, 0)))
	list.add_theme_color_override("font_color", TEXT)
	list.add_theme_color_override("font_selected_color", Color.WHITE)
	list.add_theme_color_override("font_hovered_color", Color.WHITE)


static func _style_line_edit(edit: LineEdit) -> void:
	edit.add_theme_stylebox_override("normal", rounded(Color("#0a181f"), LINE_SOFT, 1, RADIUS))
	edit.add_theme_stylebox_override("focus", focus_ring(CYAN))
	edit.add_theme_stylebox_override("read_only", rounded(DISABLED_BG, DISABLED_LINE, 1, RADIUS))
	edit.add_theme_color_override("font_color", TEXT)
	edit.add_theme_color_override("font_placeholder_color", DIM)
	edit.add_theme_color_override("font_selected_color", Color.WHITE)
	edit.add_theme_color_override("caret_color", AMBER)
	edit.add_theme_color_override("selection_color", Color(CYAN.r, CYAN.g, CYAN.b, 0.28))


static func _style_h_slider(slider: HSlider) -> void:
	var track := flat(Color("#0a181f"), 4, LINE_SOFT, 1)
	track.content_margin_top = 4
	track.content_margin_bottom = 4
	slider.add_theme_stylebox_override("slider", track)
	var filled := flat(CYAN_DEEP, 4, CYAN, 1)
	filled.content_margin_top = 4
	filled.content_margin_bottom = 4
	slider.add_theme_stylebox_override("grabber_area", filled)
	var hot := flat(Color("#1c5f70"), 4, AMBER, 1)
	hot.content_margin_top = 4
	hot.content_margin_bottom = 4
	slider.add_theme_stylebox_override("grabber_area_highlight", hot)


static func _style_tab_bar(bar: TabBar) -> void:
	bar.add_theme_stylebox_override("tab_unselected", flat(Color("#0c1c25"), 0, LINE_SOFT, 1))
	bar.add_theme_stylebox_override("tab_hovered", flat(Color("#14313f"), 0, CYAN, 1))
	bar.add_theme_stylebox_override("tab_selected", flat(Color("#173847"), 0, CYAN, 2))
	bar.add_theme_stylebox_override("tab_disabled", flat(DISABLED_BG, 0, DISABLED_LINE, 1))
	bar.add_theme_stylebox_override("tab_focus", focus_ring(AMBER))
	bar.add_theme_color_override("font_unselected_color", MUTED)
	bar.add_theme_color_override("font_hovered_color", Color.WHITE)
	bar.add_theme_color_override("font_selected_color", Color.WHITE)
	bar.add_theme_color_override("font_disabled_color", DIM)


static func _style_scroll_bar(bar: ScrollBar) -> void:
	bar.add_theme_stylebox_override("scroll", flat(Color(0, 0, 0, 0), RADIUS))
	bar.add_theme_stylebox_override("grabber", flat(Color("#2b4a58"), RADIUS))
	bar.add_theme_stylebox_override("grabber_highlight", flat(Color("#3d6a7c"), RADIUS))
	bar.add_theme_stylebox_override("grabber_pressed", flat(CYAN_DEEP, RADIUS))


# ---------- 运行时构建辅助 ----------

static func make_label(text: String, size: int = 14, color: Color = TEXT) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", color)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return label


static func make_button(text: String, height: float = BUTTON_MIN_HEIGHT) -> Button:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size = Vector2(0, height)
	_style_button(button)
	return button


static func make_panel(style: StyleBoxFlat) -> PanelContainer:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", style)
	return panel
