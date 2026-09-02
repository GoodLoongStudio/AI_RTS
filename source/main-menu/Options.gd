extends Control

signal close_requested

@export var embedded_mode = false

@onready var _screen = find_child("Screen")
@onready var _mouse_movement_restricted = find_child("MouseMovementRestricted")
@onready var _settings_box = $PanelContainer/MarginContainer/VBoxContainer/ScrollContainer/SettingsList

var _save_timer: Timer
var _camera_edge_scroll: CheckBox
var _camera_controls := {}
var _camera_value_labels := {}
var _audio_controls := {}
var _audio_value_labels := {}


func _ready():
	if embedded_mode:
		_prepare_embedded_mode()
	_setup_save_timer()
	_mouse_movement_restricted.button_pressed = Globals.options.mouse_restricted
	_screen.selected = Globals.options.screen
	_fit_panel_to_viewport()
	_build_camera_settings()
	_build_audio_settings()
	if not embedded_mode:
		AudioDirector.set_music_context("menu")


func _prepare_embedded_mode():
	process_mode = Node.PROCESS_MODE_ALWAYS
	$Background.hide()

	var dimmer := ColorRect.new()
	dimmer.name = "EmbeddedDimmer"
	dimmer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dimmer.color = Color(0.0, 0.0, 0.0, 0.72)
	dimmer.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(dimmer)
	move_child(dimmer, 0)


func _fit_panel_to_viewport():
	var panel: PanelContainer = $PanelContainer
	var view_height := get_viewport_rect().size.y
	var height := minf(840.0, maxf(520.0, view_height - 72.0))
	panel.offset_top = -height * 0.5
	panel.offset_bottom = height * 0.5


func _setup_save_timer():
	_save_timer = Timer.new()
	_save_timer.one_shot = true
	_save_timer.wait_time = 0.25
	_save_timer.timeout.connect(_save_options)
	add_child(_save_timer)


func _build_camera_settings():
	var camera_panel := PanelContainer.new()
	camera_panel.name = "CameraSettings"
	_settings_box.add_child(camera_panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 12)
	margin.add_theme_constant_override("margin_top", 12)
	margin.add_theme_constant_override("margin_right", 12)
	margin.add_theme_constant_override("margin_bottom", 12)
	camera_panel.add_child(margin)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	margin.add_child(box)

	var title := Label.new()
	title.text = "镜头"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 22)
	box.add_child(title)

	_camera_edge_scroll = CheckBox.new()
	_camera_edge_scroll.text = "启用屏幕边缘滚屏"
	_camera_edge_scroll.disabled = not FeatureFlags.enable_edge_scroll
	_camera_edge_scroll.button_pressed = (
		FeatureFlags.enable_edge_scroll
		and bool(Globals.get_camera_option("edge_scroll_enabled"))
	)
	_camera_edge_scroll.toggled.connect(_on_camera_edge_scroll_toggled)
	box.add_child(_camera_edge_scroll)

	_add_camera_slider(
		box, "movement_speed", "镜头移动速度", 0.4, 3.0, 0.1,
		float(Globals.get_camera_option("movement_speed")), "%.1fx"
	)
	_add_camera_slider(
		box, "edge_margin", "边缘触发范围", 16.0, 96.0, 1.0,
		float(Globals.get_camera_option("edge_margin")), "%.0f px"
	)
	_add_camera_slider(
		box, "bottom_edge_margin", "底边触发范围", 24.0, 128.0, 1.0,
		float(Globals.get_camera_option("bottom_edge_margin")), "%.0f px"
	)
	_add_camera_slider(
		box, "smoothing", "镜头平滑度", 3.0, 24.0, 1.0,
		float(Globals.get_camera_option("smoothing")), "%.0f"
	)
	_add_camera_slider(
		box, "zoom_step", "滚轮缩放速度", 0.25, 3.0, 0.25,
		float(Globals.get_camera_option("zoom_step")), "%.2fx"
	)

	var hint := Label.new()
	hint.text = "提示：当前 Demo 仅保留键盘平移；平滑度越高，镜头响应越直接。"
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.modulate = Color(0.78, 0.82, 0.88)
	box.add_child(hint)

	var reset_button := Button.new()
	reset_button.text = "恢复镜头默认值"
	reset_button.pressed.connect(_on_reset_camera_pressed)
	box.add_child(reset_button)


func _build_audio_settings():
	var audio_panel := PanelContainer.new()
	audio_panel.name = "AudioSettings"
	_settings_box.add_child(audio_panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 12)
	margin.add_theme_constant_override("margin_top", 12)
	margin.add_theme_constant_override("margin_right", 12)
	margin.add_theme_constant_override("margin_bottom", 12)
	audio_panel.add_child(margin)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	margin.add_child(box)

	var title := Label.new()
	title.text = "音频"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 22)
	box.add_child(title)

	_add_audio_slider(box, "master", "主音量")
	_add_audio_slider(box, "sfx", "音效")
	_add_audio_slider(box, "voice", "语音")
	_add_audio_slider(box, "music", "音乐")

	var hint := Label.new()
	hint.text = "音效和 BGM 为仓库脚本合成。旁白与应答为项目生成的中文语音。对局中设置不会切回菜单音乐。"
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.modulate = Color(0.78, 0.82, 0.88)
	box.add_child(hint)

	var reset_button := Button.new()
	reset_button.text = "恢复音频默认值"
	reset_button.pressed.connect(_on_reset_audio_pressed)
	box.add_child(reset_button)


