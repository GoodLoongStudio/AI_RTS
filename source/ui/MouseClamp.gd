extends Node

## 「鼠标限制在游戏窗口内」的实现（2026-10-12 重写）。
##
## 为什么不再用 Input.MOUSE_MODE_CONFINED：
##   它依赖 Windows 的 ClipCursor（系统级矩形裁剪）。而导出版进程是 SystemAware
##   （Godot 运行时自行设定，exe manifest 注入 PerMonitorV2 实测不生效），在显示
##   缩放非 100% 的机器上（笔记本常见的 125%/150%），系统会把窗口/鼠标坐标虚拟化，
##   Godot 传出的 clip 矩形与窗口物理区域错位 —— 表现为：
##     · 光标能"漏出"窗口（限制失效）；
##     · 漏出后点击，实际落在窗口的物理矩形内被游戏吞掉（桌面无响应）。
##   朋友在笔记本上实测复现。
##
## 现在的做法：每帧在 **Godot 自己的坐标系**（DisplayServer 的窗口/鼠标坐标，
## SystemAware 进程下两者同处虚拟坐标系、彼此自洽）内做钳制，再用
## mouse_set_position 写回（Windows 负责把虚拟坐标换算成物理坐标）。
## 绕开了 ClipCursor 的坐标转换问题，任何 DPI 缩放下都正确。
##
## 只在窗口拥有焦点时工作：失焦后玩家理应能自由操作桌面。
## 只干预 MOUSE_MODE_VISIBLE：对局内相机/拖拽的 captured/hidden 状态不碰。

var _window_focused := true


func _ready() -> void:
	# 暂停菜单/设置页打开时游戏树是 paused 的，限制仍要生效。
	process_mode = Node.PROCESS_MODE_ALWAYS


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_WINDOW_FOCUS_IN:
		_window_focused = true
	elif what == NOTIFICATION_WM_WINDOW_FOCUS_OUT:
		_window_focused = false


func _process(_delta: float) -> void:
	if not _window_focused:
		return
	if Globals.options == null or not Globals.options.mouse_restricted:
		return
	if Input.mouse_mode != Input.MOUSE_MODE_VISIBLE:
		return
	var mouse_pos := DisplayServer.mouse_get_position()   # 屏幕坐标（虚拟系）
	var win_pos := DisplayServer.window_get_position()
	var win_size := DisplayServer.window_get_size()
	if win_size.x <= 0 or win_size.y <= 0:
		return
	# Input.warp_mouse 接收的是 viewport（窗口内）坐标，先换算再钳制。
	# （DisplayServer.mouse_set_position 在 4.7 无法从 GDScript 静态调用。）
	var rel := mouse_pos - win_pos
	var hi := win_size - Vector2i.ONE
	var clamped_rel := rel.clamp(Vector2i.ZERO, hi)
	if clamped_rel != rel:
		Input.warp_mouse(clamped_rel)
