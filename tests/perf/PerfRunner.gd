extends Node

## 临时性能测试装置（2026-09-25 性能诊断专用，测完即删，不属于正式功能）。
## 职责：加载固定对局场景 → 运行时冻结 PerformanceGovernor / 解除帧率上限与
## VSync → 按命令行参数设置 scaling_3d_mode/scale（不改任何全局配置）→
## 预热 → 逐帧采样（帧时间/CPU/物理/绘制调用/显存/单位数）→ 截图 → 输出 JSON 退出。
## 用法：
##   godot --path . res://tests/perf/PerfRunner.tscn -- \
##     --scenario=battle --mode=fsr2 --scale=0.67 --warmup=20 --sample=60 \
##     --out=G:/AIRTS/tmp_logs/perf_20260925 --label=battle_fsr067_r1 \
##     --msaa=2 --expected=80

const SCENARIO_SCENES := {
	"small": "res://tests/perf/PerfSmall.tscn",
	"battle": "res://tests/perf/PerfBattle.tscn",
	"large": "res://tests/perf/PerfLarge.tscn",
}

var _cfg := {}
var _match: Node
var _sampling := false
var _last_frame_us := 0
var _frame_ms: PackedFloat64Array = []
var _proc_ms: PackedFloat64Array = []
var _phys_ms: PackedFloat64Array = []
var _phys_script_ms: PackedFloat64Array = []
var _draw_calls: PackedInt64Array = []
var _vram_mb: PackedFloat64Array = []
var _unit_snaps: Array = []
var _shot_files: Array = []
var _sustain_enabled := false
var _sustain_accum := 0.0


func _ready():
	_parse_args()
	var dir_ok := DirAccess.make_dir_recursive_absolute(_cfg["out"])
	if dir_ok != OK and dir_ok != ERR_ALREADY_EXISTS:
		push_error("无法创建输出目录: %s (%d)" % [_cfg["out"], dir_ok])
		get_tree().quit(2)
		return
	var scene_path: String = SCENARIO_SCENES.get(_cfg["scenario"], "")
	if scene_path == "" or ResourceLoader.exists(scene_path) == false:
		push_error("未知场景: %s" % _cfg["scenario"])
		get_tree().quit(2)
		return
	var packed: PackedScene = load(scene_path)
	_match = packed.instantiate()
	add_child(_match)
	_sustain_enabled = true
	_settle_window_and_mouse()
	await _wait_units_ready()
	_dump_diagnostics()
	_freeze_presentation()
	_apply_camera_override()
	await get_tree().create_timer(0.5).timeout
	_log_env()
	await _run_warmup()
	_begin_sampling()
	await _sample_loop()
	await _pan_burst_shots()
	_write_results()
	print("PERFJSON %s" % _result_path())
	get_tree().quit(0)


func _parse_args() -> void:
	_cfg = {
		"scenario": "battle", "mode": "bilinear", "scale": 1.0,
		"warmup": 20.0, "sample": 60.0, "out": "G:/AIRTS/tmp_logs/perf_20260925",
		"label": "run", "msaa": 2, "expected": 0, "cam_x": null, "cam_z": null,
	}
	for arg in OS.get_cmdline_user_args():
		if not arg.begins_with("--"):
			continue
		var kv := arg.substr(2).split("=", true, 1)
		if kv.size() != 2:
			continue
		var key: String = kv[0]
		var value: String = kv[1]
		if key == "scenario" or key == "mode" or key == "out" or key == "label":
			_cfg[key] = value
		elif key == "scale":
			_cfg[key] = value.to_float()
		elif key == "warmup" or key == "sample":
			_cfg[key] = value.to_float()
		elif key == "msaa" or key == "expected":
			_cfg[key] = value.to_int()
		elif key == "cam_x" or key == "cam_z":
			_cfg[key] = value.to_float()


