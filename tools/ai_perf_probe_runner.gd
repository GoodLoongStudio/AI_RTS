extends Node

## AI 对局性能探针（2026-10-11 整晚对局优化阶段一，测量专用）。
## 在无头真实 Match 里以 1/3 个电脑玩家运行，采样帧时间、模拟时钟、实体量与
## AIRTS_AI_PERF_STATS 插桩计数，结束时把 JSON 写到 --perf-out。
##
## 参数（--key=value）：
##   ai-count       电脑玩家数（1/3，默认 1）
##   frames         预热后采样的物理帧数（默认 5400 = 90s @60Hz）
##   warmup-frames  预热物理帧数（默认 300）
##   difficulty     难度（0 EASY / 1 NORMAL / 2 HARD，默认 1）
##   extra-units    每名玩家额外脚本单位数（默认 0；仅 A/B 负载对齐用）
##   perf-out       JSON 输出绝对路径（必填）
##   watchdog-s     墙钟看门狗秒数（默认 900）
##   run-id         局标识（写入 JSON）

const MATCH_SCENE_PATH := "res://source/match/Match.tscn"
const MATCH_TEST_SCRIPT := "res://tests/manual/Match.gd"
const MAP_SCENE := "res://source/match/maps/PlainAndSimple.tscn"
const HUMAN_SCENE := "res://source/match/players/human/Human.tscn"
const AI_SCENE := "res://source/match/players/simple-clairvoyant-ai/SimpleClairvoyantAI.tscn"
const SETTINGS_SCRIPT := "res://source/data-model/MatchSettings.gd"
const AiPerfStats = preload(
	"res://source/match/players/simple-clairvoyant-ai/AiPerfStats.gd")

const EXTRA_UNIT_SCENES := [
	"res://source/match/units/Worker.tscn",
	"res://source/match/units/Tank.tscn",
	"res://source/match/units/Helicopter.tscn",
	"res://source/match/units/Drone.tscn",
]

var _args := {
	"ai-count": 1,
	"frames": 5400,
	"warmup-frames": 300,
	"difficulty": 1,
	"extra-units": 0,
	"perf-out": "",
	"watchdog-s": 900.0,
	"run-id": "probe",
}

var _match = null
var _world_query_runtime = null
var _samples: Array[float] = []
var _wall_samples: Array[float] = []
var _last_process_us := 0
var _hitches: Array = []
var _rows := []
var _last_row_wall := 0.0
var _start_wall := 0.0
var _done := false
var _spawn_origins: Array[Vector3] = []
var _probe_dbg_done := false


func _parse_args() -> void:
	for raw in OS.get_cmdline_user_args():
		var eq := raw.find("=")
		if eq <= 0:
			continue
		var key := raw.substr(0, eq).trim_prefix("--")
		var value := raw.substr(eq + 1)
		if not _args.has(key):
			continue
		var current: Variant = _args[key]
		if typeof(current) == TYPE_INT or typeof(current) == TYPE_FLOAT:
			_args[key] = float(value)
		else:
			_args[key] = value


func _ready() -> void:
	_parse_args()
	if String(_args["perf-out"]).is_empty():
		push_error("ai_perf_probe: --perf-out 缺失")
		get_tree().quit(2)
		return
	_start_wall = Time.get_ticks_msec() / 1000.0
	_last_row_wall = _start_wall

	var match_scene: Node3D = load(MATCH_SCENE_PATH).instantiate()
	match_scene.set_script(load(MATCH_TEST_SCRIPT))
	match_scene.set("disable_match_end_for_test", true)
	var settings: Resource = load(SETTINGS_SCRIPT).new()
	settings.visibility = 0
	settings.local_player_index = -1
	match_scene.set("settings", settings)

	var map: Node = load(MAP_SCENE).instantiate()
	match_scene.add_child(map)
	var spawns := map.get_node_or_null("SpawnPoints")
	var spawn_origin := Vector3.ZERO
	if spawns != null and spawns.get_child_count() > 0:
		spawn_origin = (spawns.get_child(0) as Node3D).position

	var players := match_scene.get_node("Players")
	var human: Node = load(HUMAN_SCENE).instantiate()
	# 与真实对局同口径的起始资金（Match.gd `_create_players_from_settings`：
	# 所有玩家统一 10000，2026-09-15 用户设定）。必须在 add_child 之前设置
	# —— RegisterPlayer 会把场景导出数值作为唯一一次初始余额导入。
	human.set("resource_a", 10000)
	human.set("resource_b", 10000)
	players.add_child(human)
	_add_extra_units(human, spawn_origin)

	for index in range(int(_args["ai-count"])):
		var spawn_point_origin := spawn_origin
		if spawns != null and index + 1 < spawns.get_child_count():
			spawn_point_origin = (spawns.get_child(index + 1) as Node3D).position
		var ai: Node = load(AI_SCENE).instantiate()
		ai.set("difficulty", int(_args["difficulty"]))
		ai.set("resource_a", 10000)
		ai.set("resource_b", 10000)
		players.add_child(ai)
		_spawn_origins.append(spawn_point_origin)

	# 探针自己的 _ready 发生在根节点 add_child 尚未返回时，这时再给根加 Match
	# 会报 "Parent node is busy setting up children"，对局进不了树。
	# 等本帧收尾后再挂到根上，current_scene 的父节点仍然是根。
	call_deferred("_attach_match", match_scene)


