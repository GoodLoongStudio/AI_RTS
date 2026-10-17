extends Node

## 连续推进 + 视觉取证探针（2026-10-07，round-03）。
##
## 为什么单独写：DCS 的 `op=screenshot` 在这台机器上不可用（见 DebugControlServer 里
## `_pending_shots` 的注释），而**场景内截图是可行的**（`tests/performance/SmallArmyPerformanceProbe.gd:72`
## 已跑通，本探针 round-03 实测 3/3 成功、5–8ms）。
## 本探针把三件事放进**同一个真实对局**里：
##   ① 走**玩家命令入口** `UnitCommandGateway.MoveUnits`（= 副官下发走的同一条权威链，
##      不是直接改 transform）命令**多兵种编队**分别前往不同目标点；
##   ② 每 0.25 秒采一次每个单位的真实坐标，算"停住→再动"的间隔与轨迹长度；
##   ③ 在起点/中途/终点各截一张图并落盘（用已跑通的 `frame_post_draw` 时机）。
##
## marker: `CONTINUITY PROBE completed: <n> png, <m> failure(s)`
## 报告:  res://agent/runs/2026-10-07-adjutant-continuity-fix/round-04/liveprobe/report.json

const OUT_DIR := "res://agent/runs/2026-10-07-adjutant-continuity-fix/round-04/liveprobe"
const MAP_SCENE := "res://source/match/maps/PlainAndSimple.tscn"
const ROSTER := ["Tank.tscn", "HeavyTank.tscn", "Infantry.tscn", "APC.tscn", "Sniper.tscn"]
const SAMPLE_SECONDS := 36.0

var _match: Node = null
var _human: Node = null
var _gateway: Node = null
var _cc: Node3D = null
var _shots := 0
var _failures := 0


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	var settings = load("res://source/data-model/MatchSettings.gd").new()
	var human_settings = load("res://source/data-model/PlayerSettings.gd").new()
	human_settings.controller = Constants.PlayerType.HUMAN
	human_settings.color = Constants.Player.COLORS[0]
	settings.players.append(human_settings)
	settings.visible_player = 0
	settings.local_player_index = 0

	_match = load("res://source/match/Match.tscn").instantiate()
	_match.settings = settings
	_match.map = load(MAP_SCENE).instantiate()
	get_tree().root.add_child.call_deferred(_match)
	await get_tree().process_frame
	get_tree().current_scene = _match
	await get_tree().create_timer(8.0).timeout
	get_tree().current_scene = _match

	_human = _match.get_local_player()
	_cc = _find_command_center()
	if _human == null or _cc == null:
		print("[CPROBE] 对局未就绪 human=%s cc=%s" % [str(_human != null), str(_cc != null)])
		_finish({})
		return
	_gateway = _match.find_child("UnitCommandGateway", true, false)
	# 等导航图真的烘好（否则命令会被权威端拒/单位立刻 Arrived；见 _IndepVerifyGroundMove 注释）。
	var nav_map = _match.navigation.get_navigation_map_rid_by_domain(
		Constants.Match.Navigation.Domain.TERRAIN)
	var deadline := Time.get_ticks_msec() + 60000
	while Time.get_ticks_msec() < deadline:
		await get_tree().physics_frame
		if NavigationServer3D.map_get_closest_point_owner(
				nav_map, _cc.global_position).is_valid():
			break
	print("[CPROBE] ready gateway=%s cc=%s nav_ok=%s" % [
		str(_gateway != null), _fmt(_cc.global_position),
		str(NavigationServer3D.map_get_closest_point_owner(
			nav_map, _cc.global_position).is_valid())])
	if _gateway == null:
		_finish({})
		return

	# 编队：5 种兵，错开站位，分别去**不同**目标点（多线并行，不抢同一个点）。
	var squad: Array = []
	var base: Vector3 = _cc.global_position + Vector3(6.0, 0.0, 6.0)
	for index in range(ROSTER.size()):
		var unit = load("res://source/match/units/" + ROSTER[index]).instantiate()
		var spawn: Vector3 = base + Vector3(float(index % 3) * 4.0, 0.0,
			float(index / 3) * 4.0)
		_match.call("_setup_and_spawn_unit", unit, Transform3D(Basis.IDENTITY, spawn),
			_human, false)
		squad.append(unit)
	for _frame in range(10):
		await get_tree().physics_frame

	var targets: Array = []
	for index in range(squad.size()):
		var unit: Node3D = squad[index]
		# 沿可走方向散开：彼此目标点至少隔 25 米，避免挤在一条线上。
		var angle := float(index) * 0.9
		var target: Vector3 = _cc.global_position + Vector3(cos(angle), 0.0, sin(angle)) * 70.0
		targets.append(target)
	if _shots == 0:
		await _screenshot("00_start")
	var results: Array = []
	for index in range(squad.size()):
		var unit: Node3D = squad[index]
		var reply = _gateway.call("MoveUnits", [unit], targets[index], _human)
		results.append({"unit": str(unit.name), "type": ROSTER[index],
			"start": _v3(unit.global_position), "target": _v3(targets[index]),
			"reply": str(reply), "samples": []})

	print("[CPROBE] orders issued for %d units" % results.size())
	var started := Time.get_ticks_msec()
	var next_sample := 0
	var next_shot := 1
	while Time.get_ticks_msec() - started < int(SAMPLE_SECONDS * 1000.0):
		await get_tree().physics_frame
		var elapsed := float(Time.get_ticks_msec() - started) / 1000.0
		if elapsed >= float(next_sample) * 0.25:
			next_sample += 1
			for index in range(squad.size()):
				var unit: Node3D = squad[index]
				results[index]["samples"].append([round(elapsed * 100.0) / 100.0,
					round(unit.global_position.x * 100.0) / 100.0,
					round(unit.global_position.z * 100.0) / 100.0])
		if next_shot <= 2 and elapsed >= float(next_shot) * 10.0:
			next_shot += 1
			if _shots == 0:
				await _screenshot("%02d_mid_%ds" % [next_shot - 1, int(elapsed)])
	if _shots == 0:
		await _screenshot("03_end")

	var report := {"map": MAP_SCENE, "sample_seconds": SAMPLE_SECONDS,
		"command_center": _v3(_cc.global_position), "units": results}
	# 指标**不在 GDScript 里算**：原始坐标序列直接落盘，由 Python 侧（纯函数、可复算）
	# 统计"停住→再动"间隔。理由：GDScript 这边的字典/数组类型推断在这个引擎版本上
	# 反复出错（`Array.max()` 返回 bool 等），而统计口径本来就适合用假数据复算。
	_save_report(report)
	_finish(report)