func _settle_window_and_mouse() -> void:
	# 锁定输出分辨率（--resolution 可能被窗口管理器改写）并把鼠标拉回中心：
	# 相机开着边缘滚动（edge_scroll），鼠标停在窗口边缘会把镜头慢慢拉走
	# （2026-09-25 首次验证实测：120s 等待期相机被拖出战场，截图全空）。
	DisplayServer.window_set_size(Vector2i(1920, 1080))
	DisplayServer.window_set_position(Vector2i(0, 0))
	var camera := _match.get_node_or_null("IsometricCamera3D")
	if camera != null and "edge_scroll_enabled" in camera:
		camera.edge_scroll_enabled = false
	await get_tree().process_frame
	DisplayServer.warp_mouse(Vector2i(960, 540))
	await get_tree().process_frame
	print("[PERF] window=%dx%d mouse warped to center" % [
		DisplayServer.window_get_size().x, DisplayServer.window_get_size().y])


func _wait_units_ready() -> void:
	var waited := 0.0
	var target := int(_cfg["expected"])
	while waited < 120.0:
		await get_tree().create_timer(0.5).timeout
		waited += 0.5
		var count := get_tree().get_nodes_in_group("units").size()
		if target > 0 and count >= target:
			print("[PERF] units ready: %d (expected %d) after %.1fs" % [count, target, waited])
			return
	print("[PERF] WARNING: units ready timeout, count=%d expected=%d" % [
		get_tree().get_nodes_in_group("units").size(), target])


## 冻结动态画质并解除帧率限制（运行时，不改全局配置；PerformanceGovernor 关闭后
## 不会再覆盖渲染设置 —— 全代码只有它写 max_fps/scaling_3d/vsync）。
func _freeze_presentation() -> void:
	var governor := get_node_or_null("/root/PerformanceGovernor")
	if governor != null and governor.has_method("set_enabled"):
		governor.set_enabled(false)          # 还原其启动时的覆盖并停用动态换档
	Engine.max_fps = 0
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	var vp := get_viewport()
	if _cfg["mode"] == "fsr2":
		vp.scaling_3d_mode = Viewport.SCALING_3D_MODE_FSR2
	else:
		vp.scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
	vp.scaling_3d_scale = float(_cfg["scale"])
	vp.msaa_3d = int(_cfg["msaa"])
	print("[PERF] presentation frozen: mode=%s scale=%.2f msaa=%d max_fps=%d vsync=%d readback(mode=%d scale=%.2f)" % [
		str(_cfg["mode"]), float(_cfg["scale"]), int(_cfg["msaa"]),
		Engine.max_fps, DisplayServer.window_get_vsync_mode(),
		vp.scaling_3d_mode, vp.scaling_3d_scale])


func _apply_camera_override() -> void:
	if _cfg["cam_x"] == null or _cfg["cam_z"] == null:
		return
	var camera := _match.get_node_or_null("IsometricCamera3D")
	if camera == null:
		return
	camera.set_position_safely(Vector3(float(_cfg["cam_x"]), 0.0, float(_cfg["cam_z"])))
	print("[PERF] camera overridden to (%.1f, %.1f)" % [float(_cfg["cam_x"]), float(_cfg["cam_z"])])


func _log_env() -> void:
	var vp := get_viewport()
	var rendering_method := str(ProjectSettings.get_setting("rendering/renderer/rendering_method"))
	if RenderingServer.has_method("get_current_rendering_method"):
		rendering_method = str(RenderingServer.get_current_rendering_method())
	print("[PERF] godot=%s gpu=%s api=%s window=%dx%d scaling_mode=%d scale=%.2f msaa=%d max_fps=%d vsync=%d" % [
		Engine.get_version_info()["string"],
		RenderingServer.get_video_adapter_name(),
		rendering_method,
		DisplayServer.window_get_size().x, DisplayServer.window_get_size().y,
		vp.scaling_3d_mode, vp.scaling_3d_scale, vp.msaa_3d,
		Engine.max_fps, DisplayServer.window_get_vsync_mode()])


func _run_warmup() -> void:
	var elapsed := 0.0
	var next_sustain := 0.0
	while elapsed < float(_cfg["warmup"]):
		await get_tree().create_timer(0.5).timeout
		elapsed += 0.5
		next_sustain += 0.5
		if next_sustain >= 2.0:
			next_sustain = 0.0
			_sustain_armies()


func _sustain_armies() -> void:
	if _cfg["scenario"] != "battle":
		return
	for unit in get_tree().get_nodes_in_group("units"):
		if is_instance_valid(unit) and "hp" in unit and "hp_max" in unit:
			unit.hp = unit.hp_max