func _attach_match(match_scene: Node) -> void:
	if match_scene == null or not is_instance_valid(match_scene):
		return
	var root := get_tree().root
	if match_scene.get_parent() == null:
		root.add_child(match_scene)
	_match = match_scene
	get_tree().current_scene = match_scene
	_world_query_runtime = match_scene.get_node_or_null("WorldQueryRuntime")
	print("AI_PERF_PROBE ready ai-count=%d frames=%d extra-units=%d" % [
		int(_args["ai-count"]), int(_args["frames"]), int(_args["extra-units"])])


func _add_extra_units(player: Node, origin: Vector3) -> void:
	var count := int(_args["extra-units"])
	for index in range(count):
		var scene_path: String = EXTRA_UNIT_SCENES[index % EXTRA_UNIT_SCENES.size()]
		var unit: Node3D = load(scene_path).instantiate()
		var ring := 3.0 + 2.5 * (index / 8)
		var angle := TAU * float(index % 8) / 8.0
		unit.position = origin + Vector3(cos(angle) * ring, 0.0, sin(angle) * ring)
		player.add_child(unit)


func _process(_delta: float) -> void:
	if _match == null or _done:
		return
	if get_tree().current_scene != _match:
		get_tree().current_scene = _match
	if not _probe_dbg_done:
		_probe_dbg_done = true
		var scene: Node = get_tree().current_scene
		print("[PROBE-DBG] current_scene=%s is_match=%s has_get_local=%s" % [
			scene.name if scene != null else "<null>",
			scene == _match,
			scene != null and scene.has_method("get_local_player")])
	if (Time.get_ticks_msec() / 1000.0) - _start_wall > float(_args["watchdog-s"]):
		_finish(true, "watchdog")
		return
	var frame := Engine.get_physics_frames()
	if frame < int(_args["warmup-frames"]):
		return
	if frame >= int(_args["warmup-frames"]) + int(_args["frames"]):
		_finish(false, "frames")
		return
	var frame_ms := _delta * 1000.0
	_samples.append(frame_ms)
	var now_us := Time.get_ticks_usec()
	if _last_process_us > 0:
		var wall_ms := float(now_us - _last_process_us) / 1000.0
		_wall_samples.append(wall_ms)
		if wall_ms >= 100.0 and _hitches.size() < 64:
			_hitches.append({
				"index": _wall_samples.size() - 1,
				"ms": wall_ms,
				"kind": "wall",
				"physics_frame": frame,
				"paused": get_tree().paused,
			})
	_last_process_us = now_us
	if frame_ms >= 100.0 and _hitches.size() < 64:
		_hitches.append({
			"index": _samples.size() - 1,
			"ms": frame_ms,
			"physics_frame": Engine.get_physics_frames(),
			"paused": get_tree().paused,
		})
	var now := Time.get_ticks_msec() / 1000.0
	if now - _last_row_wall >= 5.0:
		_last_row_wall = now
		_rows.append(_sample_row())
	_rotate_camera(now)


## 可见局镜头轮换（免 DCS）：每 150 秒把等距相机移到下一个电脑的 CommandCenter 上方，
## 覆盖"基地/采矿/产线"观察位。只在窗口化试玩时有意义；无头局相机操作无副作用。
func _rotate_camera(now: float) -> void:
	if _camera == null or not is_instance_valid(_camera):
		_camera = _match.get_node_or_null("IsometricCamera3D") if _match != null else null
		if _camera == null or not _camera.has_method("set_position_safely"):
			return
	var ccs := get_tree().get_nodes_in_group("units").filter(
		func(unit): return unit.get("unit_type_id") == "command_center"
	)
	if ccs.is_empty():
		return
	var index := int(now / 150.0) % ccs.size()
	var target: Node3D = ccs[index]
	if _camera_target != target:
		_camera_target = target
		_camera.set_position_safely(target.global_position)


