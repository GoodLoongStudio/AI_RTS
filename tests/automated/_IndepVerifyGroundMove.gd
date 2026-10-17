extends Node

## 独立验证探针 #3（verifier 自写）：地面移动命令之后单位是否真的产生位移。
## 背景：lead 于 2026-09-30 修复 Moving.gd 的 _exit_tree 竞态（旧动作被替换成 queue_free
## 时调用 stop()，把新动作刚下发的 target_position 清成 INF ⇒ 点地面原地不动、立刻 Arrived）。
##
## 本探针走**玩家命令入口** UnitCommandGateway.MoveUnits(units, destination, issuer)
## （= UnitActionsController / NetSync / DebugControlServer 用的同一个 C# 入口，
##  最终落到 CommandRuntime.MoveUnitsByStableIds → LegacyMovementPort → Unit.request_legacy_move）。
##
## 输出：
##   [IVR3] 每个用例的目标、回执、各时刻位移、动作类名、Movement.target_position
##   [IVR3-REPORT] 完整 JSON 落盘 res://build/indep_verify/probe3_report.json

const MAP_SCENE := "res://source/match/maps/PlainAndSimple.tscn"
const TANK := "res://source/match/units/Tank.tscn"
const REPORT_PATH := "res://build/indep_verify/probe3_report.json"

var _match: Node = null
var _human: Node = null
var _gateway: Node = null
var _cc: Node3D = null
var _rows: Array = []


func _ready():
	var settings = load("res://source/data-model/MatchSettings.gd").new()
	var hs = load("res://source/data-model/PlayerSettings.gd").new()
	hs.controller = Constants.PlayerType.HUMAN
	hs.color = Constants.Player.COLORS[0]
	settings.players.append(hs)
	settings.visible_player = 0
	_match = load("res://source/match/Match.tscn").instantiate()
	_match.settings = settings
	_match.map = load(MAP_SCENE).instantiate()
	add_child(_match)
	get_tree().current_scene = _match
	var deadline := Time.get_ticks_msec() + 90000
	while Time.get_ticks_msec() < deadline:
		await get_tree().physics_frame
		var players: Node = _match.get_node_or_null("Players")
		if players == null or players.get_child_count() < 1:
			continue
		for sub in players.get_child(0).get_children():
			if sub is Node3D and sub.get_script() != null \
					and "CommandCenter" in str(sub.get_script().resource_path):
				_cc = sub
		if _cc != null:
			break
	if _cc == null:
		print("[IVR3] 对局未就绪")
		_finish()
		return
	_human = _match.get_node("Players").get_children()[0]
	# 等导航图烘焙就绪（否则 NavigationAgent3D 立即判"完成"，位移结论全是假阴性）
	var terrain_map = _match.navigation.get_navigation_map_rid_by_domain(
		Constants.Match.Navigation.Domain.TERRAIN)
	var nav_deadline := Time.get_ticks_msec() + 60000
	while Time.get_ticks_msec() < nav_deadline:
		await get_tree().physics_frame
		if NavigationServer3D.map_get_closest_point_owner(
				terrain_map, _cc.global_position).is_valid():
			break
	print("[IVR3] navmesh_ready=%s" % str(NavigationServer3D.map_get_closest_point_owner(
		terrain_map, _cc.global_position).is_valid()))
	await get_tree().physics_frame
	_gateway = _match.find_child("UnitCommandGateway", true, false)
	print("[IVR3] gateway=%s cc_pos=%s" % [str(_gateway != null), _fmt(_v3(_cc.global_position))])
	if _gateway == null:
		_finish()
		return
	var dirs := _reachable_directions()
	print("[IVR3] 可走方向: %s" % JSON.stringify(dirs))
	if dirs.is_empty():
		print("[IVR3] 找不到可走方向，无法验证位移")
		_finish()
		return
	var d0: Vector3 = dirs[0]
	var d1: Vector3 = dirs[1 % dirs.size()]
	await _case("A 单次地面移动 12m", d0 * 12.0, Vector3.ZERO, d0)
	await _case("B 目标改向（旧动作竞态）", d0 * 14.0, d1 * 14.0, d0)
	await _case("C 连续两次同向 12→22m", d0 * 12.0, d0 * 22.0, d0)
	_finish()


## 用导航图实测 8 个方向哪些真的可走（路径终点落在目标 1m 内），返回世界方向列表。
func _reachable_directions() -> Array:
	var out: Array = []
	var map = _match.navigation.get_navigation_map_rid_by_domain(
		Constants.Match.Navigation.Domain.TERRAIN)
	var origin: Vector3 = _cc.global_position + Vector3(0.0, 0.0, -18.0)
	var diag := PackedStringArray()
	for k in range(8):
		var a := TAU * float(k) / 8.0
		var dir := Vector3(cos(a), 0.0, sin(a))
		var goal: Vector3 = origin + dir * 20.0
		var path: PackedVector3Array = NavigationServer3D.map_get_path(map, origin, goal, true)
		var tail := (path[path.size() - 1] if path.size() > 0 else Vector3.INF)
		diag.append("%d:n=%d,tail_d=%.1f" % [k, path.size(),
			(tail.distance_to(goal) if path.size() > 0 else -1.0)])
		if path.size() >= 2 and tail.distance_to(goal) < 2.0:
			out.append(dir)
	print("[IVR3] 方向诊断(索引:路径点数,终点距目标) %s" % " ".join(diag))
	return out


