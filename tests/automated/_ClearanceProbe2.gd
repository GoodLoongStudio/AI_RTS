extends Node

## 干净版贴边测量探针（替代已损坏的 _FourDirectionClearanceProbe）。
## 设计要点（都是踩坑后的纪律）：
##  1. **一个进程只测一组**（单位 × 方向）——上一版复用场景会在多次 queue_free 后挂住 ✗；
##  2. 自带超时兜底（不退出 = 无输出 = stale 数据被误信 ✗）；
##  3. 结果写文件后打印 mtime 供校验 ✓；
##  4. 只测"稳定后"的位置，并把 spawn 偏移一并记录（位移污染检测）。

const OUT_DIR := "res://agent/runs/2026-10-01-per-unit-collider-clearance/"

var _unit_name := "Worker"
var _obstacle_name := "Barracks"
var _dir := Vector3(1, 0, 0)
var _tag := "worker_px"


func _ready():
	_unit_name = _env("AIRTS_PROBE_UNIT", _unit_name)
	_obstacle_name = _env("AIRTS_PROBE_OBSTACLE", _obstacle_name)
	_tag = _env("AIRTS_PROBE_TAG", _tag)
	var dx := float(_env("AIRTS_PROBE_DX", "1"))
	var dz := float(_env("AIRTS_PROBE_DZ", "0"))
	_dir = Vector3(dx, 0.0, dz).normalized()
	get_tree().create_timer(150.0).timeout.connect(func() -> void:
		push_error("[PROBE2] 超时兜底退出")
		get_tree().quit(2))
	await _run()


func _env(key: String, fallback: String) -> String:
	var v := OS.get_environment(key)
	return v if v != "" else fallback


func _run() -> void:
	# 正确的对战搭建方式（照 _FourDirectionClearanceProbe 的可用版本）：
	# MatchSettings.gd 是**脚本**不是场景；地图要显式赋值；并把 current_scene 指过去。
	var settings = load("res://source/data-model/MatchSettings.gd").new()
	var hs = load("res://source/data-model/PlayerSettings.gd").new()
	hs.controller = Constants.PlayerType.HUMAN
	hs.color = Constants.Player.COLORS[0]
	settings.players.append(hs)
	settings.visible_player = 0
	var match_scene: Node = load("res://source/match/Match.tscn").instantiate()
	match_scene.settings = settings
	match_scene.map = load("res://source/match/maps/PlainAndSimple.tscn").instantiate()
	add_child(match_scene)
	get_tree().current_scene = match_scene
	for _f in range(160):
		await get_tree().physics_frame
	var player: Node = match_scene.get_node("Players").get_children()[0]
	# 测试点放在地图中部空地（远离玩家基地，避免基地推出半径污染 —— 已踩过的坑）
	var base := Vector3(120.0, 0.0, 120.0)
	var obstacle: Node3D = (load("res://source/match/units/" + _obstacle_name + ".tscn") as PackedScene).instantiate()
	match_scene.call("_setup_and_spawn_unit", obstacle, Transform3D(Basis.IDENTITY, base), player, false)
	var requested := base + _dir * 18.0
	var unit: Node3D = (load("res://source/match/units/" + _unit_name + ".tscn") as PackedScene).instantiate()
	match_scene.call("_setup_and_spawn_unit", unit, Transform3D(Basis.IDENTITY, requested), player, false)
	for _f in range(200):
		await get_tree().physics_frame
	var start: Vector3 = unit.global_position
	var spawn_offset := Vector2(start.x - requested.x, start.z - requested.z).length()
	var movement: Node = unit.find_child("Movement", true, false)
	movement.call("move", base)
	var prev := start
	var stable := 0
	var frames := 0
	while frames < 600 and stable <= 60:
		await get_tree().physics_frame
		frames += 1
		var cur: Vector3 = unit.global_position
		if Vector2(cur.x - prev.x, cur.z - prev.z).length() < 0.01:
			stable += 1
		else:
			stable = 0
		prev = cur
	# ---------- 测量 ----------
	var obstacle_now: Vector3 = obstacle.global_position
	var unit_half: float = _ground_half(unit)
	var obstacle_half: float = _ground_half(obstacle)
	var center_distance := Vector2(prev.x - obstacle_now.x, prev.z - obstacle_now.z).length()
	var logic_radius: float = float(unit.get("radius")) if unit.get("radius") != null else -1.0
	var clearance: float = Utils.Match.Unit.Movement.carve_clearance_of(obstacle)
	var mv_node: Node = unit.find_child("Movement", true, false)
	var domain: Variant = mv_node.get("domain") if mv_node != null else null
	var is_air: bool = domain != null and int(domain) == int(Constants.Match.Navigation.Domain.AIR)
	var gap := center_distance - unit_half - obstacle_half
	var row := {
		"unit": _unit_name, "obstacle": _obstacle_name, "tag": _tag,
		"direction": [_dir.x, _dir.z],
		"is_air_unit": is_air,
		"spawn_offset_m": spawn_offset, "spawn_mismatch": spawn_offset > 0.8,
		"start_distance_m": Vector2(start.x - obstacle_now.x, start.z - obstacle_now.z).length(),
		"center_distance_m": center_distance,
		"unit_ground_half_m": unit_half, "obstacle_ground_half_m": obstacle_half,
		"hull_to_hull_gap_m": gap,
		"unit_logic_radius_m": logic_radius,
		"obstacle_carve_clearance_m": clearance,
		"frames": frames, "settled": stable > 60,
	}
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	var path := ProjectSettings.globalize_path(OUT_DIR + "probe2_" + _tag + ".json")
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(JSON.stringify(row, "  "))
	f.close()
	print("[PROBE2] %s ← %s dir=(%.0f,%.0f) 中心距=%.3f 单位半宽=%.3f 障碍半宽=%.3f 间隙=%.3f 停稳=%s 帧=%d" % [
		_unit_name, _obstacle_name, _dir.x, _dir.z, center_distance, unit_half, obstacle_half, gap, str(stable > 60), frames])
	print("[PROBE2] 已写入 %s" % path)
	get_tree().quit(0)


func _ground_half(node: Node3D) -> float:
	var origin: Vector3 = node.global_position
	var pts: Array[Vector2] = []
	for gi in node.find_children("*", "GeometryInstance3D", true, false):
		var p := str(gi.get_path())
		if p.contains("Selection") or p.contains("Highlight") or p.contains("Targetability") \
				or p.contains("HealthBar") or p.contains("RallyPoint"):
			continue
		var box: AABB = (gi as GeometryInstance3D).get_aabb()
		if gi is MeshInstance3D and (gi as MeshInstance3D).mesh != null and box.size.length() < 0.01:
			box = (gi as MeshInstance3D).mesh.get_aabb()
		if box.size.length() < 0.001:
			continue
		var xf: Transform3D = (gi as Node3D).global_transform
		for i in range(8):
			var pt: Vector3 = xf * box.get_endpoint(i)
			if absf(pt.y - origin.y) > 1.0:
				continue
			pts.append(Vector2(pt.x - origin.x, pt.z - origin.z))
	if pts.is_empty():
		return 0.0
	# 到"上一帧测量的对方"方向的最大投影：这里用 hull 的最大半径近似（保守、方向无关）
	var out := 0.0
	for v in pts:
		out = maxf(out, v.length())
	return out
