extends "res://source/ui/MenuPage.gd"

## 对局内教学页：一张「快捷键与操作」总览图（2026-09-27 用户要求）。
## 从暂停菜单「教学」按钮进入（embedded_mode=true），ESC / 返回 关闭回到暂停菜单。
## 图的内容来源：C# DefaultInputBindings（对局内权威键位表）+ 相机/命令 HUD 消费代码，
## 生成脚本 dev/make_tutorial_sheet.py（改键位后重跑即可重新出图）。

signal close_requested

const SHEET_TEXTURE := "res://assets/ui/tutorial/hotkeys_sheet.png"

@export var embedded_mode = false


func _ready():
	if embedded_mode:
		process_mode = Node.PROCESS_MODE_ALWAYS  # 暂停树中仍可交互（同 Options 嵌入模式）
		UISfx.play("ui_menu_open")
		var dimmer := ColorRect.new()
		dimmer.name = "EmbeddedDimmer"
		dimmer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		dimmer.color = Color(0.0, 0.0, 0.0, 0.72)
		dimmer.mouse_filter = Control.MOUSE_FILTER_STOP
		add_child(dimmer)
		move_child(dimmer, 0)
	_build_content()


func _build_content() -> void:
	var center := CenterContainer.new()
	center.name = "Center"
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(center)

	var panel := PanelContainer.new()
	panel.name = "Panel"
	center.add_child(panel)

	var margin := MarginContainer.new()
	for side in ["margin_left", "margin_top", "margin_right", "margin_bottom"]:
		margin.add_theme_constant_override(side, 18)
	panel.add_child(margin)

	var box := VBoxContainer.new()
	box.name = "Box"
	box.add_theme_constant_override("separation", 12)
	margin.add_child(box)

	# 标题已烤进总览图里，不再放重复的 Label。

	var scroll := ScrollContainer.new()
	scroll.name = "SheetScroll"
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.custom_minimum_size = Vector2(980.0, 640.0)
	box.add_child(scroll)

	var sheet := TextureRect.new()
	sheet.name = "Sheet"
	sheet.texture = load(SHEET_TEXTURE)
	sheet.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	sheet.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	sheet.custom_minimum_size = Vector2(960.0, 800.0)
	scroll.add_child(sheet)

	var back := Button.new()
	back.name = "BackButton"
	back.text = "返回"
	back.custom_minimum_size = Vector2(0, 48)
	back.pressed.connect(_close)
	box.add_child(back)


func _close() -> void:
	if embedded_mode:
		UISfx.play("ui_menu_close")
		close_requested.emit()
		return
	queue_free()


## ESC 回退（MenuPage 基类）：教学页没有子级面板，直接关闭。
func _on_escape() -> bool:
	_close()
	return true
