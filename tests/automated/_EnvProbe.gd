extends Node

## R11：问引擎"你实际用哪块显卡 / 物理跑多快"（非侵入 ✓）
func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	print("[ENV] video_adapter = ", RenderingServer.get_video_adapter_name())
	print("[ENV] video_vendor  = ", RenderingServer.get_video_adapter_vendor())
	print("[ENV] api/version   = ", RenderingServer.get_video_adapter_api_version())
	print("[ENV] rendering_method = ", ProjectSettings.get_setting("rendering/renderer/rendering_method", "?"))
	print("[ENV] physics_ticks_per_second = ", Engine.physics_ticks_per_second)
	print("[ENV] max_fps = ", Engine.max_fps, " | vsync = ", DisplayServer.window_get_vsync_mode())
	print("[ENV] 屏幕数 = ", DisplayServer.get_screen_count(), " | 主屏 = ", DisplayServer.screen_get_size())
	for i in range(DisplayServer.get_screen_count()):
		print("[ENV]   屏#%d size=%s dpi=%s refresh=%s" % [i, str(DisplayServer.screen_get_size(i)), str(DisplayServer.screen_get_dpi(i)), str(DisplayServer.screen_get_refresh_rate(i))])
	# 实测物理帧率 ✓
	var f0 := Engine.get_physics_frames()
	var t0 := Time.get_ticks_usec()
	await get_tree().create_timer(2.0).timeout
	var df := Engine.get_physics_frames() - f0
	var dt := float(Time.get_ticks_usec() - t0) / 1000000.0
	print("[ENV] 实测物理帧率 = %.1f Hz（配置 %d ✓）" % [float(df) / dt, Engine.physics_ticks_per_second])
	print("[ENV] 实测渲染帧率 = %.1f Hz" % (float(Engine.get_frames_drawn()) / dt if Engine.get_frames_drawn() > 0 else -1.0))
	get_tree().quit(0)
