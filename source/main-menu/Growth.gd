extends "res://source/ui/MenuPage.gd"

## 成长系统入口页（Item 3）：两张横向功能大卡 + 单独的返回主菜单。
##
## 卡片根节点刻意用 `Button` 而不是 PanelContainer：
## hover / 点击 / 键盘焦点三态交给引擎原生处理（`normal`/`hover`/`pressed`/`focus`
## 四个 StyleBox），内部图标/文字/箭头全部 `mouse_filter = IGNORE` 覆盖其上，
## 这样手柄与键盘 Tab 能真正走到卡片上，而不只是"看着像按钮"。
##
## 卡片子树用 `SystemUIStyle.skip_subtree()` 打豁免标记：否则 MenuPage 基类
## 延迟执行的 `apply(self)` 会把这里的强调色描边与彩色标题整片刷成通用灰。

const ICON_DIR := "res://assets/ui/icons/growth/"

var cards: VBoxContainer


func _ready() -> void:
	SystemUIStyle.apply(self)
	cards = $CenterContainer/PanelContainer/MarginContainer/VBoxContainer/Cards
	_add_card(
		"永久加点",
		"战斗 · 经济 · 建设三条分支，消耗成长点换取跨对局的永久收益",
		SystemUIStyle.AMBER,
		"growth_points",
		_on_upgrades_pressed,
	)
	_add_card(
		"玩家画像",
		"Hermes 只读画像：维度雷达、常用策略、成长投入与副官推荐",
		SystemUIStyle.CYAN,
		"profile",
		_on_profile_pressed,
	)
	_add_card(
		"历史对局",
		"逐场详细报告：经济 / 生产 / 战斗 / 时间线，以及对应的 Hermes 赛后分析",
		SystemUIStyle.GREEN,
		"recon",
		_on_history_pressed,
	)
	var first := cards.get_child(0) as Button
	if first != null:
		first.grab_focus()
	_apply_tones()


func _apply_tones() -> void:
	## Header / Status 是 tscn 声明的节点，会被 MenuPage 基类延迟的通用 apply 刷成同色；
	## 这里按语义覆盖并打豁免标记（与执行时序无关）。
	var root := $CenterContainer/PanelContainer/MarginContainer/VBoxContainer
	var header := root.get_node("Header") as Label
	var status := root.get_node("Status") as Label
	header.add_theme_color_override("font_color", SystemUIStyle.CYAN)
	status.add_theme_color_override("font_color", SystemUIStyle.MUTED)
	for label in [header, status]:
		label.set_meta("ui_skip", true)


func _add_card(title: String, description: String, accent: Color, icon_name: String,
		handler: Callable) -> void:
	var card := Button.new()
	card.custom_minimum_size = Vector2(0, 132)
	card.focus_mode = Control.FOCUS_ALL
	card.text = ""
	card.add_theme_stylebox_override("normal", _card_style(accent, 0))
	card.add_theme_stylebox_override("hover", _card_style(accent, 1))
	card.add_theme_stylebox_override("pressed", _card_style(accent, 2))
	card.add_theme_stylebox_override("focus", _card_focus(accent))
	card.pressed.connect(handler)
	cards.add_child(card)

	# 内容层：铺满按钮矩形，但整体不接收鼠标，点击一律落到下面的 Button 上。
	var row := HBoxContainer.new()
	row.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	row.offset_left = 26
	row.offset_right = -26
	row.offset_top = 18
	row.offset_bottom = -18
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_theme_constant_override("separation", 20)
	card.add_child(row)

	row.add_child(_make_icon(icon_name, 64))

	var text_box := VBoxContainer.new()
	text_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	text_box.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	text_box.add_theme_constant_override("separation", 6)
	text_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(text_box)

	var name_label := SystemUIStyle.make_label(title, 26, accent)
	text_box.add_child(name_label)
	var desc := SystemUIStyle.make_label(description, 14, SystemUIStyle.MUTED)
	desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	desc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	text_box.add_child(desc)

	row.add_child(_make_arrow(accent))

	SystemUIStyle.skip_subtree(card)


func _make_icon(icon_name: String, box: float) -> Control:
	var holder := CenterContainer.new()
	holder.custom_minimum_size = Vector2(box, box)
	holder.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var icon := TextureRect.new()
	icon.custom_minimum_size = Vector2(box, box)
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var path := ICON_DIR + icon_name + ".svg"
	if ResourceLoader.exists(path):
		icon.texture = load(path)
	holder.add_child(icon)
	return holder


func _make_arrow(accent: Color) -> Control:
	## 右向箭头用 `_draw` 画折线，避免依赖主题字体是否含 "→" 字形。
	var arrow := Control.new()
	arrow.custom_minimum_size = Vector2(30, 30)
	arrow.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	arrow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	arrow.draw.connect(_on_arrow_draw.bind(arrow, accent))
	return arrow


func _on_arrow_draw(arrow: Control, accent: Color) -> void:
	var w := arrow.size.x
	var h := arrow.size.y
	arrow.draw_line(Vector2(w * 0.32, h * 0.22), Vector2(w * 0.68, h * 0.50), accent, 2.5, true)
	arrow.draw_line(Vector2(w * 0.68, h * 0.50), Vector2(w * 0.32, h * 0.78), accent, 2.5, true)


func _card_style(accent: Color, mode: int) -> StyleBoxFlat:
	## mode: 0 常态 / 1 悬停 / 2 按下
	var background := Color(0.043, 0.114, 0.153, 0.92)
	var border := Color(accent.r, accent.g, accent.b, 0.55)
	var width := 1
	var style: StyleBoxFlat
	if mode == 1:
		background = Color(0.075, 0.169, 0.216, 0.95)
		border = accent
		width = 2
	elif mode == 2:
		background = Color(0.106, 0.290, 0.365, 0.96)
		border = accent
		width = 2
	style = SystemUIStyle.rounded(background, border, width, 12)
	if mode == 1:
		style.shadow_color = Color(accent.r, accent.g, accent.b, 0.26)
		style.shadow_size = 6
	return style


func _card_focus(accent: Color) -> StyleBoxFlat:
	## 焦点态必须一眼可辨：加粗到 2px 强调色描边 + 外发光，绝不能只是"颜色深一点"。
	var style := SystemUIStyle.rounded(Color(0.059, 0.149, 0.196, 0.96), accent, 2, 12)
	style.shadow_color = Color(accent.r, accent.g, accent.b, 0.40)
	style.shadow_size = 7
	return style


func _on_upgrades_pressed() -> void:
	get_tree().change_scene_to_file("res://source/main-menu/GrowthUpgrades.tscn")


func _on_profile_pressed() -> void:
	get_tree().change_scene_to_file("res://source/main-menu/PlayerProfile.tscn")


func _on_history_pressed() -> void:
	## 历史对局列表页的「返回」要回到成长页（从哪来回哪去）。
	MatchHistoryNav.return_scene = "res://source/main-menu/Growth.tscn"
	MatchHistoryNav.reset()
	get_tree().change_scene_to_file("res://source/main-menu/MatchHistory.tscn")


func _on_back_pressed() -> void:
	get_tree().change_scene_to_file("res://source/main-menu/Main.tscn")


func _on_escape() -> bool:
	_on_back_pressed()
	return true
