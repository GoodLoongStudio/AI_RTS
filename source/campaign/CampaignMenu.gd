extends Control

const OptionsScene = preload("res://source/main-menu/Options.tscn")
const CampaignMission = preload("res://source/campaign/CampaignMission.gd")
const CampaignFlow = preload("res://source/campaign/CampaignFlow.gd")

var _mission: Dictionary
var _options_panel: Control = null


func _ready():
	_mission = CampaignMission.echo_extraction()
	_build_ui()


func _build_ui():
	var page := MarginContainer.new()
	page.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	page.add_theme_constant_override("margin_left", 90)
	page.add_theme_constant_override("margin_top", 70)
	page.add_theme_constant_override("margin_right", 90)
	page.add_theme_constant_override("margin_bottom", 70)
	add_child(page)

	var root := HBoxContainer.new()
	root.add_theme_constant_override("separation", 30)
	page.add_child(root)

	var chapter_panel := PanelContainer.new()
	chapter_panel.custom_minimum_size = Vector2(430, 0)
	root.add_child(chapter_panel)
	var chapter_box := VBoxContainer.new()
	chapter_box.add_theme_constant_override("separation", 12)
	chapter_panel.add_child(chapter_box)

	var title := Label.new()
	title.text = "单人战役"
	title.add_theme_font_size_override("font_size", 34)
	chapter_box.add_child(title)

	var chapter := Label.new()
	chapter.text = _mission["chapter"]
	chapter.add_theme_font_size_override("font_size", 22)
	chapter_box.add_child(chapter)

	_add_mission_button(chapter_box, "01  回声撤离", true)
	_add_mission_button(chapter_box, "02  失联区  ·  未解锁", false)
	_add_mission_button(chapter_box, "03  黑箱  ·  未解锁", false)
	_add_mission_button(chapter_box, "04  封锁线  ·  未解锁", false)

	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	chapter_box.add_child(spacer)

	var settings_button := Button.new()
	settings_button.name = "SettingsButton"
	settings_button.text = "设置"
	settings_button.pressed.connect(_on_settings_pressed)
	chapter_box.add_child(settings_button)

	var back := Button.new()
	back.text = "返回主菜单"
	back.pressed.connect(_on_back_pressed)
	chapter_box.add_child(back)

	var details_panel := PanelContainer.new()
	details_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root.add_child(details_panel)
	var details := VBoxContainer.new()
	details.add_theme_constant_override("separation", 14)
	details_panel.add_child(details)

	var mission_title := Label.new()
	mission_title.text = _mission["title"]
	mission_title.add_theme_font_size_override("font_size", 30)
	details.add_child(mission_title)

	var subtitle := Label.new()
	subtitle.text = _mission["subtitle"]
	subtitle.add_theme_font_size_override("font_size", 18)
	details.add_child(subtitle)

	var divider := HSeparator.new()
	details.add_child(divider)

	var summary := Label.new()
	summary.text = _mission["summary"]
	summary.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	summary.add_theme_font_size_override("font_size", 20)
	summary.size_flags_vertical = Control.SIZE_EXPAND_FILL
	details.add_child(summary)

	var info := Label.new()
	info.text = "预计任务时间：%s\n主要威胁：未知\n可撤离：是\n主要语言：中文" % _mission["estimated_time"]
	info.add_theme_font_size_override("font_size", 18)
	details.add_child(info)

	var start := Button.new()
	start.text = "进入战区"
	start.custom_minimum_size = Vector2(0, 64)
	start.add_theme_font_size_override("font_size", 22)
	start.pressed.connect(_on_start_pressed)
	details.add_child(start)


func _add_mission_button(parent: Control, text: String, enabled: bool):
	var button := Button.new()
	button.text = text
	button.alignment = HORIZONTAL_ALIGNMENT_LEFT
	button.custom_minimum_size = Vector2(0, 58)
	button.disabled = not enabled
	parent.add_child(button)


func _on_settings_pressed():
	if _options_panel != null:
		return
	_options_panel = OptionsScene.instantiate()
	_options_panel.embedded_mode = true
	_options_panel.close_requested.connect(_close_options_panel)
	add_child(_options_panel)


func _close_options_panel():
	if _options_panel == null:
		return
	_options_panel.queue_free()
	_options_panel = null


func _on_start_pressed():
	hide()
	CampaignFlow.start_mission(get_tree(), _mission, self)


func _on_back_pressed():
	get_tree().change_scene_to_file("res://source/main-menu/Main.tscn")