## offset_a：第一条命令的相对落点；offset_b 非零时在 3 帧后补发第二条命令。
func _case(label: String, offset_a: Vector3, offset_b: Vector3, dir: Vector3) -> void:
	var tank: Node3D = load(TANK).instantiate()
	var spawn: Vector3 = _cc.global_position + Vector3(0.0, 0.0, -18.0)
	_match.call("_setup_and_spawn_unit", tank, Transform3D(Basis.IDENTITY, spawn), _human, false)
	for _f in range(6):
		await get_tree().physics_frame
	var start: Vector3 = tank.global_position
	var target_a: Vector3 = start + offset_a
	var result = _gateway.call("MoveUnits", [tank], target_a, _human)
	var row := {
		"case": label, "start": _v3(start), "target_a": _v3(target_a),
		"result_a": str(result), "samples": [],
	}
	await get_tree().physics_frame
	row["target_position_after_1_frame"] = str(_movement_target(tank))
	row["action_after_1_frame"] = _action_name(tank)
	if offset_b != Vector3.ZERO:
		for _f in range(3):
			await get_tree().physics_frame
		var target_b: Vector3 = start + offset_b
		var result_b = _gateway.call("MoveUnits", [tank], target_b, _human)
		row["target_b"] = _v3(target_b)
		row["result_b"] = str(result_b)
		row["target_position_after_retarget"] = str(_movement_target(tank))
		row["action_after_retarget"] = _action_name(tank)
	var frames := 0
	for step in [2, 30, 90, 180, 300, 420, 600]:
		while frames < step:
			await get_tree().physics_frame
			frames += 1
		var now: Vector3 = tank.global_position
		row["samples"].append({
			"frame": step,
			"pos": _v3(now),
			"displacement_from_start": snappedf(start.distance_to(now), 0.01),
			"dist_to_a": snappedf(target_a.distance_to(now), 0.01),
			"dist_to_b": (null if offset_b == Vector3.ZERO
				else snappedf((start + offset_b).distance_to(now), 0.01)),
			"action": _action_name(tank),
			"movement_target": str(_movement_target(tank)),
		})
	row["final_displacement"] = row["samples"][-1]["displacement_from_start"]
	row["arrived_a"] = float(row["samples"][-1]["dist_to_a"]) < 1.6
	row["direction"] = _v3(dir)
	row["still_alive"] = is_instance_valid(tank)
	_rows.append(row)
	var s0 = row["samples"][0]
	var s3 = row["samples"][-1]
	print("[IVR3] %-26s 方向=%s 目标A距=%.2f 位移=%.2f 到达A=%s 动作=%s→%s target1帧=%s 回执=%s" % [
		label, _fmt(row["direction"]), s3["dist_to_a"], s3["displacement_from_start"],
		str(row["arrived_a"]), row["action_after_1_frame"], s3["action"],
		row["target_position_after_1_frame"],
		str(result).replace("\n", " ").replace("  ", " ").left(150)])
	if offset_b != Vector3.ZERO:
		print("[IVR3] %-24s 改向后: target=%s action=%s 300帧时距B=%.2f 距A=%.2f" % [
			label, row["target_position_after_retarget"], row["action_after_retarget"],
			s3["dist_to_b"], s3["dist_to_a"]])
	tank.queue_free()
	await get_tree().process_frame


func _movement_target(unit: Node) -> Variant:
	var movement := unit.find_child("Movement", true, false)
	if movement == null:
		return null
	var value = movement.get("target_position")
	if value is Vector3 and value == Vector3.INF:
		return "INF"
	return _v3(value) if value is Vector3 else str(value)


func _action_name(unit: Node) -> String:
	var action = unit.get("action")
	if action == null or not is_instance_valid(action):
		return "null"
	var script: Script = action.get_script()
	return str(script.resource_path).get_file() if script != null else action.get_class()


func _finish() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://build/indep_verify"))
	var file := FileAccess.open(REPORT_PATH, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify({
			"generated_at": Time.get_datetime_string_from_system(),
			"rows": _rows}, "  "))
		file.close()
		print("[IVR3] 报告已写 %s" % REPORT_PATH)
	get_tree().quit(0)


func _v3(v: Vector3) -> Array:
	return [snappedf(v.x, 0.01), snappedf(v.y, 0.01), snappedf(v.z, 0.01)]


func _fmt(v) -> String:
	if v is Array:
		var parts := PackedStringArray()
		for x in v:
			parts.append(str(x))
		return "(" + ",".join(parts) + ")"
	return str(v)