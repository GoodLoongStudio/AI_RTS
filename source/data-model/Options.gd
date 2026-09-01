extends Resource

enum Screen { FULL = 0, WINDOW = 1 }

const DEFAULT_RESOLUTION := Vector2i(1920, 1080)
const RESOLUTION_OPTIONS := [
	Vector2i(960, 1080),
	Vector2i(1280, 720),
	Vector2i(1366, 768),
	Vector2i(1600, 900),
	Vector2i(1920, 1080),
	Vector2i(2560, 1440),
	Vector2i(3840, 2160),
]

@export var screen: Screen = Screen.FULL:
	set = _set_screen
@export var resolution: Vector2i = DEFAULT_RESOLUTION:
	set = _set_resolution
@export var mouse_restricted = false:
	set = _set_mouse_restricted


func _init():
	_apply_stored_options()


func _set_screen(value):
	screen = value
	_apply_screen()


func _set_resolution(value):
	resolution = _sanitize_resolution(value)
	_apply_resolution()


func _set_mouse_restricted(value):
	mouse_restricted = value
	_apply_mouse_restricted()


func _apply_stored_options():
	_apply_screen()
	_apply_mouse_restricted()


func _apply_screen():
	var mode := (
		DisplayServer.WINDOW_MODE_FULLSCREEN
		if screen == Screen.FULL
		else DisplayServer.WINDOW_MODE_WINDOWED
	)
	DisplayServer.window_set_mode(mode)
	# Godot 强制全屏无边框；切回窗口时必须显式恢复系统标题栏和边框。
	DisplayServer.window_set_flag(
		DisplayServer.WINDOW_FLAG_BORDERLESS,
		mode == DisplayServer.WINDOW_MODE_FULLSCREEN
	)
	if mode == DisplayServer.WINDOW_MODE_WINDOWED:
		_apply_resolution()


func _apply_resolution():
	if screen != Screen.WINDOW:
		return

	var target_size := resolution
	var usable_rect := DisplayServer.screen_get_usable_rect(DisplayServer.SCREEN_OF_MAIN_WINDOW)
	if usable_rect.size.x > 0 and usable_rect.size.y > 0 and DisplayServer.get_name() != "headless":
		# The resolution is the client area; reserve room for the title bar and borders.
		var decoration_size := (
			DisplayServer.window_get_size_with_decorations()
			- DisplayServer.window_get_size()
		)
		decoration_size.x = maxi(decoration_size.x, 0)
		decoration_size.y = maxi(decoration_size.y, 0)
		var max_client_size := usable_rect.size - decoration_size
		if max_client_size.x > 0 and max_client_size.y > 0:
			var fit_scale := minf(
				1.0,
				minf(
					float(max_client_size.x) / float(target_size.x),
					float(max_client_size.y) / float(target_size.y)
				)
			)
			if fit_scale < 1.0:
				target_size = Vector2i(
					maxi(1, floori(float(target_size.x) * fit_scale)),
					maxi(1, floori(float(target_size.y) * fit_scale))
				)

	DisplayServer.window_set_size(target_size)
	if usable_rect.size.x > 0 and usable_rect.size.y > 0 and DisplayServer.get_name() != "headless":
		_center_window_in_usable_rect(usable_rect)


func _center_window_in_usable_rect(usable_rect: Rect2i):
	var outer_size := DisplayServer.window_get_size_with_decorations()
	if outer_size.x <= 0 or outer_size.y <= 0:
		return
	var decoration_size := outer_size - DisplayServer.window_get_size()
	decoration_size.x = maxi(decoration_size.x, 0)
	decoration_size.y = maxi(decoration_size.y, 0)
	var available_space := usable_rect.size - outer_size
	var position := usable_rect.position + Vector2i(
		floori(float(available_space.x) / 2.0),
		floori(float(available_space.y) / 2.0)
	)
	# Godot positions the client area; reserve decoration space so the outer frame
	# (especially the title bar) never starts outside the usable screen rectangle.
	position += decoration_size
	var max_position := usable_rect.position + usable_rect.size - outer_size + decoration_size
	position.x = clampi(position.x, usable_rect.position.x, maxi(max_position.x, usable_rect.position.x))
	position.y = clampi(position.y, usable_rect.position.y, maxi(max_position.y, usable_rect.position.y))
	DisplayServer.window_set_position(position)


func _sanitize_resolution(value) -> Vector2i:
	if not (value is Vector2i or value is Vector2):
		return DEFAULT_RESOLUTION
	var candidate := Vector2i(value)
	if candidate in RESOLUTION_OPTIONS:
		return candidate
	return DEFAULT_RESOLUTION


func _apply_mouse_restricted():
	if mouse_restricted:
		Input.set_mouse_mode(Input.MOUSE_MODE_CONFINED)
	else:
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
