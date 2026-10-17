extends Node

## 诊断：建筑挡在工人和目标之间时，逻辑寻路给出的路径，以及工人实际走到哪。
## 只采样，不改判据。证据由启动命令重定向到 agent/runs。

const MAP_SCENE := "res://source/match/maps/PlainAndSimple.tscn"
const BASE := Vector3(160.0, 0.0, 160.0)

var _m: Node = null
var _player: Node = null


func _ready() -> void:
	get_tree().create_timer(300.0).timeout.connect(func() -> void:
		push_error("[AROUND] 超时兜底退出")
		get_tree().quit(2))
	var settings = load("res://source/data-model/MatchSettings.gd").new()
	var hs = load("res://source/data-model/PlayerSettings.gd").new()
	hs.controller = Constants.PlayerType.HUMAN
	hs.color = Constants.Player.COLORS[0]
	settings.players.append(hs)
	settings.visible_player = 0
	_m = load("res://source/match/Match.tscn").instantiate()
	_m.settings = settings
	_m.map = load(MAP_SCENE).instantiate()
	add_child(_m)
	get_tree().current_scene = _m
	for _f in range(200):
		await get_tree().physics_frame
	_player = _m.get_node("Players").get_children()[0]
	var terrain: Node = _m.map.find_child("Terrain", true, false)
	print("[AROUND] logic=", Utils.Match.is_logic_terrain_map(_m.map),
		" cell=", terrain.call("ground_path_cell_meters") if terrain.has_method("ground_path_cell_meters") else -1)
	var factory_ok: bool = await _drive(terrain, "VehicleFactory", BASE, Vector3(-18.0, 0.0, 0.0), Vector3(18.0, 0.0, 0.0), "factory-through")
	var barracks_ok: bool = await _drive(terrain, "Barracks", Vector3(280.0, 0.0, 230.0), Vector3(-20.0, 0.0, 0.0), Vector3.ZERO, "barracks-center")
	print("[AROUND] probe done factory=%s barracks=%s" % [str(factory_ok), str(barracks_ok)])
	get_tree().quit(0 if factory_ok and barracks_ok else 1)


func _spawn(scene_name: String, at: Vector3) -> Node3D:
	var unit: Node3D = (load("res://source/match/units/%s.tscn" % scene_name) as PackedScene).instantiate()
	_m.call("_setup_and_spawn_unit", unit, Transform3D(Basis.IDENTITY, at), _player, false)
	return unit


