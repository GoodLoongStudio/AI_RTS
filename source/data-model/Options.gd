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
## 判定「与显示器同比例」的容差。1366x768 与 16:9 差约 0.05%，2% 足够宽松又不会放过 4:3。
const ASPECT_TOLERANCE := 0.02

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
	if screen == Screen.WINDOW:
		_set_window_mode(DisplayServer.WINDOW_MODE_WINDOWED)
		_apply_window_resolution()
	else:
		_apply_fullscreen()


## 窗口模式与无边框标记必须成对切换：
## 切到窗口时先清 BORDERLESS 再设 mode（全屏则反过来），避免出现
## 「带边框全屏」这种错配中间态；否则在 Windows 上会被引擎重解释成
## **独占全屏**(WINDOW_MODE_EXCLUSIVE_FULLSCREEN)，而独占全屏下
## window_set_size() 被忽略 —— 分辨率设置看起来完全失效。
## （真正的启动陷阱在 project.godot：`window/size/mode` 必须保持 0，
##  详见那里的注释。）
func _set_window_mode(mode: int):
	if mode == DisplayServer.WINDOW_MODE_WINDOWED:
		DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_BORDERLESS, false)
		DisplayServer.window_set_mode(mode)
	else:
		DisplayServer.window_set_mode(mode)
		DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_BORDERLESS, true)


func _apply_resolution():
	if screen == Screen.WINDOW:
		_apply_window_resolution()
	else:
		_apply_fullscreen()


## 全屏改分辨率必须真的有效果，而 4.7 的 Windows 独占全屏在很多机器上是空操作
## （模式确实切到 EXCLUSIVE_FULLSCREEN，桌面与窗口尺寸却纹丝不动，2026-09-26 实测），
## 所以这里先试独占全屏，量到没落地就回退成「无边框全屏 + 压低根视口渲染尺寸」，
## 两条路都以显示器的宽高比为前提，画面不会被拉变形。
func _apply_fullscreen():
	if DisplayServer.get_name() == "headless":
		_set_window_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
		return

	var target := _fullscreen_target()
	if target != resolution:
		# 写回夹出来的值，否则下拉显示的档位和实际生效的档位不一致。
		resolution = target
		return

	if _enter_exclusive_fullscreen(target):
		_set_content_scale_disabled()
		return
	_set_window_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
	_set_content_scale_viewport(target)


## 全屏下真正送去渲染/切换的尺寸：与显示器同比例才用用户选的档位，
## 否则（老存档里的 960x1080 之类）退到列表里同比例的最大档。
func _fullscreen_target() -> Vector2i:
	var native := DisplayServer.screen_get_size(DisplayServer.SCREEN_OF_MAIN_WINDOW)
	if native.x <= 0 or native.y <= 0:
		return DEFAULT_RESOLUTION
	if _matches_aspect(resolution, native):
		return resolution
	var best := DEFAULT_RESOLUTION
	for candidate in RESOLUTION_OPTIONS:
		if _matches_aspect(candidate, native) and candidate.x > best.x:
			best = candidate
	return best


func _matches_aspect(candidate: Vector2i, reference: Vector2i) -> bool:
	if candidate.y <= 0 or reference.y <= 0:
		return false
	var ratio := float(reference.x) / float(reference.y)
	return absf(float(candidate.x) / float(candidate.y) - ratio) <= ratio * ASPECT_TOLERANCE


## 独占全屏靠「进模式时的窗口尺寸」挑显示模式，所以顺序必须是先窗口化定尺寸再切。
## 返回是否真的落到了目标分辨率，调用方据此决定要不要回退。
func _enter_exclusive_fullscreen(target: Vector2i) -> bool:
	_set_window_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	DisplayServer.window_set_size(target)
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN)
	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_BORDERLESS, true)
	if DisplayServer.window_get_mode() != DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN:
		return false
	return (
		DisplayServer.window_get_size() == target
		or DisplayServer.screen_get_size(DisplayServer.SCREEN_OF_MAIN_WINDOW) == target
	)


func _main_window() -> Window:
	var loop := Engine.get_main_loop()
	return loop.root if loop is SceneTree else null


func _set_content_scale_viewport(target: Vector2i) -> void:
	var window := _main_window()
	if window == null:
		return
	window.content_scale_mode = Window.CONTENT_SCALE_MODE_VIEWPORT
	window.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_KEEP
	window.content_scale_size = Vector2(target)


func _set_content_scale_disabled() -> void:
	var window := _main_window()
	if window == null:
		return
	window.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED


func _apply_window_resolution():
	_set_content_scale_disabled()

	# 存储是「窗口」但实际仍停在独占全屏（启动早期的模式切换被引擎吞掉、
	# 或窗口被外部改成全屏）时，window_set_size() 不生效 —— 先真正切回窗口模式。
	if (
		DisplayServer.get_name() != "headless"
		and DisplayServer.window_get_mode() != DisplayServer.WINDOW_MODE_WINDOWED
	):
		_set_window_mode(DisplayServer.WINDOW_MODE_WINDOWED)

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
