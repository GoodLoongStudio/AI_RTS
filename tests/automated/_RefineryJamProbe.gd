extends Node

## 复现探针：主基地与矿场贴近摆放（默认表面间隙 2.0m，落在 navmesh 有通道、矿车推不过去的区间），
## 矿点放在基地另一侧，迫使矿车交货时把矿场朝向基地的那一面当作落点；多辆矿车往返。
## 统计：交付次数、卡住次数/秒数（移动中 3s 内净位移 < 0.5m）、最小表面间隙（负值=穿模深度）、
## 脱困计数，以及一段单车绕基地的 RVO 偏转（判定建筑障碍是否参与避障）和重烘耗时。
## 环境变量：AIRTS_JAM_GAP（米）、AIRTS_JAM_SECONDS、AIRTS_JAM_TAG（输出文件名后缀）。

const MAP_SCENE := "res://source/match/maps/PlainAndSimple.tscn"
const BASE := Vector3(120.0, 0.0, 96.0)
const RVO_BASE := Vector3(60.0, 0.0, 150.0)
const WORKER_COUNT := 3
const STUCK_WINDOW_S := 3.0
const STUCK_NET_MOVE_M := 0.5
const WORKER_BODY_RADIUS := 0.92

var _m: Node = null
var _player: Node = null


