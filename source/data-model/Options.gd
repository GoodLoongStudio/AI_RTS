extends Resource

enum Screen { FULL = 0, WINDOW = 1 }

@export var screen: Screen = Screen.FULL:
	set = _set_screen
@export var mouse_restricted = false:
	set = _set_mouse_restricted

# RTS camera preferences. These stay in the same user:// options resource as the
# existing display settings, so old save files simply receive the defaults below.
@export_category("Camera")
@export var camera_edge_scroll_enabled := true
@export_range(0.4, 3.0, 0.1) var camera_movement_speed := 1.1
@export_range(16.0, 96.0, 1.0) var camera_edge_margin := 48.0
@export_range(24.0, 128.0, 1.0) var camera_bottom_edge_margin := 72.0
@export_range(3.0, 24.0, 1.0) var camera_smoothing := 10.0
@export_range(0.25, 3.0, 0.25) var camera_zoom_step := 1.0


func _init():
	_apply_stored_options()


func _set_screen(value):
	screen = value
	_apply_screen()


func _set_mouse_restricted(value):
	mouse_restricted = value
	_apply_mouse_restricted()


func _apply_stored_options():
	_apply_screen()
	_apply_mouse_restricted()


func _apply_screen():
	DisplayServer.window_set_mode(
		(
			DisplayServer.WINDOW_MODE_FULLSCREEN
			if screen == Screen.FULL
			else DisplayServer.WINDOW_MODE_WINDOWED
		)
	)


func _apply_mouse_restricted():
	if mouse_restricted:
		Input.set_mouse_mode(Input.MOUSE_MODE_CONFINED)
	else:
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)


func reset_camera_to_defaults():
	camera_edge_scroll_enabled = true
	camera_movement_speed = 1.1
	camera_edge_margin = 48.0
	camera_bottom_edge_margin = 72.0
	camera_smoothing = 10.0
	camera_zoom_step = 1.0
