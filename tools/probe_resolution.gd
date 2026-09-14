extends Node

const Options = preload("res://source/data-model/Options.gd")

## 诊断探针：确认"分辨率设置不生效"的根因。
## 用法（headless，只读逻辑值）：
##   Godot_v4.7.1-stable_mono_win64_console.exe --headless --path . res://tools/probe_resolution.tscn
## 用法（带窗口，实测 window_set_size 对 viewport 的影响，窗口移到屏幕外不抢前台）：
##   ..._console.exe --path . --position -4000,-4000 res://tools/probe_resolution.tscn

func _ready() -> void:
	await _run()


func _run() -> void:
	print("===== PROBE RESOLUTION BEGIN =====")
	var ds_name := DisplayServer.get_name()
	print("[env] display server = ", ds_name)

	print("[project] viewport_width  = ", ProjectSettings.get_setting("display/window/size/viewport_width"))
	print("[project] viewport_height = ", ProjectSettings.get_setting("display/window/size/viewport_height"))
	print("[project] window_width_override  = ", ProjectSettings.get_setting("display/window/size/window_width_override", "<unset>"))
	print("[project] window_height_override = ", ProjectSettings.get_setting("display/window/size/window_height_override", "<unset>"))
	print("[project] size/mode       = ", ProjectSettings.get_setting("display/window/size/mode", "<unset>"))
	print("[project] stretch/mode    = ", ProjectSettings.get_setting("display/window/stretch/mode", "<unset>"))
	print("[project] stretch/aspect  = ", ProjectSettings.get_setting("display/window/stretch/aspect", "<unset>"))
	print("[project] stretch/scale   = ", ProjectSettings.get_setting("display/window/stretch/scale", "<unset>"))

	print("[options] file path        = ", Constants.OPTIONS_FILE_PATH)
	print("[options] file exists      = ", ResourceLoader.exists(Constants.OPTIONS_FILE_PATH))
	print("[options] screen (0=FULL,1=WINDOW) = ", Globals.options.screen)
	print("[options] resolution       = ", Globals.options.resolution)
	print("[options] res in list idx  = ", Options.RESOLUTION_OPTIONS.find(Globals.options.resolution))

	var scene: PackedScene = load("res://source/main-menu/Options.tscn")
	var inst: Control = scene.instantiate()
	add_child(inst)
	await get_tree().process_frame
	await get_tree().process_frame

	var res_btn: OptionButton = inst.find_child("Resolution", true, false)
	var scr_btn: OptionButton = inst.find_child("Screen", true, false)
	if res_btn != null:
		print("[ui] Resolution item_count = ", res_btn.item_count, " selected = ", res_btn.selected,
			" text = '", res_btn.get_item_text(res_btn.selected), "' disabled = ", res_btn.disabled)
	else:
		print("[ui] Resolution NOT FOUND")
	if scr_btn != null:
		print("[ui] Screen selected = ", scr_btn.selected, " text = '", scr_btn.get_item_text(scr_btn.selected), "'")
	else:
		print("[ui] Screen NOT FOUND")

	print("[win] window size       = ", DisplayServer.window_get_size())
	print("[win] viewport visible = ", get_viewport().get_visible_rect().size)
	if ds_name != "headless":
		print("[win] usable rect     = ", DisplayServer.screen_get_usable_rect(DisplayServer.SCREEN_OF_MAIN_WINDOW))

	if ds_name != "headless":
		# 关键实验：把窗口设成 1280x720，看 viewport 逻辑尺寸是否跟着变。
		# stretch=canvas_items 时 viewport 会**保持不变**（固定 1920x1080），
		# 只有窗口被缩放 —— 这就是"分辨率设置看起来没用"的机制。
		DisplayServer.window_set_size(Vector2i(1280, 720))
		await get_tree().process_frame
		await get_tree().process_frame
		print("[test] after window_set_size(1280x720):")
		print("[test]   window size    = ", DisplayServer.window_get_size())
		print("[test]   viewport rect  = ", get_viewport().get_visible_rect().size)
		DisplayServer.window_set_size(Vector2i(1600, 900))
		await get_tree().process_frame
		await get_tree().process_frame
		print("[test] after window_set_size(1600x900):")
		print("[test]   window size    = ", DisplayServer.window_get_size())
		print("[test]   viewport rect  = ", get_viewport().get_visible_rect().size)

	print("===== PROBE RESOLUTION END =====")
	get_tree().quit()