func _ready():
	var seconds := float(_env("AIRTS_JAM_SECONDS", "90"))
	get_tree().create_timer(seconds + 120.0).timeout.connect(func() -> void:
		push_error("[JAM] 超时兜底退出")
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
	for _f in range(160):
		await get_tree().physics_frame
	_player = _m.get_node("Players").get_children()[0]
	for resource in get_tree().get_nodes_in_group("resource_units"):
		if Vector2(resource.global_position.x - BASE.x, resource.global_position.z - BASE.z).length() < 60.0:
			resource.queue_free()

	var movement_script = load("res://source/match/units/traits/Movement.gd")
	if _legacy():
		movement_script.structure_pass_enabled = false
		load("res://source/match/utils/UnitMovementUtils.gd").structure_approach_enabled = false
	var report := {"schema": "refinery-jam-probe/v1", "tag": _env("AIRTS_JAM_TAG", "run"),
		"legacy": _legacy(), "generated_at": Time.get_datetime_string_from_system()}
	report["rvo"] = await _rvo_probe()
	report["jam"] = await _jam_run(float(_env("AIRTS_JAM_GAP", "2.0")), seconds)
	report["rebake"] = await _rebake_timing()
	var out_path := "res://agent/runs/nav-clearance/jam-%s.json" % report["tag"]
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://agent/runs/nav-clearance"))
	var f := FileAccess.open(out_path, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(report, "  "))
		f.close()
	print("[JAM] 写入 %s" % out_path)
	get_tree().quit(0)


func _env(name: String, fallback: String) -> String:
	var raw := OS.get_environment(name).strip_edges()
	return fallback if raw.is_empty() else raw


## AIRTS_JAM_LEGACY=1：在同一份代码上模拟改前口径（无 carve 外扩、圆形洞、建筑参与 RVO、
## 关闭己方建筑脱困），用于多次重复的公平对照。
func _legacy() -> bool:
	return _env("AIRTS_JAM_LEGACY", "0") == "1"


func _spawn(scene_name: String, at: Vector3) -> Node3D:
	var unit: Node3D = (load("res://source/match/units/%s.tscn" % scene_name) as PackedScene).instantiate()
	var obstacle: Node = unit.find_child("MovementObstacle", true, false)
	if _legacy() and obstacle != null:
		obstacle.set("carve_margin_m", 0.0)
		obstacle.set("carve_from_collision_bounds", false)
	_m.call("_setup_and_spawn_unit", unit, Transform3D(Basis.IDENTITY, at), _player, false)
	if (_legacy() or _env("AIRTS_JAM_BUILDING_RVO", "0") == "1") and obstacle != null \
			and bool(obstacle.get("affect_navigation_mesh")):
		obstacle.set("avoidance_enabled", true)
	var path_max := _env("AIRTS_JAM_PATHMAX", "")
	if scene_name == "Worker" and not path_max.is_empty():
		var agent := unit.find_child("Movement", true, false) as NavigationAgent3D
		if agent != null:
			agent.path_max_distance = float(path_max)
	return unit


## 单车沿直线掠过孤立基地（通道中心离基地中心 4.6m：在 navmesh 洞外、在 RVO 障碍圈内）。
## 记录 RVO 安全速度相对期望速度的最大偏转；建筑障碍不参与避障时应≈0。
func _rvo_probe() -> Dictionary:
	var cc := _spawn("CommandCenter", RVO_BASE)
	var worker := _spawn("Worker", RVO_BASE + Vector3(-14.0, 0.0, 4.6))
	for _f in range(150):
		await get_tree().physics_frame
	var movement: Node = worker.find_child("Movement", true, false)
	var stats := {"samples_near": 0, "deviated": 0, "max_angle_deg": 0.0, "min_speed_ratio": 1.0,
		"obstacle_avoidance_enabled": bool(cc.find_child("MovementObstacle", true, false).get("avoidance_enabled"))}
	var on_velocity := func(safe: Vector3) -> void:
		var desired: Vector3 = movement.get("velocity")
		var d2 := Vector2(desired.x, desired.z)
		var s2 := Vector2(safe.x, safe.z)
		if d2.length() < 0.001:
			return
		var to_cc := Vector2(worker.global_position.x - cc.global_position.x, worker.global_position.z - cc.global_position.z)
		if to_cc.length() > 3.48 + 3.0:
			return
		stats["samples_near"] += 1
		var angle := rad_to_deg(absf(d2.angle_to(s2))) if s2.length() > 0.001 else 180.0
		stats["max_angle_deg"] = maxf(float(stats["max_angle_deg"]), angle)
		stats["min_speed_ratio"] = minf(float(stats["min_speed_ratio"]), s2.length() / d2.length())
		if angle > 3.0 or s2.length() / d2.length() < 0.9:
			stats["deviated"] += 1
	movement.velocity_computed.connect(on_velocity)
	movement.call("move", RVO_BASE + Vector3(14.0, 0.0, 4.6))
	for _f in range(360):
		await get_tree().physics_frame
	movement.velocity_computed.disconnect(on_velocity)
	print("[JAM] RVO 探针：建筑 avoidance=%s 近处样本=%d 偏转样本=%d 最大偏转=%.1f° 最小速比=%.2f" % [
		str(stats["obstacle_avoidance_enabled"]), stats["samples_near"], stats["deviated"],
		stats["max_angle_deg"], stats["min_speed_ratio"]])
	worker.queue_free()
	cc.queue_free()
	for _f in range(60):
		await get_tree().physics_frame
	return stats


func _jam_run(gap: float, seconds: float) -> Dictionary:
	var cc_offset := 1.9 + gap + 3.48
	var refinery := _spawn("OreRefinery", BASE)
	var cc := _spawn("CommandCenter", BASE + Vector3(cc_offset, 0.0, 0.0))
	refinery.set("service_radius_m", 34.0)
	refinery.set("claim_interval_s", 0.2)
	refinery.set("worker_capacity", WORKER_COUNT)
	for z in [-3.0, 3.0]:
		var ore: Node3D = (load("res://source/match/units/non-player/ResourceA.tscn") as PackedScene).instantiate()
		ore.set("resource_a", 5000)
		_m.get_node("Map/Resources").add_child(ore)
		ore.global_position = BASE + Vector3(cc_offset + 16.0, 0.0, z)
	var workers: Array = []
	for i in WORKER_COUNT:
		workers.append(_spawn("Worker", BASE + Vector3(-3.0 + 3.0 * float(i), 0.0, 9.0)))
	for _f in range(180):
		await get_tree().physics_frame
	var movement_script = load("res://source/match/units/traits/Movement.gd")
	var stats_before: Dictionary = movement_script.recovery_stats.duplicate()
	var history := {}
	var stuck_flag := {}
	var clip_flag := {}
	var trace := {}
	var last_pos := {}
	var result := {"gap_m": gap, "seconds": seconds, "stuck_episodes": 0, "stuck_seconds": 0.0,
		"min_surface_gap_m": 99.0, "clip_frames": 0, "frames": 0}
	var refinery_shape: CollisionShape3D = refinery.find_child("CollisionShape3D", false, false)
	var box_half: Vector3 = (refinery_shape.shape as BoxShape3D).size * 0.5
	var dt := 1.0 / float(Engine.physics_ticks_per_second)
	var frames := int(seconds * Engine.physics_ticks_per_second)
	var window := int(STUCK_WINDOW_S * Engine.physics_ticks_per_second)
	for frame in frames:
		await get_tree().physics_frame
		result["frames"] += 1
		for worker in workers:
			if not is_instance_valid(worker):
				continue
			var p: Vector3 = worker.global_position
			var to_cc := Vector2(p.x - cc.global_position.x, p.z - cc.global_position.z).length() - 3.48
			var local: Vector3 = refinery_shape.global_transform.affine_inverse() * Vector3(p.x, refinery_shape.global_position.y, p.z)
			var outside := Vector2(maxf(absf(local.x) - box_half.x, 0.0), maxf(absf(local.z) - box_half.z, 0.0))
			var to_refinery := outside.length() if outside.length() > 0.0 else -minf(box_half.x - absf(local.x), box_half.z - absf(local.z))
			var surface := minf(to_cc, to_refinery) - WORKER_BODY_RADIUS
			if surface < float(result["min_surface_gap_m"]):
				var mvm: Node = worker.find_child("Movement", true, false)
				result["min_gap_at"] = "t=%.1f %s (%.2f,%.2f) to_cc=%.2f to_ref=%.2f mode=%s r=%.2f moving=%s" % [
					frame * dt, worker.name, p.x - BASE.x, p.z - BASE.z, to_cc, to_refinery,
					str(mvm.get("_recovery_mode")), float(mvm.get("radius")), str(mvm.get("_committed_target") != null)]
			result["min_surface_gap_m"] = minf(float(result["min_surface_gap_m"]), surface)
			var key: int = worker.get_instance_id()
			var last_p: Vector3 = last_pos.get(key, p)
			var last_to_cc := Vector2(last_p.x - cc.global_position.x, last_p.z - cc.global_position.z).length() - 3.48
			if to_cc < 1.15 and last_to_cc >= 1.15 and int(result.get("cross_dumps", 0)) < 6:
				result["cross_dumps"] = int(result.get("cross_dumps", 0)) + 1
				var mvx: Node = worker.find_child("Movement", true, false)
				worker.global_position = last_p
				var redo: Vector3 = mvx._push_out_of_static_obstacles(p, true)
				worker.global_position = p
				print("[JAM] 跨站距 t=%.2f %s last=(%.2f,%.2f)%.2f now=(%.2f,%.2f)%.2f step=%.3f interim=%.3f vel=%s tgt=%s mode=%s r=%.2f 复算=%.2f flow=%s" % [
					frame * dt, worker.name, last_p.x - BASE.x, last_p.z - BASE.z, last_to_cc,
					p.x - BASE.x, p.z - BASE.z, to_cc, Vector2(p.x - last_p.x, p.z - last_p.z).length(),
					float(mvx.get("_interim_speed")), str(mvx.get("velocity")), str(mvx.get("_committed_target")),
					str(mvx.get("_recovery_mode")), float(mvx.get("radius")),
					Vector2(redo.x - cc.global_position.x, redo.z - cc.global_position.z).length() - 3.48,
					str(mvx.get("flow_mode"))])
			last_pos[key] = p
			if frame % 6 == 0:
				var mvt: Node = worker.find_child("Movement", true, false)
				var tgt = mvt.get("_committed_target")
				if not trace.has(key):
					trace[key] = []
				var lines: Array = trace[key]
				lines.append("t=%.1f p=(%.2f,%.2f) gap=%.2f mode=%s r=%.2f tgt=%s nav_t=%s act=%s" % [
					frame * dt, p.x - BASE.x, p.z - BASE.z, surface, str(mvt.get("_recovery_mode")),
					float(mvt.get("radius")), str(tgt - BASE) if tgt is Vector3 else "null",
					str(mvt.get("target_position") - BASE) if mvt.get("target_position").is_finite() else "INF",
					str(worker.get("action").get_script().resource_path.get_file()) if worker.get("action") != null else "null"])
				if lines.size() > 30:
					lines.pop_front()
			if surface < -0.05:
				result["clip_frames"] += 1
				if not clip_flag.get(key, false):
					result["clip_episodes"] = int(result.get("clip_episodes", 0)) + 1
					var mv: Node = worker.find_child("Movement", true, false)
					print("[JAM] 穿模 t=%.1fs %s at (%.2f,%.2f) 离基地表面=%.2f 离矿场表面=%.2f 目标=%s 动作=%s" % [
						frame * dt, worker.name, p.x - BASE.x, p.z - BASE.z, to_cc, to_refinery,
						str(mv.get("_committed_target")), str(worker.get("action"))])
					if int(result["clip_episodes"]) <= 4:
						for line in trace.get(key, []):
							print("[JAM]   轨迹 ", line)
						var cc_obstacle: Node = cc.find_child("MovementObstacle", true, false)
						var inward: Vector3 = p + (cc.global_position - p).normalized() * 0.1
						var pushed: Vector3 = mv._push_out_of_static_obstacles(inward, true)
						var fp: Dictionary = mv._obstacle_footprint_closest(cc_obstacle, Vector2(p.x, p.z))
						print("[JAM]   推出复验 inward离基地表面=%.2f pushed离基地表面=%.2f fp=%s 在组=%s radius=%.2f" % [
							Vector2(inward.x - cc.global_position.x, inward.z - cc.global_position.z).length() - 3.48,
							Vector2(pushed.x - cc.global_position.x, pushed.z - cc.global_position.z).length() - 3.48,
							str(fp), str(cc_obstacle.is_in_group(Constants.Match.Navigation.DOMAIN_TO_OBSTACLE_GROUP_MAPPING[Constants.Match.Navigation.Domain.TERRAIN])),
							float(mv.get("radius"))])
			elif surface < 0.25 and frame % 30 == 0:
				var mv2: Node = worker.find_child("Movement", true, false)
				var nav_map: RID = mv2.get_navigation_map()
				var closest := NavigationServer3D.map_get_closest_point(nav_map, p)
				print("[JAM] 贴近 t=%.1fs %s at (%.2f,%.2f) 表面间隙=%.2f 离网格=%.2f 目标=%s 下一点=%s 恢复=%s" % [
					frame * dt, worker.name, p.x - BASE.x, p.z - BASE.z, surface,
					Vector2(closest.x - p.x, closest.z - p.z).length(), str(mv2.get("_committed_target")),
					str(mv2.get_next_path_position() - BASE), str(mv2.get("_recovery_mode"))])
			clip_flag[key] = surface < -0.05
			if not history.has(key):
				history[key] = []
			var trail: Array = history[key]
			trail.append(p)
			if trail.size() > window:
				trail.pop_front()
			var movement: Node = worker.find_child("Movement", true, false)
			var moving: bool = movement.get("_committed_target") != null
			var stuck := moving and trail.size() >= window \
				and Vector2(p.x - trail[0].x, p.z - trail[0].z).length() < STUCK_NET_MOVE_M
			if stuck:
				result["stuck_seconds"] += dt
				if not stuck_flag.get(key, false):
					result["stuck_episodes"] += 1
					if minf(to_cc, to_refinery) < 3.0:
						result["stuck_near_structure"] = int(result.get("stuck_near_structure", 0)) + 1
					var kind := _classify_stuck(worker, workers)
					result["stuck_" + kind] = int(result.get("stuck_" + kind, 0)) + 1
					print("[JAM] 卡住 t=%.1fs %s at (%.2f,%.2f) 离基地表面=%.2f 离矿场表面=%.2f 分类=%s" % [
						frame * dt, worker.name, p.x - BASE.x, p.z - BASE.z, to_cc, to_refinery, kind])
			stuck_flag[key] = stuck
	var delta := {}
	for k in movement_script.recovery_stats:
		delta[k] = int(movement_script.recovery_stats[k]) - int(stats_before.get(k, 0))
	result["recovery_delta"] = delta
	result["delivered_count"] = int(refinery.get("delivered_count"))
	result["delivered_amount"] = int(refinery.get("delivered_amount"))
	print("[JAM] 间隙=%.2fm %ds：交付=%d 卡住次数=%d（建筑旁 %d）卡住秒数=%.1f 最小表面间隙=%.2f 穿模帧=%d 脱困=%s 分类 head_on=%d drop_overlap=%d route_cross=%d alone=%d" % [
		gap, int(seconds), result["delivered_count"], result["stuck_episodes"],
		int(result.get("stuck_near_structure", 0)), result["stuck_seconds"],
		result["min_surface_gap_m"], result["clip_frames"], JSON.stringify(delta),
		int(result.get("stuck_head_on", 0)), int(result.get("stuck_drop_overlap", 0)),
		int(result.get("stuck_route_cross", 0)), int(result.get("stuck_alone", 0))])
	return result


## 卡住开始时看一次邻居，不改单位行为。优先：对向、落点重叠、去程回程交叉。
func _classify_stuck(worker: Node, workers: Array) -> String:
	var movement: Node = worker.find_child("Movement", true, false)
	var mine: Vector2 = _travel_dir(worker, movement)
	var my_target: Vector3 = _committed(movement)
	var head_on := false
	var drop_overlap := false
	var route_cross := false
	var my_cargo := int(worker.get("resource_a")) + int(worker.get("resource_b"))
	for other in workers:
		if other == worker or not is_instance_valid(other):
			continue
		var gap_m := Vector2(
			other.global_position.x - worker.global_position.x,
			other.global_position.z - worker.global_position.z).length()
		if gap_m > 8.0:
			continue
		var other_movement: Node = other.find_child("Movement", true, false)
		var theirs: Vector2 = _travel_dir(other, other_movement)
		if mine.length() > 0.2 and theirs.length() > 0.2 and mine.normalized().dot(theirs.normalized()) < -0.35:
			head_on = true
		var other_target := _committed(other_movement)
		if my_target.is_finite() and other_target.is_finite() \
				and Vector2(my_target.x - other_target.x, my_target.z - other_target.z).length() < 2.2:
			drop_overlap = true
		var other_cargo := int(other.get("resource_a")) + int(other.get("resource_b"))
		if (my_cargo > 0) != (other_cargo > 0):
			route_cross = true
	if head_on:
		return "head_on"
	if drop_overlap:
		return "drop_overlap"
	if route_cross:
		return "route_cross"
	return "alone"


func _travel_dir(unit: Node, movement: Node) -> Vector2:
	if movement == null:
		return Vector2.ZERO
	var velocity: Vector3 = movement.get("velocity")
	var planar := Vector2(velocity.x, velocity.z)
	if planar.length() > 0.05:
		return planar
	var target := _committed(movement)
	if not target.is_finite():
		return Vector2.ZERO
	return Vector2(target.x - unit.global_position.x, target.z - unit.global_position.z)


func _committed(movement: Node) -> Vector3:
	if movement == null:
		return Vector3.INF
	var target = movement.get("_committed_target")
	return target if target is Vector3 else Vector3.INF


## 重烘耗时：主线程同步解析段（_rebake 调用本身）+ 到新网格换入的总延迟。
func _rebake_timing() -> Dictionary:
	var terrain: Node = _m.navigation.terrain
	var rows: Array = []
	for i in 3:
		while bool(terrain.get("_is_baking")) or bool(terrain.get_script().server_busy):
			await get_tree().process_frame
		var revision := int(terrain.get("bake_revision"))
		terrain.set("_is_baking", true)
		var t0 := Time.get_ticks_usec()
		terrain.call("_rebake")
		var t1 := Time.get_ticks_usec()
		while int(terrain.get("bake_revision")) == revision:
			await get_tree().process_frame
		var t2 := Time.get_ticks_usec()
		rows.append({"main_thread_ms": (t1 - t0) / 1000.0, "total_ms": (t2 - t0) / 1000.0})
	print("[JAM] 重烘耗时 %s" % JSON.stringify(rows))
	return {"rows": rows}