func _dump_diagnostics() -> void:
	var counts := {}
	for unit in get_tree().get_nodes_in_group("units"):
		var parent_name: String = unit.get_parent().name if unit.get_parent() != null else "?"
		counts[parent_name] = int(counts.get(parent_name, 0)) + 1
	print("[PERF][DIAG] units group by parent: %s" % str(counts))
	for player_path in ["Players/Human", "Players/Enemy"]:
		var player := _match.get_node_or_null(player_path)
		if player == null:
			print("[PERF][DIAG] %s MISSING" % player_path)
			continue
		var child_names := []
		for child in player.get_children():
			child_names.append("%s(%s)" % [child.name, child.get_class()])
		print("[PERF][DIAG] %s children[%d]: %s" % [player_path, child_names.size(),
			", ".join(child_names)])
	var camera := _match.get_node_or_null("IsometricCamera3D")
	if camera != null:
		print("[PERF][DIAG] camera pos=%s rot=%s" % [camera.global_position,
			camera.global_rotation_degrees])
	await RenderingServer.frame_post_draw
	_shot("%s_ready" % str(_cfg["label"]))


func _begin_sampling() -> void:
	_last_frame_us = Time.get_ticks_usec()
	_sampling = true
	print("[PERF] sampling begins")


func _process(_delta) -> void:
	# 战斗场景从 add_child 起每帧回血：0.5s 间隙挡不住集火爆发（实测 88→52 减员），
	# 每帧置满 HP 才能让混战负载在整个采样窗保持稳定（开销 ~88 次属性写/帧，可忽略）。
	if _sustain_enabled:
		_sustain_armies()
	if not _sampling:
		return
	var now := Time.get_ticks_usec()
	var dt_ms := float(now - _last_frame_us) / 1000.0
	_last_frame_us = now
	if dt_ms <= 0.0 or dt_ms > 500.0:      # 采样窗口内的异常长帧（读盘/断点）单独保留但不计入
		return
	_frame_ms.append(dt_ms)
	_proc_ms.append(Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0)
	_draw_calls.append(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
	_vram_mb.append(Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0)


func _physics_process(_delta) -> void:
	if _sustain_enabled:
		_sustain_armies()
	if not _sampling:
		return
	_phys_ms.append(Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0)
	if _match != null and "last_physics_script_ms" in _match:
		_phys_script_ms.append(float(_match.last_physics_script_ms))


func _sample_loop() -> void:
	var t0 := Time.get_ticks_usec()
	var sample_s := float(_cfg["sample"])
	var next_shot := 15.0
	var next_units := 0.0
	var next_sustain := 0.0
	while true:
		await get_tree().process_frame
		var elapsed := float(Time.get_ticks_usec() - t0) / 1e6
		if elapsed >= sample_s:
			break
		# 单位数快照（每 2s）
		if elapsed >= next_units:
			next_units += 2.0
			var units := get_tree().get_nodes_in_group("units")
			var hp := 0.0
			for unit in units:
				if is_instance_valid(unit) and "hp" in unit:
					hp += float(unit.hp)
			_unit_snaps.append([snappedf(elapsed, 0.1), units.size(), snappedf(hp, 1.0)])
		# 战斗场景持续回血，保持负载稳定（见报告"方法"节）
		if elapsed >= next_sustain:
			next_sustain += 2.0
			_sustain_armies()
		# 采样中段截图（每 60s 窗口 2 张，读回瞬时 stall 已在报告中说明）
		if elapsed >= next_shot and next_shot < sample_s:
			next_shot += 25.0
			await RenderingServer.frame_post_draw
			_shot("%s_mid%d" % [str(_cfg["label"]), int(elapsed)])
	_sampling = false
	print("[PERF] sampling done: %d frames" % _frame_ms.size())


func _shot(shot_name: String) -> void:
	var img := get_viewport().get_texture().get_image()
	var path := "%s/%s.png" % [_cfg["out"], shot_name]
	img.save_png(path)
	_shot_files.append(path)


## 采样结束后水平平移镜头连拍 6 张：动态拖影/闪烁的人工检查素材。
func _pan_burst_shots() -> void:
	var camera := _match.get_node_or_null("IsometricCamera3D")
	if camera == null:
		return
	var base: Vector3 = camera.global_position
	for i in range(6):
		camera.set_position_safely(base + Vector3(float(i) * 2.0, 0.0, 0.0))
		await RenderingServer.frame_post_draw
		_shot("%s_pan%d" % [str(_cfg["label"]), i])
	camera.set_position_safely(base)


func _result_path() -> String:
	return "%s/%s.json" % [_cfg["out"], _cfg["label"]]


static func _percentile(sorted_values: Array, p: float) -> float:
	if sorted_values.is_empty():
		return 0.0
	var idx := int(round(p * 0.01 * float(sorted_values.size() - 1)))
	idx = clampi(idx, 0, sorted_values.size() - 1)
	return float(sorted_values[idx])


static func _avg(values: Array) -> float:
	if values.is_empty():
		return 0.0
	var total := 0.0
	for v in values:
		total += float(v)
	return total / float(values.size())


func _write_results() -> void:
	var sorted_ft := Array(_frame_ms)
	sorted_ft.sort()
	var sorted_proc := Array(_proc_ms)
	sorted_proc.sort()
	var n := sorted_ft.size()
	var worst1_count := maxi(1, int(float(n) / 100.0))
	var worst1 := sorted_ft.slice(n - worst1_count, n)
	var worst1_avg_ms := _avg(worst1)
	var unit_counts := []
	for snap in _unit_snaps:
		unit_counts.append(int(snap[1]))
	var result := {
		"label": _cfg["label"], "scenario": _cfg["scenario"],
		"mode": _cfg["mode"], "scale": float(_cfg["scale"]), "msaa": int(_cfg["msaa"]),
		"warmup_s": float(_cfg["warmup"]), "sample_s": float(_cfg["sample"]),
		"godot": Engine.get_version_info()["string"],
		"gpu_adapter": RenderingServer.get_video_adapter_name(),
		"rendering_method": str(ProjectSettings.get_setting("rendering/renderer/rendering_method")),
		"window_size": [DisplayServer.window_get_size().x, DisplayServer.window_get_size().y],
		"scaling_mode_readback": get_viewport().scaling_3d_mode,
		"scaling_scale_readback": get_viewport().scaling_3d_scale,
		"max_fps": Engine.max_fps,
		"vsync_mode": DisplayServer.window_get_vsync_mode(),
		"frames": n,
		"fps_avg": 0.0 if n == 0 else 1000.0 / _avg(sorted_ft),
		"fps_1pct_low": 0.0 if n == 0 else 1000.0 / worst1_avg_ms,
		"frame_ms_p50": snappedf(_percentile(sorted_ft, 50), 0.01),
		"frame_ms_p95": snappedf(_percentile(sorted_ft, 95), 0.01),
		"frame_ms_p99": snappedf(_percentile(sorted_ft, 99), 0.01),
		"frame_ms_max": snappedf(float(sorted_ft[n - 1]) if n > 0 else 0.0, 0.01),
		"cpu_process_ms_avg": snappedf(_avg(_proc_ms), 0.01),
		"cpu_process_ms_p95": snappedf(_percentile(sorted_proc, 95), 0.01),
		"physics_ms_avg": snappedf(_avg(_phys_ms), 0.01),
		"physics_script_ms_avg": snappedf(_avg(_phys_script_ms), 0.01),
		"draw_calls_avg": int(_avg(_draw_calls)),
		"vram_mb_avg": snappedf(_avg(_vram_mb), 1.0),
		"units_min": 0 if unit_counts.is_empty() else int(unit_counts.min()),
		"units_max": 0 if unit_counts.is_empty() else int(unit_counts.max()),
		"unit_snaps": _unit_snaps,
		"screenshots": _shot_files,
		"generated_at": Time.get_datetime_string_from_system(),
	}
	var file := FileAccess.open(_result_path(), FileAccess.WRITE)
	file.store_string(JSON.stringify(result, "  "))
	file.close()
	print("[PERF] result: fps=%.1f 1%%low=%.1f p50=%.2fms p95=%.2fms p99=%.2fms cpu=%.2fms draw=%d" % [
		float(result["fps_avg"]), float(result["fps_1pct_low"]),
		float(result["frame_ms_p50"]), float(result["frame_ms_p95"]),
		float(result["frame_ms_p99"]), float(result["cpu_process_ms_avg"]),
		int(result["draw_calls_avg"])])
