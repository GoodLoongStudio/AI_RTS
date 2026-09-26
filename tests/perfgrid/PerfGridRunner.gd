extends Node

## 临时性能对照装置（2026-09-26 索敌优化第一轮，性能报告数据源）。
## 场景在运行时构建（Match.tscn + MatchSettings + 地图 + 双方单位），
## 命令行参数控制场景/版本/时长；版本经 AIRTS_TARGETING 环境变量由外层驱动设置：
##   A=baseline（旧全场扫描+无错峰）  B=nostagger（仅网格）  C=默认（网格+错峰）
## 输出 JSON（唯一 run_id，不覆盖旧文件）+ 帧时原始数组 + 索敌计数器 + GPU 渲染计时探针。

const UNIT_SCENES := {
	"tank": "res://source/match/units/Tank.tscn",
	"heavy": "res://source/match/units/HeavyTank.tscn",
	"infantry": "res://source/match/units/Infantry.tscn",
	"apc": "res://source/match/units/APC.tscn",
	"sniper": "res://source/match/units/Sniper.tscn",
	"helicopter": "res://source/match/units/Helicopter.tscn",
}

var _cfg := {}
var _match: Node
var _grid: Node
var _sampling := false
var _last_frame_us := 0
var _frame_ms: PackedFloat64Array = []
var _render_cpu_ms: PackedFloat64Array = []
var _render_gpu_ms: PackedFloat64Array = []
var _unit_snaps: Array = []
var _render_time_supported := false
var _mid_shots := {}


func _save_shot(index: int) -> void:
	var img := get_viewport().get_texture().get_image()
	img.save_png("%s/%s_shot%d.png" % [_cfg["out"], _cfg["label"], index])


func _ready():
	_parse_args()
	DirAccess.make_dir_recursive_absolute(_cfg["out"])
	await _build_scenario()
	if not bool(_cfg["keep_defaults"]):
		# 对照测量口径：解除帧率上限/VSync、冻结动态画质（仅测试进程内）。
		# --keep-defaults 时保留游戏默认（30 帧上限 + 治理器）做流畅度实测。
		_freeze_presentation()
	await get_tree().create_timer(0.5).timeout
	_log_env()
	await _run_warmup()
	_diagnose_layout()
	_begin_sampling()
	await _sample_loop()
	_write_results()
	print("PERFJSON %s" % _result_path())
	get_tree().quit(0)


func _parse_args() -> void:
	_cfg = {
		"scenario": "idle200", "warmup": 20.0, "sample": 60.0,
		"out": "G:/AIRTS/tmp_logs/perf_grid_20260926", "label": "run",
		"keep_defaults": false,
	}
	for arg in OS.get_cmdline_user_args():
		if not arg.begins_with("--"):
			continue
		var kv := arg.substr(2).split("=", true, 1)
		if kv.size() != 2:
			continue
		match kv[0]:
			"scenario", "out", "label":
				_cfg[kv[0]] = kv[1]
			"warmup", "sample":
				_cfg[kv[0]] = kv[1].to_float()
	if "--keep-defaults" in OS.get_cmdline_user_args():
		_cfg["keep_defaults"] = true
	# 测试进程内关闭终局判定：idle 场景只有一方玩家，避免"全灭胜利"面板中断采样。
	FeatureFlags.set("handle_match_end", false)


