extends Control

@onready var _logos = find_child("Logos")


func _ready():
	# 独立运行时默认贴靠屏幕左侧，占用一半宽度，给 Codex/日志窗口
	# 留出右侧空间；嵌入 Godot 编辑器时这些调用由引擎忽略。
	call_deferred("_place_window_left_half")
	if NetSession.try_start_from_cmdline():
		if _logos != null:
			_logos.queue_free()
		var status := Label.new()
		status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		status.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		status.set_anchors_preset(Control.PRESET_FULL_RECT)
		status.text = NetSession.get_status()
		# 用对象方法的 Callable，而不是闭包：闭包捕获的标签被释放后，emit 会报
		# "Lambda capture at index 0 was freed"（2026-09-10 服务器因客户端断线崩溃的根因）；
		# 对象方法 Callable 在对象销毁时自动断开连接。
		NetSession.status_changed.connect(status.set_text)
		add_child(status)
		return
	_logos.tree_exited.connect(
		get_tree().change_scene_to_file.bind("res://source/main-menu/Main.tscn")
	)


func _place_window_left_half() -> void:
	if Engine.is_editor_hint() or DisplayServer.get_name() == "headless":
		return
	var screen := DisplayServer.screen_get_size()
	if screen.x <= 0 or screen.y <= 0:
		return
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	DisplayServer.window_set_position(Vector2i.ZERO)
	DisplayServer.window_set_size(Vector2i(maxi(640, screen.x / 2), screen.y))
