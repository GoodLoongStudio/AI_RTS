extends Node

## 实机验证：窗口模式下"改分辨率"到底有没有改窗口。
## 用法（必须带窗口；窗口移到屏幕外，不抢前台）：
##   ..._console.exe --path . --windowed --position -4000,-4000 res://tools/probe_resolution_live.tscn

func _ready() -> void:
	# 先把窗口挪到屏幕外，避免抢前台
	DisplayServer.window_set_position(Vector2i(-4000, -4000))
	await _run()


func _step(tag: String) -> void:
	var win := get_window()
	print("[%s] mode=%s size=%s pos=%s viewport=%s" % [
		tag,
		str(DisplayServer.window_get_mode()),
		str(DisplayServer.window_get_size()),
		str(DisplayServer.window_get_position()),
		str(get_viewport().get_visible_rect().size),
	])


func _run() -> void:
	print("===== PROBE LIVE BEGIN =====")
	print("[env] display server = ", DisplayServer.get_name())
	print("[env] usable rect    = ", DisplayServer.screen_get_usable_rect(DisplayServer.SCREEN_OF_MAIN_WINDOW))
	print("[env] decorations    = ", DisplayServer.window_get_size_with_decorations() - DisplayServer.window_get_size())
	_step("initial")
	print("[store] screen = ", Globals.options.screen, " resolution = ", Globals.options.resolution)

	print("--- 模拟：设置面板里选 1280 x 720 ---")
	Globals.options.resolution = Vector2i(1280, 720)
	await get_tree().process_frame
	await get_tree().process_frame
	await get_tree().process_frame
	_step("after_1280x720")
	print("[store] resolution = ", Globals.options.resolution)

	print("--- 模拟：设置面板里选 960 x 1080 ---")
	Globals.options.resolution = Vector2i(960, 1080)
	await get_tree().process_frame
	await get_tree().process_frame
	await get_tree().process_frame
	_step("after_960x1080")
	print("[store] resolution = ", Globals.options.resolution)

	print("--- 注意：不实测 screen=FULL（会无边框全屏抢占前台）。 ---")
	print("--- 该路径的正确性由代码判定：Options._apply_resolution() 首行 ---")
	print("---   if screen != Screen.WINDOW: return   -> 全屏时改分辨率 100% 被忽略 ---")

	print("===== PROBE LIVE END =====")
	get_tree().quit()
