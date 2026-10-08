extends "res://source/ui/MenuPage.gd"

## 对局内教学页：一张「快捷键与操作」总览图（2026-09-27 用户要求）。
## 从暂停菜单「教学」按钮进入（embedded_mode=true），ESC / 返回 关闭回到暂停菜单。
## 图的内容来源：C# DefaultInputBindings（对局内权威键位表）+ 相机/命令 HUD 消费代码，
## 生成脚本 dev/make_tutorial_sheet.py（改键位后重跑即可重新出图）。
## 【2026-09-28 用户反馈"美术效果和主题页对不上"】图和页面整体改成 SystemUIStyle
## 深色科幻风（此前白底高对比版对比度没问题，但整个游戏是深蓝灰玻璃 + 青/琥珀，
## 白图放进暂停菜单/主菜单都违和）。页面底色直接取 SystemUIStyle.BG。

signal close_requested

const SHEET_TEXTURE := "res://assets/ui/tutorial/hotkeys_sheet.png"

@export var embedded_mode = false


func _ready():
	if embedded_mode:
		process_mode = Node.PROCESS_MODE_ALWAYS  # 暂停树中仍可交互（同 Options 嵌入模式）
		UISfx.play("ui_menu_open")
	_build_content()


func _build_content() -> void:
	# 页面结构照抄其它菜单页：深底 "Background" + 内容作**兄弟节点**。
	# 【2026-09-28 用户反馈"字不要那么暗"】根因是 MenuPage 基类 deferred 加的
	# SystemScrim（45% 黑）盖在了总览图上——add_scrim 的固定行为是插到
	# "Background" 节点之后；旧白底版为此专门写了"挪 scrim"补丁。深色版照搬了
	# "内容挂 Background 底下"的结构，于是 scrim 又一次罩住全部内容（实测
	# CHILD_ORDER=[Background, SystemScrim]，Margin 在 Background 子树里照样被压）。
	# 现在内容做成 Background 的兄弟节点：scrim 落在深底之上、内容之下——
	# 深底被它压暗看不出，内容恢复全亮度，也不再需要任何挪动补丁。
	# （不用 PanelContainer 装内容——容器会被子节点最小尺寸撑开、拿不到视口
	# 大小，实测 Panel 只有 1032×752。）
	var backdrop := ColorRect.new()
	backdrop.name = "Background"
	backdrop.color = SystemUIStyle.BG
	backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	backdrop.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(backdrop)

	var margin := MarginContainer.new()
	margin.name = "Margin"
	for side in ["margin_left", "margin_top", "margin_right", "margin_bottom"]:
		margin.add_theme_constant_override(side, 18)
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	# 注意挂 page 而不是 Background：得做 scrim 之上的兄弟节点（见上方注释）。
	add_child(margin)

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
	# 【2026-09-28 用户反馈"页面居中"】横向/纵向都撑满滚动区，配合
	# KEEP_ASPECT_CENTERED，图在任意窗口尺寸下都居中并按比例缩放，
	# 不再是贴着左上角的固定 960×800（窗口一大右边就空一块）。
	sheet.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sheet.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.add_child(sheet)

	# 返回按钮收窄居中（同菜单按钮口径），不再整条横贯页面底部。
	var back := Button.new()
	back.name = "BackButton"
	back.text = "返回"
	back.custom_minimum_size = Vector2(320, 48)
	back.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	back.pressed.connect(_close)
	box.add_child(back)


func _close() -> void:
	if embedded_mode:
		UISfx.play("ui_menu_close")
		close_requested.emit()
		return
	# 非嵌入（主菜单/首页入口）：返回首页。同 Options/Growth 的返回口径。
	get_tree().change_scene_to_file("res://source/main-menu/Main.tscn")


## ESC 回退（MenuPage 基类）：教学页没有子级面板，直接关闭。
func _on_escape() -> bool:
	_close()
	return true