## 场景来自预生成的 tscn（tests/perfgrid/gen_perfgrid_scenes.py），
## 保证迷雾/HUD 等子系统的节点 owned 语义与真实对局一致。
func _build_scenario() -> void:
	var scenario: String = _cfg["scenario"]
	# 场景名到场景文件的显式映射（不用 capitalize()：它会在数字边界插空格）。
	var scene_names := {
		"idle200": "PerfGridIdle200", "idle400": "PerfGridIdle400",
		"battle200": "PerfGridBattle200", "move200": "PerfGridMove200",
		"g4idle200": "PerfGridG4Idle200", "g4idle400": "PerfGridG4Idle400",
		"g4battle200": "PerfGridG4Battle200", "g4move200": "PerfGridG4Move200",
	}
	var scene_name: String = scene_names.get(scenario, "")
	var scene_path := "res://tests/perfgrid/%s.tscn" % scene_name
	var packed: PackedScene = load(scene_path)
	if packed == null:
		push_error("场景加载失败: %s" % scene_path)
		get_tree().quit(2)
		return
	_match = packed.instantiate()
	add_child(_match)
	# G4 场景单位全部经真实出场入口运行时生成（_setup_and_spawn_unit 自带贴地
	# 校正）：tscn 预置 y=0 在 G4 高度图上会滑聚/丢失（2026-09-26 实测 200→59，
	# 用户截图确认单位挤在角落）。出生点锚定地图自带的 SpawnPoints 标记。
	if scenario.begins_with("g4"):
		await get_tree().process_frame
		var human := _match.get_node("Players/Human")
		var enemy := _match.get_node_or_null("Players/Enemy")
		# seed_35 实测可行走区只有 (51-99, 59-100) 这一个口袋（其他 SpawnPoints
		# 标记点外的单位会自动走到最近可行走区，实测 8 秒内跨图滑动）。
		# 全部场景锚定在口袋内；战斗双方相邻摆放（块心距 9.4m < 块宽）即开打。
		match scenario:
			"g4idle200":
				_spawn_army(human, Vector3(60, 0, 92), 100)
				_spawn_army(human, Vector3(72, 0, 86), 100)
			"g4idle400":
				_spawn_army(human, Vector3(62, 0, 90), 100)
				_spawn_army(human, Vector3(74, 0, 84), 100)
				_spawn_army(human, Vector3(68, 0, 96), 100)
				_spawn_army(human, Vector3(80, 0, 90), 100)
			"g4battle200":
				_spawn_army(human, Vector3(60, 0, 92), 100, true)
				if enemy != null:
					_spawn_army(enemy, Vector3(68, 0, 97), 100, true)
			"g4move200":
				_spawn_army(human, Vector3(62, 0, 95), 100)
				_spawn_army(human, Vector3(75, 0, 85), 100)
	# 移动场景的命令在树内下发（gateway 才能解析）。
	if scenario.contains("move"):
		var move_counts := {"move200": 200, "g4move200": 200}
		await _wait_units_ready(int(move_counts.get(scenario, 200)))
		var human := _match.get_node("Players/Human")
		var gateway := human.get_node("UnitCommandGateway")
		var units: Array = get_tree().get_nodes_in_group("controlled_units")
		gateway.SetFirePolicy(units, "HoldFire", human)
		gateway.GroundAttackMoveUnits(units, Vector3(154, 0, 60), human)
	_grid = _match.get_node_or_null("TargetAcquisitionGrid")


const G4_ROSTER := [
	"res://source/match/units/Tank.tscn", "res://source/match/units/HeavyTank.tscn",
	"res://source/match/units/Infantry.tscn", "res://source/match/units/APC.tscn",
	"res://source/match/units/Sniper.tscn",
]


## 在单个中心点周围生成 count 个单位（10 列方格，间距 2.2m），走真实出场入口。
## 战斗单位在出场后放大生命值（HP 为 C# 权威，出场前赋值会被出生管线重置；
## 出场后赋值随首次伤害结算被读取，交战贯穿整个采样窗且双方数量保持一致）。
func _spawn_army(player: Node, center: Vector3, count: int, battle_hp_boost: bool = false) -> void:
	var cols := 10
	for i in range(count):
		var row := i / cols
		var col := i % cols
		var pos := center + Vector3(col * 2.2 - (cols - 1) * 1.1, 0, row * 2.2 - 1.1)
		var unit: Node = load(G4_ROSTER[i % G4_ROSTER.size()]).instantiate()
		_match._setup_and_spawn_unit(unit, Transform3D(Basis(), pos), player)
		if battle_hp_boost and "hp_max" in unit:
			unit.hp_max = unit.hp_max * 80.0
			unit.hp = unit.hp_max


## 把 count 个单位均摊到多个出生点标记周围。
func _spawn_army_around_markers(player: Node, markers: Array, count: int) -> void:
	var per_marker := int(ceil(float(count) / float(markers.size())))
	var spawned := 0
	for marker in markers:
		var n := mini(per_marker, count - spawned)
		if n <= 0:
			break
		_spawn_army(player, marker, n)
		spawned += n


func _wait_units_ready(expected: int) -> void:
	var waited := 0.0
	while waited < 60.0:
		await get_tree().create_timer(0.5).timeout
		waited += 0.5
		if get_tree().get_nodes_in_group("units").size() >= expected:
			return
	push_warning("units ready timeout: %d/%d" % [
		get_tree().get_nodes_in_group("units").size(), expected])


