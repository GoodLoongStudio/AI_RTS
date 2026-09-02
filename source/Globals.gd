extends Node

const Options = preload("res://source/data-model/Options.gd")
const OPTION_PROPERTIES := ["screen", "mouse_restricted"]
const CAMERA_CONFIG_PATH := "user://camera.cfg"
const CAMERA_CONFIG_SECTION := "camera"
const AUDIO_CONFIG_PATH := "user://audio.cfg"
const AUDIO_CONFIG_SECTION := "audio"
const CAMERA_DEFAULTS := {
	"edge_scroll_enabled": true,
	"movement_speed": 1.35,
	"edge_margin": 48.0,
	"bottom_edge_margin": 72.0,
	"smoothing": 10.0,
	"zoom_step": 1.0,
}
const AUDIO_DEFAULTS := {
	"master": 1.0,
	"music": 0.8,
	"sfx": 0.8,
	"voice": 0.85,
}

var options = _load_and_migrate_options()
var camera_options: Dictionary = _load_camera_options()
var audio_options: Dictionary = _load_audio_options()
var god_mode = false
var cache = {}


func _load_and_migrate_options():
	# Display/mouse settings keep using the legacy Resource. We instantiate the latest
	# schema first so old user://options.tres files cannot remove newly expected fields.
	var current_options = Options.new()
	if not ResourceLoader.exists(Constants.OPTIONS_FILE_PATH):
		return current_options

	var stored_options = load(Constants.OPTIONS_FILE_PATH)
	if stored_options == null:
		return current_options

	var stored_property_names := {}
	for property in stored_options.get_property_list():
		stored_property_names[str(property.get("name", ""))] = true

	for property_name in OPTION_PROPERTIES:
		if stored_property_names.has(property_name):
			current_options.set(property_name, stored_options.get(property_name))

	var save_error = ResourceSaver.save(current_options, Constants.OPTIONS_FILE_PATH)
	if save_error != OK:
		push_warning("无法保存迁移后的显示设置：%s" % error_string(save_error))
	return current_options


func _load_camera_options() -> Dictionary:
	var loaded := CAMERA_DEFAULTS.duplicate(true)
	var config := ConfigFile.new()
	var load_error := config.load(CAMERA_CONFIG_PATH)
	if load_error != OK:
		return loaded

	for key in CAMERA_DEFAULTS.keys():
		loaded[key] = config.get_value(CAMERA_CONFIG_SECTION, key, CAMERA_DEFAULTS[key])
	return _sanitize_camera_options(loaded)


func _sanitize_camera_options(values: Dictionary) -> Dictionary:
	return {
		"edge_scroll_enabled": bool(values.get("edge_scroll_enabled", true)),
		"movement_speed": clamp(float(values.get("movement_speed", 1.35)), 0.4, 3.0),
		"edge_margin": clamp(float(values.get("edge_margin", 48.0)), 16.0, 96.0),
		"bottom_edge_margin": clamp(float(values.get("bottom_edge_margin", 72.0)), 24.0, 128.0),
		"smoothing": clamp(float(values.get("smoothing", 10.0)), 3.0, 24.0),
		"zoom_step": clamp(float(values.get("zoom_step", 1.0)), 0.25, 3.0),
	}


func get_camera_option(key: String):
	return camera_options.get(key, CAMERA_DEFAULTS.get(key))


func set_camera_option(key: String, value):
	if not CAMERA_DEFAULTS.has(key):
		push_warning("未知镜头设置：%s" % key)
		return
	camera_options[key] = value
	camera_options = _sanitize_camera_options(camera_options)


func save_camera_options():
	var config := ConfigFile.new()
	for key in CAMERA_DEFAULTS.keys():
		config.set_value(CAMERA_CONFIG_SECTION, key, camera_options[key])
	var save_error := config.save(CAMERA_CONFIG_PATH)
	if save_error != OK:
		push_warning("无法保存镜头设置：%s" % error_string(save_error))


func reset_camera_options():
	camera_options = CAMERA_DEFAULTS.duplicate(true)
	save_camera_options()


func _ready():
	apply_audio_buses()


func _load_audio_options() -> Dictionary:
	var loaded := AUDIO_DEFAULTS.duplicate(true)
	var config := ConfigFile.new()
	if config.load(AUDIO_CONFIG_PATH) != OK:
		return loaded
	for key in AUDIO_DEFAULTS.keys():
		loaded[key] = config.get_value(AUDIO_CONFIG_SECTION, key, AUDIO_DEFAULTS[key])
	return _sanitize_audio_options(loaded)


func _sanitize_audio_options(values: Dictionary) -> Dictionary:
	return {
		"master": clampf(float(values.get("master", 1.0)), 0.0, 1.0),
		"music": clampf(float(values.get("music", 0.5)), 0.0, 1.0),
		"sfx": clampf(float(values.get("sfx", 0.8)), 0.0, 1.0),
		"voice": clampf(float(values.get("voice", 0.85)), 0.0, 1.0),
	}


func get_audio_option(key: String) -> float:
	return float(audio_options.get(key, AUDIO_DEFAULTS.get(key, 1.0)))


func set_audio_option(key: String, value: float):
	if not AUDIO_DEFAULTS.has(key):
		push_warning("未知音频设置：%s" % key)
		return
	audio_options[key] = value
	audio_options = _sanitize_audio_options(audio_options)
	apply_audio_buses()


func save_audio_options():
	var config := ConfigFile.new()
	for key in AUDIO_DEFAULTS.keys():
		config.set_value(AUDIO_CONFIG_SECTION, key, audio_options[key])
	var save_error := config.save(AUDIO_CONFIG_PATH)
	if save_error != OK:
		push_warning("无法保存音频设置：%s" % error_string(save_error))


func reset_audio_options():
	audio_options = AUDIO_DEFAULTS.duplicate(true)
	apply_audio_buses()
	save_audio_options()


## 把线性音量写到 Master/Music/Sfx/Voice 总线。
func apply_audio_buses():
	_apply_bus_linear("Master", get_audio_option("master"))
	_apply_bus_linear("Music", get_audio_option("music"))
	_apply_bus_linear("Sfx", get_audio_option("sfx"))
	_apply_bus_linear("Voice", get_audio_option("voice"))


func _apply_bus_linear(bus_name: String, linear: float):
	var bus_index := AudioServer.get_bus_index(bus_name)
	if bus_index < 0:
		return
	var volume := clampf(linear, 0.0, 1.0)
	AudioServer.set_bus_mute(bus_index, volume <= 0.0001)
	AudioServer.set_bus_volume_db(bus_index, linear_to_db(maxf(volume, 0.0001)))


func _unhandled_input(event):
	if event.is_action_pressed("toggle_god_mode"):
		_toggle_god_mode()


func _toggle_god_mode():
	if not FeatureFlags.god_mode:
		return
	god_mode = not god_mode
	if god_mode:
		Signals.god_mode_enabled.emit()
	else:
		Signals.god_mode_disabled.emit()