func _drive(terrain: Node, structure_name: String, center: Vector3, worker_offset: Vector3, goal_offset: Vector3, tag: String) -> bool:
	var ground_ok := not bool(terrain.is_ground_blocked(center))
	print("[AROUND] %s center_blocked=%s pos=(%.1f,%.1f)" % [tag, str(not ground_ok), center.x, center.z])
	if not ground_ok:
		print("[AROUND] %s skip: center is not open ground" % tag)
		return false
	var structure := _spawn(structure_name, center)
	var worker := _spawn("Worker", center + worker_offset)
	for _f in range(90):
		await get_tree().physics_frame
	var goal := center + goal_offset
	var clamped: Vector3 = terrain.clamp_ground_destination(goal)
	var movement: Node = worker.find_child("Movement", true, false)
	var body_r := float(movement.radius) if movement != null else 0.0
	var path: PackedVector3Array = terrain.find_ground_path(worker.global_position, clamped, body_r)
	print("[AROUND] %s worker=(%.2f,%.2f) goal=(%.2f,%.2f) clamped=(%.2f,%.2f) clearance=%.3f path_n=%d" % [
		tag, worker.global_position.x, worker.global_position.z,
		goal.x, goal.z, clamped.x, clamped.z, body_r, path.size()])
	var path_min_gap := _print_path(terrain, structure, path, tag)
	var end_reason := ""
	movement.movement_ended.connect(func(reason: String) -> void:
		end_reason = reason)
	var start := worker.global_position
	movement.call("move", goal)
	var samples: PackedStringArray = PackedStringArray()
	var min_gap := 999.0
	var max_travel := 0.0
	var still_frames := 0
	var last := worker.global_position
	for frame in range(1200):
		await get_tree().physics_frame
		if end_reason != "":
			break
		if frame % 30 != 0:
			continue
		var pos := worker.global_position
		var gap := _surface_gap(pos, structure)
		min_gap = minf(min_gap, gap)
		var travel := Vector2(pos.x - start.x, pos.z - start.z).length()
		max_travel = maxf(max_travel, travel)
		var step := Vector2(pos.x - last.x, pos.z - last.z).length()
		if step < 0.05:
			still_frames += 1
		else:
			still_frames = 0
		last = pos
		samples.append("%.0f:(%.2f,%.2f) gap=%.2f" % [frame / 60.0, pos.x, pos.z, gap])
		if still_frames == 8 and travel > 1.0:
			var committed: Variant = movement.get("_committed_target")
			var logic_path: Variant = movement.get("_logic_path")
			print("[AROUND] %s stall-state radius=%.3f path_i=%s repath=%s stuck=%s committed=%s logic=%s" % [
				tag,
				float(movement.get("radius")),
				str(movement.get("_logic_path_i")),
				str(movement.get("_logic_repath_attempts")),
				str(movement.get("_logic_stuck")),
				str(committed),
				str(logic_path)])
	var end := worker.global_position
	var goal_dist := Vector2(end.x - clamped.x, end.z - clamped.z).length()
	var lateral := _lateral_clearance(start, center, end, structure)
	print("[AROUND] %s end=(%.2f,%.2f) reason=%s dist_clamped=%.2f travel=%.2f min_gap=%.2f lateral=%.2f" % [
		tag, end.x, end.z, end_reason if end_reason != "" else "TIMEOUT",
		goal_dist, Vector2(end.x - start.x, end.z - start.z).length(), min_gap, lateral])
	print("[AROUND] %s samples %s" % [tag, " ".join(samples)])
	var passed := goal_dist <= 2.0 and min_gap > 0.05 and path_min_gap >= body_r * 0.85
	print("[AROUND] %s result pass=%s path_min_gap=%.2f body=%.3f" % [tag, str(passed), path_min_gap, body_r])
	if movement != null and movement.has_method("terminal_events_since"):
		print("[AROUND] %s terminal %s" % [tag, str(movement.call("terminal_events_since", 0))])
	worker.queue_free()
	structure.queue_free()
	for _f in range(45):
		await get_tree().physics_frame
	return passed


func _print_path(terrain: Node, structure: Node3D, path: PackedVector3Array, tag: String) -> float:
	var prev := Vector3.INF
	var clip := 0
	var min_gap := 999.0
	for point in path:
		var gap := _surface_gap(point, structure)
		min_gap = minf(min_gap, gap)
		var blocked := bool(terrain.is_ground_blocked(point))
		print("[AROUND] %s wp=(%.2f,%.2f) gap=%.2f blocked=%s" % [
			tag, point.x, point.z, gap, str(blocked)])
		if prev.is_finite():
			clip += _segment_clip_count(terrain, prev, point)
		prev = point
	print("[AROUND] %s path_min_gap=%.2f segment_blocked_samples=%d" % [tag, min_gap, clip])
	return min_gap


func _segment_clip_count(terrain: Node, a: Vector3, b: Vector3) -> int:
	var hits := 0
	var length := Vector2(b.x - a.x, b.z - a.z).length()
	var steps := maxi(1, int(ceil(length / 0.25)))
	for s in range(1, steps):
		var t := float(s) / float(steps)
		if bool(terrain.is_ground_blocked(a.lerp(b, t))):
			hits += 1
	return hits


func _surface_gap(point: Vector3, structure: Node3D) -> float:
	var shape: CollisionShape3D = structure.find_child("CollisionShape3D", true, false)
	if shape == null or not (shape.shape is BoxShape3D):
		return 999.0
	var half: Vector3 = (shape.shape as BoxShape3D).size * 0.5
	var origin: Vector3 = shape.global_position
	var dx := absf(point.x - origin.x) - half.x
	var dz := absf(point.z - origin.z) - half.z
	if dx <= 0.0 and dz <= 0.0:
		return maxf(dx, dz)
	return Vector2(maxf(dx, 0.0), maxf(dz, 0.0)).length()


## 终点相对「起点→楼心」直线的侧向偏离。绕楼应明显大于 0；顶在正面墙上接近 0。
func _lateral_clearance(start: Vector3, center: Vector3, end: Vector3, structure: Node3D) -> float:
	var axis := Vector2(center.x - start.x, center.z - start.z)
	if axis.length() < 0.01:
		return 0.0
	axis = axis.normalized()
	var side := Vector2(-axis.y, axis.x)
	var rel := Vector2(end.x - center.x, end.z - center.z)
	return absf(rel.dot(side))