var _camera: Node = null
var _camera_target: Node = null


func _sample_row() -> Dictionary:
	var row := {
		"wall_s": Time.get_ticks_msec() / 1000.0 - _start_wall,
		"sim_s": (_match.get_simulation_msec() / 1000.0) if _match.has_method("get_simulation_msec") else null,
		"units": get_tree().get_nodes_in_group("units").size(),
		"resources": get_tree().get_nodes_in_group("resource_units").size(),
	}
	row["paused"] = get_tree().paused
	row["simulation_paused"] = _match.is_simulation_paused() if _match.has_method("is_simulation_paused") else get_tree().paused
	row["physics_frames"] = Engine.get_physics_frames()
	if AiPerfStats.enabled():
		var snap_started := Time.get_ticks_usec()
		row["gdscript"] = AiPerfStats.snapshot()
		row["gdscript_hitches"] = AiPerfStats.hitch_log()
		row["probe_snapshot_us"] = Time.get_ticks_usec() - snap_started
	if _world_query_runtime != null and _world_query_runtime.has_method("GetQueryPerfStats"):
		var query_started := Time.get_ticks_usec()
		row["csharp"] = _world_query_runtime.GetQueryPerfStats()
		row["probe_query_dump_us"] = Time.get_ticks_usec() - query_started
	return row


func _percentile(sorted_values: Array, fraction: float) -> float:
	if sorted_values.is_empty():
		return 0.0
	var index := int(ceil(fraction * sorted_values.size())) - 1
	index = clampi(index, 0, sorted_values.size() - 1)
	return sorted_values[index]


func _finish(timed_out: bool, reason: String) -> void:
	if _done:
		return
	_done = true
	var sorted := _samples.duplicate()
	sorted.sort()
	var wall_sorted := _wall_samples.duplicate()
	wall_sorted.sort()
	var result := {
		"run_id": _args["run-id"],
		"reason": reason,
		"timed_out": timed_out,
		"ai_count": int(_args["ai-count"]),
		"difficulty": int(_args["difficulty"]),
		"extra_units_per_player": int(_args["extra-units"]),
		"warmup_frames": int(_args["warmup-frames"]),
		"sampled_frames": _samples.size(),
		"wall_s": Time.get_ticks_msec() / 1000.0 - _start_wall,
		"sim_s": (_match.get_simulation_msec() / 1000.0) if _match.has_method("get_simulation_msec") else null,
		"units_final": get_tree().get_nodes_in_group("units").size(),
		"resources_final": get_tree().get_nodes_in_group("resource_units").size(),
		"frame_ms": {
			"p50": _percentile(sorted, 0.50),
			"p95": _percentile(sorted, 0.95),
			"p99": _percentile(sorted, 0.99),
			"max": sorted[-1] if not sorted.is_empty() else 0.0,
			"mean": (_samples.reduce(func(a, b): return a + b, 0.0) / _samples.size())
				if not _samples.is_empty() else 0.0,
			"over_33_33ms": _samples.filter(func(v): return v > 33.33).size(),
			"over_100ms": _samples.filter(func(v): return v > 100.0).size(),
			"over_500ms": _samples.filter(func(v): return v > 500.0).size(),
		},
		"frame_wall_ms": {
			"max": wall_sorted[-1] if not wall_sorted.is_empty() else 0.0,
			"p95": _percentile(wall_sorted, 0.95),
			"over_33_33ms": _wall_samples.filter(func(v): return v > 33.33).size(),
			"over_100ms": _wall_samples.filter(func(v): return v > 100.0).size(),
		},
		"frame_hitches_ms": _hitches,
		"rows": _rows,
	}
	if AiPerfStats.enabled():
		result["gdscript_final"] = AiPerfStats.snapshot()
		result["gdscript_hitches"] = AiPerfStats.hitch_log()
	if _world_query_runtime != null and _world_query_runtime.has_method("GetQueryPerfStats"):
		result["csharp_final"] = _world_query_runtime.GetQueryPerfStats()
	var file := FileAccess.open(String(_args["perf-out"]), FileAccess.WRITE)
	if file == null:
		push_error("ai_perf_probe: 无法写 %s" % _args["perf-out"])
		get_tree().quit(3)
		return
	file.store_string(JSON.stringify(result, "\t"))
	file.close()
	print("AI_PERF_PROBE completed reason=%s frames=%d" % [reason, _samples.size()])
	get_tree().quit(0)
