extends Node

const Options = preload("res://source/data-model/Options.gd")
const OPTION_PROPERTIES := [
	"screen",
	"mouse_restricted",
	"camera_edge_scroll_enabled",
	"camera_movement_speed",
	"camera_edge_margin",
	"camera_bottom_edge_margin",
	"camera_smoothing",
	"camera_zoom_step",
]

var options = _load_and_migrate_options()
var god_mode = false
var cache = {}


func _load_and_migrate_options():
	# Always instantiate the latest schema first. Older user://options.tres files may
	# have been serialized before new settings existed, so using them directly makes
	# newly added properties inaccessible at runtime.
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

	# Persist the migrated resource so the next launch is already on the newest schema.
	var save_error = ResourceSaver.save(current_options, Constants.OPTIONS_FILE_PATH)
	if save_error != OK:
		push_warning("无法保存迁移后的设置文件：%s" % error_string(save_error))
	return current_options


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