func _freeze_presentation() -> void:
	var governor := get_node_or_null("/root/PerformanceGovernor")
	if governor != null and governor.has_method("set_enabled"):
		governor.set_enabled(false)   # 运行时冻结动态画质（测试进程内，不落盘）
	Engine.max_fps = 0
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	DisplayServer.window_set_size(Vector2i(1920, 1080))
	DisplayServer.window_set_position(Vector2i(0, 0))
	var camera := _match.get_node_or_null("IsometricCamera3D")
	if camera != null and "edge_scroll_enabled" in camera:
		camera.edge_scroll_enabled = false
	var vp := get_viewport()
	vp.scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
	vp.scaling_3d_scale = 1.0
	vp.msaa_3d = 2
	await get_tree().process_frame
	DisplayServer.warp_mouse(Vector2i(960, 540))
	# GPU 渲染计时探针（先核实本版本接口；GPU 渲染计时 ≠ 整系统帧时间）。
	_render_time_supported = RenderingServer.has_method("viewport_set_measure_render_time") \
		and RenderingServer.has_method("viewport_get_measured_render_time_cpu") \
		and RenderingServer.has_method("viewport_get_measured_render_time_gpu")
	if _render_time_supported:
		RenderingServer.viewport_set_measure_render_time(vp.get_viewport_rid(), true)
	print("[PERFGRID] render_time_probe supported=%s (set=%s cpu_get=%s gpu_get=%s)" % [
		_render_time_supported,
		RenderingServer.has_method("viewport_set_measure_render_time"),
		RenderingServer.has_method("viewport_get_measured_render_time_cpu"),
		RenderingServer.has_method("viewport_get_measured_render_time_gpu")])


func _log_env() -> void:
	print("[PERFGRID] godot=%s gpu=%s window=%dx%d vsync=%d max_fps=%d grid_stats=%s" % [
		Engine.get_version_info()["string"], RenderingServer.get_video_adapter_name(),
		DisplayServer.window_get_size().x, DisplayServer.window_get_size().y,
		DisplayServer.window_get_vsync_mode(), Engine.max_fps,
		str(_grid_stats())])


func _grid_stats() -> Dictionary:
	if _grid == null:
		return {"available": false}
	var snapshot: Dictionary = _grid.stats.duplicate()
	snapshot["available"] = true
	snapshot["use_grid"] = _grid.use_grid
	snapshot["use_stagger"] = _grid.use_stagger
	return snapshot


func _run_warmup() -> void:
	var elapsed := 0.0
	while elapsed < float(_cfg["warmup"]):
		await get_tree().create_timer(0.5).timeout
		elapsed += 0.5


## 采样前一次性诊断：单位实际散布（G4 高度图上 y=0 出生会滑聚成团，需可观测）。
func _diagnose_layout() -> void:
	var units := get_tree().get_nodes_in_group("units")
	if units.is_empty():
		return
	var lo := Vector3(1e9, 1e9, 1e9)
	var hi := Vector3(-1e9, -1e9, -1e9)
	for unit in units:
		if is_instance_valid(unit):
			var p: Vector3 = unit.global_position
			lo = lo.min(p)
			hi = hi.max(p)
	print("[PERFGRID] layout bbox min=%s max=%s size=%s units=%d" % [lo, hi, hi - lo, units.size()])
	for marker in [Vector3(62, 0, 95), Vector3(154, 0, 60), Vector3(186, 0, 161), Vector3(99, 0, 198)]:
		var nearby := 0
		for unit in units:
			if is_instance_valid(unit) and \
					unit.global_position.distance_to(marker) < 15.0:
				nearby += 1
		print("[PERFGRID] marker %s nearby_units=%d" % [marker, nearby])


func _begin_sampling() -> void:
	if _grid != null:
		_grid.reset_stats()
	_last_frame_us = Time.get_ticks_usec()
	_sampling = true


func _process(_delta) -> void:
	if not _sampling:
		return
	var now := Time.get_ticks_usec()
	var dt_ms := float(now - _last_frame_us) / 1000.0
	_last_frame_us = now
	if dt_ms <= 0.0 or dt_ms > 500.0:
		return
	_frame_ms.append(dt_ms)


func _sample_loop() -> void:
	var t0 := Time.get_ticks_usec()
	var sample_s := float(_cfg["sample"])
	var next_units := 0.0
	var next_rt := 0.0
	while true:
		await get_tree().process_frame
		var elapsed := float(Time.get_ticks_usec() - t0) / 1e6
		if elapsed >= sample_s:
			break
		if elapsed >= next_units:
			next_units += 2.0
			var units := get_tree().get_nodes_in_group("units")
			_unit_snaps.append([snappedf(elapsed, 0.1), units.size()])
		# 采样中段截图（60s 窗口 2 张；读回瞬时 stall 影响 ~1 帧，报告中说明）。
		if elapsed >= 5.0 and not _mid_shots.has(1):
			_mid_shots[1] = true
			await RenderingServer.frame_post_draw
			_save_shot(1)
		elif elapsed >= 40.0 and not _mid_shots.has(2):
			_mid_shots[2] = true
			await RenderingServer.frame_post_draw
			_save_shot(2)
		# GPU 渲染计时必须在渲染帧完成后读取（frame_post_draw 之后），
		# 以 0.5s 低频采样避免逐帧等待引入停顿。
		if _render_time_supported and elapsed >= next_rt:
			next_rt += 0.5
			await RenderingServer.frame_post_draw
			var rid := get_viewport().get_viewport_rid()
			var cpu_ms := RenderingServer.viewport_get_measured_render_time_cpu(rid) / 1000.0
			var gpu_ms := RenderingServer.viewport_get_measured_render_time_gpu(rid) / 1000.0
			if cpu_ms > 0.0:
				_render_cpu_ms.append(cpu_ms)
			if gpu_ms > 0.0:
				_render_gpu_ms.append(gpu_ms)