func _find_command_center() -> Node3D:
	var players: Node = _match.get_node_or_null("Players")
	if players == null or players.get_child_count() == 0:
		return null
	for sub in players.get_child(0).get_children():
		if sub is Node3D and sub.get_script() != null \
				and "CommandCenter" in str(sub.get_script().resource_path):
			return sub
	return null


## 从坐标序列里量"停住→再动"的间隔、轨迹长度、最终位移（与副官的监督口径一致）。
func _summarise(row: Dictionary) -> Dictionary:
	var samples: Array = row.get("samples") or []
	if samples.size() < 2:
		return {"samples": samples.size()}
	var moves: Array = [float(samples[0][0])]
	var total := 0.0
	var last := Vector2(float(samples[0][1]), float(samples[0][2]))
	for index in range(1, samples.size()):
		var point := Vector2(float(samples[index][1]), float(samples[index][2]))
		var step := point.distance_to(last)
		total += step
		if step > 0.5:
			moves.append(float(samples[index][0]))
		last = point
	# 手写最大值：`Array.max()` 在这个引擎版本上返回的不是数值（实测报
	# "Trying to assign value of type 'bool' to a variable of type 'Array'"）。
	var max_gap := 0.0
	var gaps: Array = []
	for index in range(1, moves.size()):
		var gap: float = round((float(moves[index]) - float(moves[index - 1])) * 100.0) / 100.0
		gaps.append(gap)
		if gap > max_gap:
			max_gap = gap
	var start := Vector2(float(samples[0][1]), float(samples[0][2]))
	var end := Vector2(float(samples[-1][1]), float(samples[-1][2]))
	var goal := Vector2(float(row["target"][0]), float(row["target"][2]))
	return {
		"samples": samples.size(),
		"move_events": moves.size(),
		"total_path_m": round(total * 100.0) / 100.0,
		"net_displacement_m": round(start.distance_to(end) * 100.0) / 100.0,
		"goal_distance_start_m": round(start.distance_to(goal) * 100.0) / 100.0,
		"goal_distance_end_m": round(end.distance_to(goal) * 100.0) / 100.0,
		"max_gap_s": max_gap,
		"gaps_s": gaps,
		"idle_tail_s": round((float(samples[-1][0]) - float(moves[-1])) * 100.0) / 100.0,
	}


func _screenshot(label: String) -> void:
	var path := "%s/%s.png" % [OUT_DIR, label]
	await RenderingServer.frame_post_draw
	var image: Image = get_viewport().get_texture().get_image()
	if image == null:
		print("[CPROBE] screenshot %s null" % label)
		_failures += 1
		return
	var err := image.save_png(ProjectSettings.globalize_path(path))
	print("[CPROBE] screenshot %s %dx%d -> %d" % [label, image.get_width(),
		image.get_height(), err])
	if err == OK:
		_shots += 1
	else:
		_failures += 1


func _save_report(report: Dictionary) -> void:
	var handle := FileAccess.open(OUT_DIR + "/report.json", FileAccess.WRITE)
	if handle == null:
		return
	handle.store_string(JSON.stringify(report, "  "))
	handle.close()


## ⚠ 这个函数**不 await**：`await` 只能出现在协程里，而在返回 `void` 的函数里
## `await get_tree().process_frame` 会让调用方的协程静默失效 —— 实测表现是
## "日志打到一半就没了、引擎还活着、脚本再也不往下走"（本探针 round-03/04 各踩一次）。
## 退出用 `call_deferred`，把 quit 推到本帧之后即可。
func _finish(report: Dictionary) -> void:
	if not report.is_empty():
		for row in report.get("units") or []:
			var summary = row.get("summary") or {}
			print("[CPROBE] %-12s %-14s path=%-7s disp=%-7s goal %s→%s gap_max=%s" % [
				str(row["unit"]), str(row["type"]), str(summary.get("total_path_m")),
				str(summary.get("net_displacement_m")),
				str(summary.get("goal_distance_start_m")),
				str(summary.get("goal_distance_end_m")), str(summary.get("max_gap_s"))])
	print("CONTINUITY PROBE completed: %d png, %d failure(s)" % [_shots, _failures])
	_quit_soon(0 if _failures == 0 else 1)


func _quit_soon(code: int) -> void:
	await get_tree().process_frame
	get_tree().quit(code)


func _v3(value: Vector3) -> Array:
	return [round(value.x * 100.0) / 100.0, round(value.y * 100.0) / 100.0,
		round(value.z * 100.0) / 100.0]


func _fmt(value: Vector3) -> String:
	return "(%.1f, %.1f)" % [value.x, value.z]
