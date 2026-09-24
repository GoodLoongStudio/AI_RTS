extends Control

const AdjutantRunnerLauncher := preload("res://source/ui/AdjutantRunnerLauncher.gd")
const AdjutantModelService := preload("res://source/ui/AdjutantModelService.gd")

## 主菜单背景音乐由常驻自动加载 MenuMusic 播放（跨菜单场景不断），
## 此处不再单独挂载（2026-09-08）。

static var _autojoin_fired := false  # 每进程只生效一次，防止把玩家弹回联机界面


func _ready() -> void:
	SystemUIStyle.add_scrim(self)
	SystemUIStyle.apply(self)
	# 中央面板：半透明深色金属 + 极轻的青色内发光，不抢标题。
	var panel := get_node_or_null("CenterContainer/PanelContainer") as PanelContainer
	if panel != null:
		var frame := SystemUIStyle.flat(Color("#081923e8"), 14, Color("#496875"), 1)
		frame.shadow_color = Color(0.15, 0.79, 0.91, 0.10)
		frame.shadow_size = 10
		panel.add_theme_stylebox_override("panel", frame)
	var title := get_node_or_null("CenterContainer/PanelContainer/MarginContainer/VBoxContainer/Title") as Label
	if title != null:
		title.add_theme_font_size_override("font_size", 46)
		title.add_theme_color_override("font_color", SystemUIStyle.AMBER_HI)
	var subtitle := get_node_or_null("CenterContainer/PanelContainer/MarginContainer/VBoxContainer/Subtitle") as Label
	if subtitle != null:
		subtitle.add_theme_font_size_override("font_size", 15)
		subtitle.add_theme_color_override("font_color", Color("#7fc4d6"))
	_add_system_header()
	# 键盘/手柄进入菜单即有明确焦点（按钮用琥珀金描边 + 外发光，见 SystemUIStyle._style_button）。
	# 放在 _add_system_header() 之后：顶部信息行不参与焦点链，避免抢走首焦点。
	var first := get_node_or_null(
		"CenterContainer/PanelContainer/MarginContainer/VBoxContainer/PlayButton") as Button
	if first != null:
		first.grab_focus()
	# 【2026-09-20 用户要求】联机暂不开放：隐藏「在线匹配」入口。
	# 只藏 UI，不删场景/信号/autojoin 钩子（--autojoin 自动化仍可进联机页，便于日后开放）。
	var online_btn := get_node_or_null(
		"CenterContainer/PanelContainer/MarginContainer/VBoxContainer/OnlineButton") as Button
	if online_btn != null:
		online_btn.visible = false
		online_btn.disabled = true
	# 调试钩子：--autojoin（或 res://autojoin.txt）→ 直接进联机界面，
	# Online._ready 的 autojoin 钩子接管加入+立即开局（供 Godot MCP 一键开局）。
	# 复核 2026-09-02：只在本进程第一次加载 Main 时生效——自动化会话遗留/重建
	# autojoin.txt 期间，玩家点「返回」到主菜单会被立刻弹回联机界面（表现为返回失灵）。
	if not _autojoin_fired and "--autojoin" in OS.get_cmdline_user_args():
		_autojoin_fired = true
		_on_online_button_pressed()
	_prewarm_model_service()


## 【2026-09-23】主菜单就把本地模型服务拉起来并预热。
##
## 为什么放这儿：冷模型首次推理 ~70s（2.6GB 载入）。只在加载页/点"接管"时才开始，
## 玩家从主菜单走到开局通常没这么久 → 头几分钟面板一直显示"预热中"。
## 主菜单是玩家停留最久的地方，把这段时间用起来，等真开局时模型大概率已经热了。
##
## 两个护栏，避免替玩家决定/拖累无关玩家：
##   ① 只对**开过副官接管**的玩家预热（`auto_takeover`）——没开过的不替他决定；
##   ② 专用服实例不预热（副官是玩家自己的，服务端起它是浪费 2.6GB）。
## 非阻塞：服务在后台起，菜单该干嘛干嘛。
func _prewarm_model_service() -> void:
	if OS.get_cmdline_user_args().has("--server"):
		return
	if not AdjutantRunnerLauncher.auto_takeover():
		return
	if AdjutantModelService.is_ready() and AdjutantModelService.is_listening():
		return
	AdjutantModelService.ensure_started(self)
	print("[MainMenu] 已在主菜单开始预热本地模型服务（端口 %d）"
		% AdjutantModelService.PORT)


func _add_system_header() -> void:
	var header := Label.new()
	# 联机暂不开放（2026-09-20），横幅不再宣称 ONLINE。
	header.text = "HERMES COMMAND // LOCAL"
	header.position = Vector2(28, 22)
	header.add_theme_font_size_override("font_size", 14)
	header.add_theme_color_override("font_color", SystemUIStyle.CYAN)
	header.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(header)
	var footer := Label.new()
	footer.text = "BUILD 0.1  •  LOCAL PROFILE"
	footer.anchor_left = 1.0
	footer.anchor_top = 1.0
	footer.anchor_right = 1.0
	footer.anchor_bottom = 1.0
	footer.offset_left = -230
	footer.offset_top = -34
	footer.offset_right = -24
	footer.offset_bottom = -14
	footer.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	footer.add_theme_font_size_override("font_size", 12)
	footer.add_theme_color_override("font_color", SystemUIStyle.MUTED)
	footer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(footer)


func _on_play_button_pressed():
	get_tree().change_scene_to_file("res://source/main-menu/Play.tscn")


func _on_online_button_pressed():
	get_tree().change_scene_to_file("res://source/main-menu/Online.tscn")


func _on_options_button_pressed():
	get_tree().change_scene_to_file("res://source/main-menu/Options.tscn")


func _on_growth_button_pressed():
	get_tree().change_scene_to_file("res://source/main-menu/Growth.tscn")


func _on_map_gen_button_pressed():
	get_tree().change_scene_to_file("res://source/main-menu/MapGeneration.tscn")


func _on_quit_button_pressed():
	get_tree().quit()
