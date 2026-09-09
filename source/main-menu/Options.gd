extends Control

signal close_requested

const Options = preload("res://source/data-model/Options.gd")

@export var embedded_mode = false

@onready var _screen = find_child("Screen")
@onready var _resolution = find_child("Resolution")
@onready var _mouse_movement_restricted = find_child("MouseMovementRestricted")
@onready var _settings_box = $CenterContainer/PanelContainer/MarginContainer/ScrollContainer/VBoxContainer
@onready var _center = $CenterContainer
@onready var _panel = $CenterContainer/PanelContainer

var _save_timer: Timer
var _camera_edge_scroll: CheckBox
var _camera_controls := {}
var _camera_value_labels := {}
var _audio_sliders := {}
var _audio_value_labels := {}


func _ready():
	if embedded_mode:
		_prepare_embedded_mode()
		UISfx.play("ui_menu_open")  # 游戏内打开设置：菜单开音
	_setup_save_timer()
	_mouse_movement_restricted.button_pressed = Globals.options.mouse_restricted
	_screen.selected = Globals.options.screen
	_setup_resolution_options()
	_build_camera_settings()
	_build_audio_settings()
	# 内容构建完成后再 clamp（camera/audio 面板动态加进去后高度才稳定）。
	# 监听 size_changed 让窗口缩放/全屏切换时自动重排，防止未来再加设置项时跑屏外。
	_clamp_to_viewport()
	get_viewport().size_changed.connect(_clamp_to_viewport)
	UISfx.play("ui_plate")  # 设置面板展开落位音


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


func _setup_save_timer():
	_save_timer = Timer.new()
	_save_timer.one_shot = true
	_save_timer.wait_time = 0.25
	_save_timer.timeout.connect(_save_options)
	add_child(_save_timer)


## 防御性 viewport 适配：菜单面板用 CenterContainer 自适应居中 + 内层 ScrollContainer
## 自动滚动，但若 viewport 极端矮（如窗口被手动缩很小），仍要把 panel 高度 clamp 到
## viewport - 边距，防止标题/底部按钮跑到屏外。CenterContainer 已经把 PanelContainer
## 居中，所以这里只需要给 PanelContainer 一个最大高度上限。
func _clamp_to_viewport() -> void:
	if _panel == null or _center == null:
		return
	var viewport_rect := get_viewport().get_visible_rect()
	var top_margin := 40.0  # 上方留给标题栏/FPS 覆盖等
	var bottom_margin := 40.0
	var max_h := maxf(360.0, viewport_rect.size.y - top_margin - bottom_margin)
	# custom_minimum_size.y 设上限即可；CenterContainer 会基于 PanelContainer 的 min size 居中。
	# 横向不动（700 已够用），纵向不设下限避免空内容时面板塌缩。
	if _panel.custom_minimum_size.y != max_h:
		_panel.custom_minimum_size = Vector2(_panel.custom_minimum_size.x, max_h)


func _setup_resolution_options():
	_resolution.clear()
	for size in Options.RESOLUTION_OPTIONS:
		_resolution.add_item("%d x %d" % [size.x, size.y])
		_resolution.set_item_tooltip(
			_resolution.item_count - 1, "窗口大小 %d x %d" % [size.x, size.y]
		)
	var selected_index := Options.RESOLUTION_OPTIONS.find(Globals.options.resolution)
	_resolution.select(maxi(selected_index, 0))


func _build_camera_settings():
	var camera_panel := PanelContainer.new()
	camera_panel.name = "CameraSettings"
	_settings_box.add_child(camera_panel)
	_settings_box.move_child(camera_panel, _settings_box.get_child_count() - 2)

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


## 音频设置面板：背景音乐 / 人物语音音量（0-100%，实时生效并持久化）。
func _build_audio_settings():
	var audio_panel := PanelContainer.new()
	audio_panel.name = "AudioSettings"
	_settings_box.add_child(audio_panel)
	_settings_box.move_child(audio_panel, _settings_box.get_child_count() - 2)

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

	_add_audio_slider(box, "music_volume", "背景音乐音量")
	_add_audio_slider(box, "voice_volume", "人物语音音量")

	var hint := Label.new()
	hint.text = "提示：音量实时生效；0% 为静音。"
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.modulate = Color(0.78, 0.82, 0.88)
	box.add_child(hint)


func _add_audio_slider(parent: Control, key: String, label_text: String):
	var initial_percent := roundi(Globals.get_audio_volume(key) * 100.0)

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
	slider.step = 5.0
	slider.value = initial_percent
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.custom_minimum_size = Vector2(250, 30)
	row.add_child(slider)

	var value_label := Label.new()
	value_label.custom_minimum_size = Vector2(78, 0)
	value_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	value_label.text = "%d%%" % initial_percent
	row.add_child(value_label)

	_audio_sliders[key] = slider
	_audio_value_labels[key] = value_label
	slider.value_changed.connect(_on_audio_slider_changed.bind(key))


func _on_audio_slider_changed(value: float, key: String):
	Globals.set_audio_volume(key, value / 100.0)
	var value_label: Label = _audio_value_labels[key]
	value_label.text = "%d%%" % roundi(value)
	_queue_save()


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


func _on_resolution_item_selected(index):
	if index < 0 or index >= Options.RESOLUTION_OPTIONS.size():
		return
	Globals.options.resolution = Options.RESOLUTION_OPTIONS[index]
	_queue_save()


func _on_save_button_pressed():
	# 显式保存入口：显示/鼠标/镜头设置本已随改动自动落盘（options.tres + camera.cfg），
	# 此按钮提供确定感，并把当前 UI 状态完整写入存档（下次启动沿用）。
	_save_options()
	var save_button := find_child("SaveButton") as Button
	if save_button == null:
		return
	save_button.text = "已保存 ✓"
	save_button.disabled = true
	await get_tree().create_timer(1.2).timeout
	if is_instance_valid(save_button):
		save_button.text = "保存设置"
		save_button.disabled = false


func _on_back_button_pressed():
	_save_options()
	if embedded_mode:
		UISfx.play("ui_menu_close")  # 游戏内关闭设置：菜单关音
		close_requested.emit()
		return
	get_tree().change_scene_to_file("res://source/main-menu/Main.tscn")
