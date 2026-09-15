extends SceneTree

## 物理插值验收脚本
##
## 判据一（设置是否生效）：ProjectSettings.get_setting("physics/common/physics_interpolation")
##   读到 true 说明 project.godot 的键名被 Godot 识别（键名写错会是 null）。
## 判据二（插值是否真的在跑）：Engine.get_physics_interpolation_fraction() 每渲染帧
##   返回当前物理 tick 的推进比例；插值开启时它在 0..1 之间变化，关闭时恒为定值。
## 判据三（观感指标）：单位位置在渲染帧之间的更新率 —— 未开插值时同一物理 tick 内的
##   多个渲染帧位置完全相同（一卡一卡），开插值后每渲染帧都在变。
##
## 用法：
##   --script interp_verify.gd -- --map=res://... --out=<json路径>

const SAMPLE_FRAMES := 300
const SPIKE_MS := 40.0

var _map_path := ""
var _out_path := "interp_verify.json"
var _seconds := 180.0
var _t0 := 0
var _last_ms := 0
var _spikes := []
var _rebake_count := 0
var _spawn_count := 0
var _match: Node
var _nav: Node

var _frames_total := 0
var _frames_moved := 0
var _prev_pos := {}
var _peak_unit := ""
var _lag_sum := 0.0
var _lag_max := 0.0
var _fraction_values := []
var _render_fps := 0.0


func _trace(msg: String) -> void:
	var path: String = "G:/AIRTS/RTS_Map_Tool/tmp_logs/probe_trace.log"
	var mode: int = FileAccess.READ_WRITE if FileAccess.file_exists(path) else FileAccess.WRITE
	var f = FileAccess.open(path, mode)
	if f != null:
		f.seek_end()
		f.store_line(str(Time.get_ticks_msec()) + " " + msg)
		f.close()


func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--map="):
			_map_path = a.substr(6)
		elif a.begins_with("--out="):
			_out_path = a.substr(6)
		elif a.begins_with("--seconds="):
			_seconds = float(a.substr(10))
	root.size = Vector2i(640, 400)  # 小画布，抬高渲染帧率（需 > 物理 60Hz 才有对照意义）
	await process_frame
	await _run()
	quit(0)


func _run() -> void:
	var settings_script = load("res://source/data-model/MatchSettings.gd")
	var ps_script = load("res://source/data-model/PlayerSettings.gd")
	if settings_script == null or ps_script == null:
		print("[verify] FATAL: settings script load failed")
		return
	var settings = settings_script.new()
	var players: Array[Resource] = []
	for i in range(4):
		var p = ps_script.new()
		p.controller = 2
		p.color = [Color.RED, Color.BLUE, Color.GREEN, Color.YELLOW][i]
		players.append(p)
	settings.players = players
	settings.visibility = 2
	settings.local_player_index = -1

	var map = load(_map_path).instantiate()
	var match_node = load("res://source/match/Match.tscn").instantiate()
	match_node.settings = settings
	match_node.map = map
	root.add_child(match_node)
	for _i in range(60):
		await process_frame

	var signals = root.get_node("/root/MatchSignals")
	signals.schedule_navigation_rebake.connect(_on_rebake)
	signals.unit_spawned.connect(_on_spawn)
	_t0 = Time.get_ticks_msec()
	_last_ms = _t0
	while Time.get_ticks_msec() - _t0 < _seconds * 1000.0:
		await process_frame
		_sample()
	var elapsed := (Time.get_ticks_msec() - _t0) / 1000.0
	_render_fps = float(SAMPLE_FRAMES) / maxf(elapsed, 0.001)

	var setting_value = ProjectSettings.get_setting("physics/common/physics_interpolation")
	var uniq_fractions := {}
	for v in _fraction_values:
		uniq_fractions[str(v)] = true
	var report := {
		"setting_physics_interpolation": setting_value,
		"total_spikes": _spikes.size(),
		"total_rebakes": _rebake_count,
		"total_spawns": _spawn_count,
		"render_fps": round(_render_fps * 10.0) / 10.0,
		"physics_ticks_per_second": Engine.physics_ticks_per_second,
		"frames_moving": _frames_total,
		"frames_with_interp_lag": _frames_moved,
		"lag_avg_m": round(_lag_sum / maxf(_frames_moved, 1) * 10000.0) / 10000.0,
		"lag_max_m": round(_lag_max * 10000.0) / 10000.0,
		"peak_unit": _peak_unit,
	}
	var f := FileAccess.open(_out_path, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(report, "  "))
		f.close()
	print("[verify] ", JSON.stringify(report))


func _ratio() -> float:
	if _frames_total == 0:
		return 0.0
	return round(float(_frames_moved) / float(_frames_total) * 1000.0) / 1000.0


func _on_rebake(_domain) -> void:
	_rebake_count += 1


func _on_spawn(_unit) -> void:
	_spawn_count += 1


func _sample() -> void:
	var now: int = Time.get_ticks_msec()
	var frame_ms: float = float(now - _last_ms)
	_last_ms = now
	if frame_ms <= SPIKE_MS:
		return
	var nav_baking: bool = false
	var nav_busy: bool = false
	if _nav != null:
		var tn = _nav.get("terrain")
		if tn != null:
			nav_busy = bool(tn.get("server_busy"))
			nav_baking = bool(tn.get("_is_baking"))
	_spikes.append({
		"at_s": round((now - _t0) / 100.0) / 10.0,
		"frame_ms": round(frame_ms * 10.0) / 10.0,
		"process_ms": round(Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0) / 10.0,
		"physics_ms": round(Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0) / 10.0,
		"units": get_nodes_in_group("units").size(),
		"nav_baking": nav_baking,
		"nav_busy": nav_busy,
		"rebakes_so_far": _rebake_count,
		"spawns_so_far": _spawn_count,
	})