func _add_audio_slider(parent: Control, key: String, label_text: String):
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	parent.add_child(row)

	var label := Label.new()
	label.text = label_text
	label.custom_minimum_size = Vector2(165, 0)
	row.add_child(label)

	var slider := HSlider.new()
	slider.min_value = 0.0
	slider.max_value = 100.0
	slider.step = 1.0
	slider.value = Globals.get_audio_option(key) * 100.0
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.custom_minimum_size = Vector2(250, 30)
	row.add_child(slider)

	var value_label := Label.new()
	value_label.custom_minimum_size = Vector2(78, 0)
	value_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	value_label.text = "%d%%" % int(slider.value)
	row.add_child(value_label)

	_audio_controls[key] = slider
	_audio_value_labels[key] = value_label
	slider.value_changed.connect(_on_audio_slider_changed.bind(key))


func _on_audio_slider_changed(value: float, key: String):
	Globals.set_audio_option(key, value / 100.0)
	_audio_value_labels[key].text = "%d%%" % int(value)
	_queue_save()


func _on_reset_audio_pressed():
	Globals.reset_audio_options()
	_audio_controls["master"].value = Globals.get_audio_option("master") * 100.0
	_audio_controls["sfx"].value = Globals.get_audio_option("sfx") * 100.0
	_audio_controls["voice"].value = Globals.get_audio_option("voice") * 100.0
	_audio_controls["music"].value = Globals.get_audio_option("music") * 100.0
	_queue_save()


func _add_camera_slider(
	parent: Control,
	key: String,
	label_text: String,
	min_value: float,
	max_value: float,
	step: float,
	initial_value: float,
	value_format: String
):
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	parent.add_child(row)

	var label := Label.new()
	label.text = label_text
	label.custom_minimum_size = Vector2(165, 0)
	row.add_child(label)

	var slider := HSlider.new()
	slider.min_value = min_value
	slider.max_value = max_value
	slider.step = step
	slider.value = initial_value
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.custom_minimum_size = Vector2(250, 30)
	row.add_child(slider)

	var value_label := Label.new()
	value_label.custom_minimum_size = Vector2(78, 0)
	value_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	value_label.text = value_format % initial_value
	row.add_child(value_label)

	_camera_controls[key] = slider
	_camera_value_labels[key] = [value_label, value_format]
	slider.value_changed.connect(_on_camera_slider_changed.bind(key))


func _on_camera_slider_changed(value: float, key: String):
	Globals.set_camera_option(key, value)
	var display = _camera_value_labels[key]
	display[0].text = display[1] % value
	_apply_camera_options_live()
	_queue_save()


func _on_camera_edge_scroll_toggled(enabled: bool):
	Globals.set_camera_option("edge_scroll_enabled", enabled)
	_apply_camera_options_live()
	_queue_save()


func _on_reset_camera_pressed():
	Globals.reset_camera_options()
	_camera_edge_scroll.button_pressed = bool(Globals.get_camera_option("edge_scroll_enabled"))
	_camera_controls["movement_speed"].value = float(Globals.get_camera_option("movement_speed"))
	_camera_controls["edge_margin"].value = float(Globals.get_camera_option("edge_margin"))
	_camera_controls["bottom_edge_margin"].value = float(Globals.get_camera_option("bottom_edge_margin"))
	_camera_controls["smoothing"].value = float(Globals.get_camera_option("smoothing"))
	_camera_controls["zoom_step"].value = float(Globals.get_camera_option("zoom_step"))
	_apply_camera_options_live()
	_queue_save()


func _apply_camera_options_live():
	var camera = get_tree().root.find_child("IsometricCamera3D", true, false)
	if camera != null and camera.has_method("_apply_user_camera_options"):
		camera.call("_apply_user_camera_options")


func _queue_save():
	_save_timer.start()


func _save_options():
	var save_error = ResourceSaver.save(Globals.options, Constants.OPTIONS_FILE_PATH)
	if save_error != OK:
		push_warning("无法保存显示设置：%s" % error_string(save_error))
	Globals.save_camera_options()
	Globals.save_audio_options()


func _on_mouse_movement_restricted_pressed():
	Globals.options.mouse_restricted = _mouse_movement_restricted.button_pressed
	_queue_save()


func _on_screen_item_selected(index):
	Globals.options.screen = {
		0: Globals.options.Screen.FULL,
		1: Globals.options.Screen.WINDOW,
	}[index]
	_queue_save()


func _on_back_button_pressed():
	_save_options()
	if embedded_mode:
		close_requested.emit()
		return
	get_tree().change_scene_to_file("res://source/main-menu/Main.tscn")