func _result_path() -> String:
	return "%s/%s.json" % [_cfg["out"], _cfg["label"]]


static func _percentile(values: Array, p: float) -> float:
	if values.is_empty():
		return 0.0
	var idx := clampi(int(round(p * 0.01 * float(values.size() - 1))), 0, values.size() - 1)
	return float(values[idx])


static func _avg(values: Array) -> float:
	if values.is_empty():
		return 0.0
	var total := 0.0
	for v in values:
		total += float(v)
	return total / float(values.size())


static func _file_hash(path: String) -> String:
	if FileAccess.file_exists(path):
		return FileAccess.get_md5(path)
	return "n/a"


func _write_results() -> void:
	var sorted_ft := Array(_frame_ms)
	sorted_ft.sort()
	var n := sorted_ft.size()
	var worst1 := sorted_ft.slice(n - maxi(1, int(n / 100.0)), n)
	var worst1_avg := _avg(worst1)
	var sorted_cpu := Array(_render_cpu_ms)
	sorted_cpu.sort()
	var sorted_gpu := Array(_render_gpu_ms)
	sorted_gpu.sort()
	var grid_stats := _grid_stats()
	grid_stats["label_at_end"] = str(_cfg["label"])
	var result := {
		"run_id": str(_cfg["label"]),
		"scenario": _cfg["scenario"],
		"godot": Engine.get_version_info()["string"],
		"gpu_adapter": RenderingServer.get_video_adapter_name(),
		"window_size": [DisplayServer.window_get_size().x, DisplayServer.window_get_size().y],
		"max_fps": Engine.max_fps, "vsync": DisplayServer.window_get_vsync_mode(),
		"render_time_supported": _render_time_supported,
		"warmup_s": float(_cfg["warmup"]), "sample_s": float(_cfg["sample"]),
		"frames": n,
		"fps_avg": 0.0 if n == 0 else 1000.0 / _avg(sorted_ft),
		"fps_1pct_low": 0.0 if n == 0 else 1000.0 / worst1_avg,
		"frame_ms_p50": snappedf(_percentile(sorted_ft, 50), 0.01),
		"frame_ms_p95": snappedf(_percentile(sorted_ft, 95), 0.01),
		"frame_ms_p99": snappedf(_percentile(sorted_ft, 99), 0.01),
		"frame_ms_all": Array(_frame_ms),
		"render_cpu_ms_avg": snappedf(_avg(_render_cpu_ms), 0.01),
		"render_cpu_ms_p95": snappedf(_percentile(sorted_cpu, 95), 0.01),
		"render_gpu_ms_avg": snappedf(_avg(_render_gpu_ms), 0.01),
		"render_gpu_ms_p95": snappedf(_percentile(sorted_gpu, 95), 0.01),
		"units_start": 0 if _unit_snaps.is_empty() else int(_unit_snaps[0][1]),
		"units_end": 0 if _unit_snaps.is_empty() else int(_unit_snaps[-1][1]),
		"unit_snaps": _unit_snaps,
		"targeting_stats": grid_stats,
		"code_hashes": {
			"WaitingForTargets": _file_hash("res://source/match/units/actions/WaitingForTargets.gd"),
			"TargetAcquisitionGrid": _file_hash("res://source/match/TargetAcquisitionGrid.gd"),
			"Match": _file_hash("res://source/match/Match.gd"),
		},
		"generated_at": Time.get_datetime_string_from_system(),
	}
	var file := FileAccess.open(_result_path(), FileAccess.WRITE)
	file.store_string(JSON.stringify(result, "  "))
	file.close()
	print("[PERFGRID] fps=%.1f 1low=%.1f p50=%.2f p95=%.2f p99=%.2f render_cpu=%.2f render_gpu=%.2f queries=%d cands=%d scan_us=%d maintain_us=%d" % [
		float(result["fps_avg"]), float(result["fps_1pct_low"]),
		float(result["frame_ms_p50"]), float(result["frame_ms_p95"]), float(result["frame_ms_p99"]),
		float(result["render_cpu_ms_avg"]), float(result["render_gpu_ms_avg"]),
		int(grid_stats.get("query_calls", 0)), int(grid_stats.get("candidates_returned", 0)),
		int(grid_stats.get("scan_time_us", 0)), int(grid_stats.get("index_maintain_us", 0))])
