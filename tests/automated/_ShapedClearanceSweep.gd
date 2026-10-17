extends Node

## ============================================================================
## 独立复核探针（第三方自写，2026-10-01）
## 目标：不复用主线任何探针/结论，自己量：
##   ① 工兵 Worker：CollisionShape3D 类型/半径、逻辑 radius、是否参与 carve；
##   ② 兵营 Barracks：CollisionShape3D 类型/size、逻辑 radius、carve 属性与导航洞；
##   ③ 金矿 ResourceA：CollisionShape3D 半径、affect_navigation_mesh、导航层有没有洞；
##   ④ 四方向贴边：工兵从 ±X/±Z 走向兵营，静止后的 hull-to-hull 表面间隙
##      （两种口径：A=碰撞形状解析解；B=近地真实顶点凸包）。
## 只读测量：不修改 source/ 任何文件。
## 输出：agent/runs/2026-10-01-indep-verify-collider-clearance/indep-probe.json
## ============================================================================

const MAP_SCENE := "res://source/match/maps/PlainAndSimple.tscn"
const RUN_DIR := "res://agent/runs/2026-10-01-indep-verify-collider-clearance"
var OUT_JSON := RUN_DIR + "/sweep-" + (OS.get_environment("AIRTS_SWEEP_UNIT") if OS.get_environment("AIRTS_SWEEP_UNIT") != "" else "Worker") + ".json"

const TEST_BASE := Vector3(100.0, 0.0, 100.0)
const START_DIST := 9.0
const NEAR_GROUND_BAND := 1.0
const DIRS := [Vector3(1, 0, 0), Vector3(-1, 0, 0), Vector3(0, 0, 1), Vector3(0, 0, -1)]
const REPS := 3
## 排除非本体几何（选圈/高亮/索敌圈/血条/粒子）——与本人自己的判据一致
const EXCLUDE_TOKENS := ["Selection", "Highlight", "Targetability", "HealthBar", "Sparkling", "RallyPoint"]

var _m: Node
var _player: Node
var _nav_map: RID
var _out := {}


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(RUN_DIR))
	get_tree().create_timer(400.0).timeout.connect(func() -> void:
		push_error("[INDEP] 超时兜底触发，退出 rc=2")
		_flush()
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
	print("[INDEP] 等待 Match 初始化…")
	for _f in range(180):
		await get_tree().physics_frame
	_player = _m.get_node("Players").get_children()[0]
	var nav_node: Node = _m.get("navigation")
	_nav_map = nav_node.call("get_navigation_map_rid_by_domain", Constants.Match.Navigation.Domain.TERRAIN)
	print("[INDEP] nav_map valid=%s  player=%s" % [str(_nav_map.is_valid()), str(_player.name)])
	_out["nav_map_valid"] = _nav_map.is_valid()
	_out["agent_radius_navmesh"] = _agent_radius()
	_out["map_closest_point_at_test_base_m"] = _closest_dist(TEST_BASE)

	# ---------------- 阶段 1：实体几何 ----------------
	print("[INDEP] ===== 阶段 1：实体几何静态读（运行时） =====")
	var barracks_probe: Node3D = load("res://source/match/units/Barracks.tscn").instantiate()
	_m.call("_setup_and_spawn_unit", barracks_probe, Transform3D(Basis.IDENTITY, TEST_BASE), _player, false)
	var worker_probe: Node3D = load("res://source/match/units/Worker.tscn").instantiate()
	_m.call("_setup_and_spawn_unit", worker_probe, Transform3D(Basis.IDENTITY, TEST_BASE + Vector3(0, 0, 12)), _player, false)
	var ore_probe: Node3D = load("res://source/match/units/non-player/ResourceA.tscn").instantiate()
	_m.call("_setup_and_spawn_unit", ore_probe, Transform3D(Basis.IDENTITY, TEST_BASE + Vector3(0, 0, 20)), _player, false)
	for _f in range(120):
		await get_tree().physics_frame

	_out["entities"] = {}
	for entry in [["Worker", worker_probe], ["Barracks", barracks_probe], ["ResourceA", ore_probe]]:
		var rep: Dictionary = _entity_report(entry[1] as Node3D, 0.0)
		_out["entities"][entry[0]] = rep
		_print_entity(entry[0], rep)

	# 地图自带金矿（对照：非我生成）
	var map_res: Node3D = null
	for r in get_tree().get_nodes_in_group("resource_units"):
		if r is Node3D and (r as Node3D).global_position.distance_to(Vector3(26.9272, 0, 57.2079)) < 1.0:
			map_res = r
	if map_res != null:
		var rep2: Dictionary = _entity_report(map_res, 0.0)
		_out["entities"]["ResourceA_map(26.9,57.2)"] = rep2
		_print_entity("ResourceA_map", rep2)

	# ---------------- 阶段 2：导航层洞 ----------------
	print("[INDEP] ===== 阶段 2：NavigationServer3D 洞探测 =====")
	var nav_rows := {}
	for entry in [["Barracks", barracks_probe], ["ResourceA", ore_probe], ["Worker", worker_probe]]:
		var n: Node3D = entry[1]
		var p: Vector3 = n.global_position
		var closest: Vector3 = NavigationServer3D.map_get_closest_point(_nav_map, p)
		var owner_ok: bool = NavigationServer3D.map_get_closest_point_owner(_nav_map, p).is_valid()
		var row := {
			"position": [p.x, p.y, p.z],
			"closest": [closest.x, closest.y, closest.z],
			"closest_xz_distance_m": Vector2(closest.x - p.x, closest.z - p.z).length(),
			"closest_owner_valid": owner_ok,
			"is_point_on_navmesh": Vector2(closest.x - p.x, closest.z - p.z).length() < 0.05,
		}
		row["hole_boundary_ring_m"] = _hole_boundary(_nav_map, p, 8)
		nav_rows[entry[0]] = row
		print("[INDEP][NAV] %s pos=(%.2f,%.2f) closest=(%.2f,%.2f) 吸附距离=%.3fm on_mesh=%s" % [
			entry[0], p.x, p.z, closest.x, closest.z, row.closest_xz_distance_m, str(row.is_point_on_navmesh)])
	if map_res != null:
		var p3: Vector3 = map_res.global_position
		var c3: Vector3 = NavigationServer3D.map_get_closest_point(_nav_map, p3)
		nav_rows["ResourceA_map"] = {
			"position": [p3.x, p3.y, p3.z],
			"closest_xz_distance_m": Vector2(c3.x - p3.x, c3.z - p3.z).length(),
		}
		print("[INDEP][NAV] ResourceA_map pos=(%.2f,%.2f) 吸附距离=%.3fm" % [
			p3.x, p3.z, nav_rows["ResourceA_map"].closest_xz_distance_m])
	_out["nav"] = nav_rows

	# 清场
	for n in [worker_probe, ore_probe, barracks_probe]:
		n.queue_free()
	for _f in range(40):
		await get_tree().physics_frame

	# ---------------- 阶段 3：四方向贴边 ----------------
	print("[INDEP] ===== 阶段 3：四方向贴边（Worker ← Barracks） =====")
	var runs := []
	for di in [int(OS.get_environment("AIRTS_SWEEP_DI")) if OS.get_environment("AIRTS_SWEEP_DI") != "" else 0]:
		for rep in range(1):
			# 每个组合用**独立基地点**：同一位置反复生成会被上一次残留的导航洞
			# 把新兵营吸附走 3.8m（实测），污染"9m 起步"的前提。
			var base := Vector3(70.0 + float(rep) * 45.0, 0.0, 70.0 + float(di) * 30.0)
			var row: Dictionary = await _one_run(base, DIRS[di], rep)
			runs.append(row)
			print("[INDEP][4DIR] base=(%.0f,%.0f) dir=%s rep=%d 中心距=%.3f | 口径A=%.3f 口径B=%.3f 口径C=%.3f | 停止=%s 帧=%d 终态=%s | 下达后落点距中心=%.3f (committed=%.3f) | clamp探针=%.3f push探针=%.3f | 理论standoff=%.3f carve=%.3f | yaw=%.0f°" % [
				row.base[0], row.base[1], str(row.direction), rep, row.center_distance_m,
				row.gap_collision_hull_m, row.gap_near_ground_hull_m, row.gap_aabb_corner_m,
				str(row.stopped), row.frames, str(row.movement_end_reason),
				row.target_after_move_distance_m, row.committed_after_move_distance_m,
				row.clamp_probe_distance_m, row.push_probe_distance_m,
				row.push_stand_off_theory_m, row.carve_clearance_m, row.unit_final_yaw_deg])
	_out["four_direction"] = runs

	# 汇总
	_out["summary"] = _summarize(runs)
	print("[INDEP] ===== 汇总 =====")
	print(JSON.stringify(_out["summary"], "  "))
	print("[INDEP] 完成")
	_flush()
	get_tree().quit(0)


# ---------------------------------------------------------------- 四方向单次

func _one_run(base: Vector3, dir: Vector3, rep: int) -> Dictionary:
	var _obs_name := OS.get_environment("AIRTS_SWEEP_OBSTACLE")
	if _obs_name == "":
		_obs_name = "Barracks"
	var barracks: Node3D = load("res://source/match/units/" + _obs_name + ".tscn").instantiate()
	_m.call("_setup_and_spawn_unit", barracks, Transform3D(Basis.IDENTITY, base), _player, false)
	var _unit_name := OS.get_environment("AIRTS_SWEEP_UNIT")
	if _unit_name == "":
		_unit_name = "Worker"
	var worker: Node3D = load("res://source/match/units/" + _unit_name + ".tscn").instantiate()
	var want := base + dir * START_DIST
	_m.call("_setup_and_spawn_unit", worker, Transform3D(Basis.IDENTITY, want), _player, false)
	for _f in range(180):
		await get_tree().physics_frame
	var ob_pos: Vector3 = barracks.global_position
	var u_start: Vector3 = worker.global_position
	var movement: Node = worker.find_child("Movement", true, false)
	var ended := {"reason": ""}
	movement.movement_ended.connect(func(reason: String) -> void: ended["reason"] = str(reason))
	movement.call("move", ob_pos)
	# 下达后立刻读"被钳制后的任务落点"⇒ 第一限制层的直接证据
	var target_after_move_d := _dist_from_center(movement.get("target_position"), ob_pos)
	var committed_after_move_d := _dist_from_center(movement.get("_committed_target"), ob_pos)
	var prev: Vector3 = worker.global_position
	var stable := 0
	var frames := 0
	var min_center := 1e9
	var last_target_d := -1.0
	var last_committed_d := -1.0
	while frames < 420:
		await get_tree().physics_frame
		frames += 1
		var cur: Vector3 = worker.global_position
		min_center = minf(min_center, Vector2(cur.x - ob_pos.x, cur.z - ob_pos.z).length())
		var tp: Variant = movement.get("target_position")
		if tp != null and is_finite((tp as Vector3).x):
			last_target_d = Vector2((tp as Vector3).x - ob_pos.x, (tp as Vector3).z - ob_pos.z).length()
		var ct: Variant = movement.get("_committed_target")
		if ct != null:
			last_committed_d = Vector2((ct as Vector3).x - ob_pos.x, (ct as Vector3).z - ob_pos.z).length()
		if Vector2(cur.x - prev.x, cur.z - prev.z).length() < 0.02:
			stable += 1
		else:
			stable = 0
		prev = cur
		if stable >= 45:
			break
	var u_end: Vector3 = worker.global_position
	# 直接调用两个层函数：证明是哪一层把落点定在多远
	var clamp_probe: Vector3 = movement.call("_clamp_to_reachable", ob_pos)
	var push_probe: Vector3 = movement.call("_push_out_of_static_obstacles", ob_pos)
	var clamp_probe_d := Vector2(clamp_probe.x - ob_pos.x, clamp_probe.z - ob_pos.z).length()
	var push_probe_d := Vector2(push_probe.x - ob_pos.x, push_probe.z - ob_pos.z).length()
	var yaw_deg := rad_to_deg(worker.global_transform.basis.get_euler().y)
	var center_dist := Vector2(u_end.x - ob_pos.x, u_end.z - ob_pos.z).length()
	var worker_r := _collision_half_radius(worker)
	var ob_shape: CollisionShape3D = _first_active_shape(barracks)
	# 口径 A：碰撞形状解析最近表面距离
	var gap_a := -1.0
	if ob_shape != null and ob_shape.shape is BoxShape3D:
		var xf: Transform3D = ob_shape.global_transform
		var half: Vector3 = (ob_shape.shape as BoxShape3D).size * 0.5
		var lp: Vector3 = xf.affine_inverse() * Vector3(u_end.x, xf.origin.y, u_end.z)
		var clamped := Vector3(clampf(lp.x, -half.x, half.x), 0.0, clampf(lp.z, -half.z, half.z))
		var wp: Vector3 = xf * clamped
		gap_a = (Vector2(wp.x - u_end.x, wp.z - u_end.z).length()) - worker_r
	# 口径 B：近地真实顶点凸包最小间隙
	var hull_u: PackedVector2Array = _near_ground_hull(worker, NEAR_GROUND_BAND)
	var hull_o: PackedVector2Array = _near_ground_hull(barracks, NEAR_GROUND_BAND)
	var gap_b := _poly_gap(hull_u, hull_o)
	# 口径 C：主线 AABB 角点口径（仅对照）
	var half_u := _aabb_corner_half(worker, dir, 0.6)
	var half_o := _aabb_corner_half(barracks, dir, 0.6)
	var gap_c := center_dist - half_u - half_o
	# 第一限制层线索
	var clearance: float = Utils.Match.Unit.Movement.carve_clearance_of(barracks)
	var own_r := float(worker.get("radius"))
	var ob_r := float(barracks.get("radius"))
	var stand_off := ob_r + own_r + 0.2
	var committed: Variant = movement.get("_committed_target")
	var committed_d := -1.0
	if committed != null:
		var cv: Vector3 = committed
		committed_d = Vector2(cv.x - ob_pos.x, cv.z - ob_pos.z).length()
	var closest_at_end: Vector3 = NavigationServer3D.map_get_closest_point(_nav_map, u_end)
	var on_mesh := Vector2(closest_at_end.x - u_end.x, closest_at_end.z - u_end.z).length() < 0.15
	var row := {
		"direction": [dir.x, dir.z], "repeat": rep,
		"frames": frames, "stopped": stable >= 45,
		"base": [base.x, base.z],
		"obstacle_spawn_offset_m": Vector2(ob_pos.x - base.x, ob_pos.z - base.z).length(),
		"nearby_obstacles_within_20m": _nearby_obstacle_count(base, 20.0),
		"unit_spawn_offset_m": Vector2(u_start.x - want.x, u_start.z - want.z).length(),
		"start_center_distance_m": Vector2(u_start.x - ob_pos.x, u_start.z - ob_pos.z).length(),
		"center_distance_m": center_dist,
		"unit_collision_radius_m": worker_r,
		"obstacle_box_half_xz_m": ([ob_shape.shape.size.x * 0.5, ob_shape.shape.size.z * 0.5] if ob_shape != null and ob_shape.shape is BoxShape3D else []),
		"gap_collision_hull_m": gap_a,
		"gap_near_ground_hull_m": gap_b,
		"near_ground_hull_unit_pts": hull_u.size(),
		"near_ground_hull_obstacle_pts": hull_o.size(),
		"gap_aabb_corner_m": gap_c,
		"aabb_corner_unit_half_m": half_u,
		"aabb_corner_obstacle_half_m": half_o,
		"unit_radius_m": own_r,
		"obstacle_radius_m": ob_r,
		"carve_clearance_m": clearance,
		"push_stand_off_theory_m": stand_off,
		"committed_target_distance_m": committed_d,
		"target_desired_distance": float(movement.get("target_desired_distance")),
		"target_after_move_distance_m": target_after_move_d,
		"committed_after_move_distance_m": committed_after_move_d,
		"last_target_distance_m": last_target_d,
		"last_committed_distance_m": last_committed_d,
		"min_center_distance_m": min_center,
		"clamp_probe_distance_m": clamp_probe_d,
		"push_probe_distance_m": push_probe_d,
		"movement_end_reason": ended["reason"],
		"unit_final_pos": [snappedf(u_end.x, 0.001), snappedf(u_end.y, 0.001), snappedf(u_end.z, 0.001)],
		"unit_final_yaw_deg": snappedf(yaw_deg, 0.1),
		"hull_unit_final": _poly_to_arr(hull_u),
		"hull_obstacle_final": _poly_to_arr(hull_o),
		"unit_on_navmesh_at_end": on_mesh,
		"agent_avoidance_enabled": bool(movement.get("avoidance_enabled")),
		"obstacle_avoidance_enabled": bool(barracks.find_child("MovementObstacle", true, false).get("avoidance_enabled")),
	}
	barracks.queue_free()
	worker.queue_free()
	for _f in range(60):
		await get_tree().physics_frame
	return row


func _nearby_obstacle_count(at: Vector3, radius: float) -> int:
	var group: String = Constants.Match.Navigation.DOMAIN_TO_OBSTACLE_GROUP_MAPPING[Constants.Match.Navigation.Domain.TERRAIN]
	var n := 0
	for ob in get_tree().get_nodes_in_group(group):
		if ob is Node3D and (ob as Node3D).global_position.distance_to(at) < radius:
			n += 1
	return n


# ---------------------------------------------------------------- 几何读取

func _entity_report(node: Node3D, _unused: float) -> Dictionary:
	var o: Vector3 = node.global_position
	var rep := {
		"scene": node.scene_file_path,
		"global_position": [o.x, o.y, o.z],
		"unit_radius_property": _num(node.get("radius")),
		"collision_shapes": [],
		"meshes": [],
		"obstacle": {},
		"movement": {},
		"near_ground_hull_radius_m": 0.0,
		"full_projection_hull_radius_m": 0.0,
		"all_vertex_world_aabb": [],
	}
	var full_pts := PackedVector2Array()
	var near_pts := PackedVector2Array()
	var vmin := Vector3(1e20, 1e20, 1e20)
	var vmax := Vector3(-1e20, -1e20, -1e20)
	for cs in node.find_children("*", "CollisionShape3D", true, false):
		var c := cs as CollisionShape3D
		var d := _shape_desc(c)
		rep.collision_shapes.append(d)
	for mi in node.find_children("*", "MeshInstance3D", true, false):
		var m := mi as MeshInstance3D
		if _excluded(m):
			continue
		var pts := _mesh_world_points(m)
		var maabb := AABB()
		var first := true
		for p in pts:
			vmin = vmin.min(p)
			vmax = vmax.max(p)
			full_pts.append(Vector2(p.x, p.z))
			if p.y - o.y <= NEAR_GROUND_BAND:
				near_pts.append(Vector2(p.x, p.z))
			if first:
				maabb = AABB(p, Vector3.ZERO)
				first = false
			else:
				maabb = maabb.expand(p)
		rep.meshes.append({
			"path": str(m.get_path()).replace(str(node.get_path()), ""),
			"mesh_class": m.mesh.get_class() if m.mesh != null else "null",
			"surface_count": m.mesh.get_surface_count() if m.mesh != null else 0,
			"vertex_count": pts.size(),
			"mesh_local_aabb_size": _v3(m.mesh.get_aabb().size) if m.mesh != null else [],
			"global_scale": _v3(m.global_transform.basis.get_scale()),
			"world_vertex_aabb_min": _v3(maabb.position),
			"world_vertex_aabb_size": _v3(maabb.size),
			"skinned": m.get("skin") != null,
		})
	var ob: Node = node.find_child("MovementObstacle", true, false)
	if ob != null:
		var verts: PackedVector3Array = ob.get("vertices")
		var outer := 0.0
		var wpts := PackedVector2Array()
		var xf: Transform3D = ob.global_transform
		for v in verts:
			var w: Vector3 = xf * v
			outer = maxf(outer, Vector2(w.x - o.x, w.z - o.z).length())
			wpts.append(Vector2(w.x, w.z))
		rep.obstacle = {
			"exists": true,
			"radius": _num(ob.get("radius")),
			"affect_navigation_mesh": bool(ob.get("affect_navigation_mesh")),
			"carve_from_collision_bounds": bool(ob.get("carve_from_collision_bounds")),
			"carve_vertices_from_radius": bool(ob.get("carve_vertices_from_radius")),
			"avoidance_enabled": bool(ob.get("avoidance_enabled")),
			"vertices_count": verts.size(),
			"vertices_world_outer_radius_m": outer,
			"in_obstacle_group": ob.is_in_group(Constants.Match.Navigation.DOMAIN_TO_OBSTACLE_GROUP_MAPPING[Constants.Match.Navigation.Domain.TERRAIN]),
			"in_bake_group": ob.is_in_group(Constants.Match.Navigation.DOMAIN_TO_GROUP_MAPPING[Constants.Match.Navigation.Domain.TERRAIN]),
			"vertices_world_hull": _poly_to_arr(Geometry2D.convex_hull(wpts)) if wpts.size() >= 3 else [],
		}
	else:
		rep.obstacle = {"exists": false}
	var mv: Node = node.find_child("Movement", true, false)
	if mv != null:
		rep.movement = {
			"exists": true,
			"radius": _num(mv.get("radius")),
			"speed": _num(mv.get("speed")),
			"target_desired_distance": _num(mv.get("target_desired_distance")),
			"path_desired_distance": _num(mv.get("path_desired_distance")),
			"neighbor_distance": _num(mv.get("neighbor_distance")),
			"avoidance_enabled": bool(mv.get("avoidance_enabled")),
		}
	else:
		rep.movement = {"exists": false}
	var hu := Geometry2D.convex_hull(near_pts)
	var fu := Geometry2D.convex_hull(full_pts)
	rep.near_ground_hull_radius_m = _poly_max_radius(hu, Vector2(o.x, o.z))
	rep.full_projection_hull_radius_m = _poly_max_radius(fu, Vector2(o.x, o.z))
	rep.near_ground_hull = _poly_to_arr(hu)
	rep.full_projection_hull = _poly_to_arr(fu)
	rep.all_vertex_world_aabb = [_v3(vmin), _v3(vmax)]
	rep.carve_clearance_of_m = Utils.Match.Unit.Movement.carve_clearance_of(node)
	return rep


func _shape_desc(c: CollisionShape3D) -> Dictionary:
	var d := {
		"path": str(c.get_path()),
		"disabled": c.disabled,
		"local_origin": _v3(c.transform.origin),
		"global_origin": _v3(c.global_transform.origin),
		"global_basis": [
			_v3(c.global_transform.basis.x), _v3(c.global_transform.basis.y), _v3(c.global_transform.basis.z)
		],
		"global_scale": _v3(c.global_transform.basis.get_scale()),
	}
	if c.shape == null:
		d["shape_class"] = "null"
		return d
	var s := c.shape
	d["shape_class"] = s.get_class()
	if s is CylinderShape3D:
		d["radius"] = s.radius
		d["height"] = s.height
		d["shape_tokens"] = ["CylinderShape3D", "radius=%.4f" % s.radius, "height=%.4f" % s.height]
	elif s is BoxShape3D:
		d["size"] = _v3(s.size)
		d["half"] = _v3(s.size * 0.5)
		d["shape_tokens"] = ["BoxShape3D", "size=(%.4f,%.4f,%.4f)" % [s.size.x, s.size.y, s.size.z]]
		d["max_xz_half"] = maxf(s.size.x, s.size.z) * 0.5
	elif s is SphereShape3D:
		d["radius"] = s.radius
		d["shape_tokens"] = ["SphereShape3D", "radius=%.4f" % s.radius]
	elif s is CapsuleShape3D:
		d["radius"] = s.radius
		d["height"] = s.height
		d["shape_tokens"] = ["CapsuleShape3D"]
	else:
		d["shape_tokens"] = ["unsupported:" + s.get_class()]
	return d


func _excluded(m: MeshInstance3D) -> bool:
	var p := str(m.get_path())
	for t in EXCLUDE_TOKENS:
		if p.contains(t):
			return true
	return false


func _mesh_world_points(m: MeshInstance3D) -> PackedVector3Array:
	var out := PackedVector3Array()
	if m.mesh == null:
		return out
	var xf: Transform3D = m.global_transform
	for s in range(m.mesh.get_surface_count()):
		var arrays := m.mesh.surface_get_arrays(s)
		if arrays.is_empty():
			continue
		var verts: Variant = arrays[Mesh.ARRAY_VERTEX]
		if verts == null:
			continue
		for v in verts:
			out.append(xf * (v as Vector3))
	return out


func _near_ground_hull(node: Node3D, band: float) -> PackedVector2Array:
	var o: Vector3 = node.global_position
	var pts := PackedVector2Array()
	for mi in node.find_children("*", "MeshInstance3D", true, false):
		var m := mi as MeshInstance3D
		if _excluded(m):
			continue
		for p in _mesh_world_points(m):
			if p.y - o.y <= band:
				pts.append(Vector2(p.x, p.z))
	if pts.size() < 3:
		return PackedVector2Array()
	return Geometry2D.convex_hull(pts)


## 主线口径（_FourDirectionClearanceProbe._ground_half）：每个 mesh 的 AABB 8 角点，
## 丢掉高于根 y+0.6 的角点，沿 dir 取最大投影。
func _aabb_corner_half(node: Node3D, dir: Vector3, height_limit: float) -> float:
	var out := 0.0
	var o: Vector3 = node.global_position
	for mi in node.find_children("*", "MeshInstance3D", true, false):
		var m := mi as MeshInstance3D
		if _excluded(m):
			continue
		var local: AABB = m.get_aabb()
		if m.mesh != null and local.size.length() < 0.01:
			local = m.mesh.get_aabb()
		if local.size.length() < 0.001:
			continue
		var xf: Transform3D = m.global_transform
		for i in range(8):
			var pt: Vector3 = xf * local.get_endpoint(i)
			if pt.y - o.y > height_limit:
				continue
			var planar := Vector2(pt.x - o.x, pt.z - o.z)
			out = maxf(out, absf(planar.dot(Vector2(dir.x, dir.z).normalized())))
	return out


## 从中心沿 8 个方向步进，找第一个"落在导航面上"的点 ⇒ 该方向的洞边界半径（无洞则≈0.2）。
func _hole_boundary(nav_map: RID, center: Vector3, dir_count: int) -> Array:
	var out := []
	for k in range(dir_count):
		var a := TAU * float(k) / float(dir_count)
		var d := Vector2(cos(a), sin(a))
		var boundary := -1.0
		var t := 0.2
		while t < 8.0:
			var q := Vector3(center.x + d.x * t, center.y, center.z + d.y * t)
			var c: Vector3 = NavigationServer3D.map_get_closest_point(nav_map, q)
			if Vector2(c.x - q.x, c.z - q.z).length() < 0.02:
				boundary = snappedf(t, 0.05)
				break
			t += 0.05
		out.append([snappedf(d.x, 0.001), snappedf(d.y, 0.001), boundary])
	return out


func _poly_gap(a: PackedVector2Array, b: PackedVector2Array) -> float:
	if a.size() < 3 or b.size() < 3:
		return -1.0
	for p in a:
		if Geometry2D.is_point_in_polygon(p, b):
			return 0.0
	for p in b:
		if Geometry2D.is_point_in_polygon(p, a):
			return 0.0
	for i in range(a.size()):
		var a1 := a[i]
		var a2 := a[(i + 1) % a.size()]
		for j in range(b.size()):
			var b1 := b[j]
			var b2 := b[(j + 1) % b.size()]
			if Geometry2D.segment_intersects_segment(a1, a2, b1, b2) != null:
				return 0.0
	var best := 1e20
	for i in range(a.size()):
		var a1 := a[i]
		var a2 := a[(i + 1) % a.size()]
		for j in range(b.size()):
			var b1 := b[j]
			var b2 := b[(j + 1) % b.size()]
			best = minf(best, _seg_seg_dist(a1, a2, b1, b2))
	return best


func _seg_seg_dist(a1: Vector2, a2: Vector2, b1: Vector2, b2: Vector2) -> float:
	return minf(
		minf(_pt_seg_dist(a1, b1, b2), _pt_seg_dist(a2, b1, b2)),
		minf(_pt_seg_dist(b1, a1, a2), _pt_seg_dist(b2, a1, a2)))


func _pt_seg_dist(p: Vector2, s1: Vector2, s2: Vector2) -> float:
	var d := s2 - s1
	if d.length_squared() < 1e-9:
		return p.distance_to(s1)
	var t := clampf((p - s1).dot(d) / d.length_squared(), 0.0, 1.0)
	return p.distance_to(s1 + d * t)


func _poly_max_radius(poly: PackedVector2Array, center: Vector2) -> float:
	var out := 0.0
	for p in poly:
		out = maxf(out, p.distance_to(center))
	return out


func _poly_to_arr(poly: PackedVector2Array) -> Array:
	var out := []
	for p in poly:
		out.append([snappedf(p.x, 0.001), snappedf(p.y, 0.001)])
	return out


# ---------------------------------------------------------------- 小工具

func _first_active_shape(node: Node3D) -> CollisionShape3D:
	for cs in node.find_children("*", "CollisionShape3D", true, false):
		var c := cs as CollisionShape3D
		if c != null and c.shape != null and not c.disabled:
			return c
	return null


func _collision_half_radius(node: Node3D) -> float:
	var c := _first_active_shape(node)
	if c == null:
		return -1.0
	var sc := c.global_transform.basis.get_scale()
	if c.shape is CylinderShape3D:
		return (c.shape as CylinderShape3D).radius * sc.x
	if c.shape is BoxShape3D:
		return (c.shape as BoxShape3D).size.x * 0.5 * sc.x
	if c.shape is SphereShape3D:
		return (c.shape as SphereShape3D).radius * sc.x
	if c.shape is CapsuleShape3D:
		return (c.shape as CapsuleShape3D).radius * sc.x
	return -1.0


func _agent_radius() -> float:
	var region: Node = _m.get_node_or_null("Navigation")
	var found := -1.0
	for sub in _m.find_children("*", "NavigationRegion3D", true, false):
		var mesh = sub.get("navigation_mesh")
		if mesh != null:
			found = float(mesh.get("agent_radius"))
			break
	return found


func _closest_dist(p: Vector3) -> float:
	if not _nav_map.is_valid():
		return -1.0
	var c: Vector3 = NavigationServer3D.map_get_closest_point(_nav_map, p)
	return Vector2(c.x - p.x, c.z - p.z).length()


func _dist_from_center(v: Variant, center: Vector3) -> float:
	if v == null:
		return -1.0
	var p: Vector3 = v
	if not is_finite(p.x):
		return -1.0
	return Vector2(p.x - center.x, p.z - center.z).length()


func _num(v: Variant) -> float:
	return -1.0 if v == null else float(v)


func _v3(v: Vector3) -> Array:
	return [snappedf(v.x, 0.0001), snappedf(v.y, 0.0001), snappedf(v.z, 0.0001)]


func _summarize(runs: Array) -> Dictionary:
	var s := {}
	for d in DIRS:
		var key := "dir_%s" % ("+X" if d.x > 0 else ("-X" if d.x < 0 else ("+Z" if d.z > 0 else "-Z")))
		var sel := []
		for r in runs:
			if r.direction[0] == d.x and r.direction[1] == d.z:
				sel.append(r)
		if sel.is_empty():
			continue
		var row := {"n": sel.size()}
		for field in ["center_distance_m", "gap_collision_hull_m", "gap_near_ground_hull_m", "gap_aabb_corner_m", "unit_radius_m", "obstacle_radius_m", "carve_clearance_m", "push_stand_off_theory_m", "aabb_corner_unit_half_m", "aabb_corner_obstacle_half_m", "target_after_move_distance_m", "committed_after_move_distance_m", "last_target_distance_m", "last_committed_distance_m", "min_center_distance_m", "clamp_probe_distance_m", "push_probe_distance_m"]:
			var vals := []
			for r in sel:
				vals.append(float(r[field]))
			row[field] = {"mean": snappedf(_mean(vals), 0.001), "min": snappedf(_minv(vals), 0.001), "max": snappedf(_maxv(vals), 0.001), "values": vals.map(func(v): return snappedf(v, 0.001))}
		row["stopped"] = sel.map(func(r): return r.stopped)
		row["movement_end_reason"] = sel.map(func(r): return r.movement_end_reason)
		row["unit_final_yaw_deg"] = sel.map(func(r): return r.unit_final_yaw_deg)
		s[key] = row
	return s


func _mean(v: Array) -> float:
	var t := 0.0
	for x in v:
		t += float(x)
	return t / maxf(1.0, float(v.size()))


func _minv(v: Array) -> float:
	var m := 1e20
	for x in v:
		m = minf(m, float(x))
	return m


func _maxv(v: Array) -> float:
	var m := -1e20
	for x in v:
		m = maxf(m, float(x))
	return m


func _print_entity(label: String, rep: Dictionary) -> void:
	print("[INDEP][E] ---- %s (scene=%s) unit.radius=%s carve_clearance=%.3f" % [
		label, str(rep.scene), str(rep.unit_radius_property), rep.carve_clearance_of_m])
	for d in rep.collision_shapes:
		print("[INDEP][E]   CollisionShape3D %s class=%s tokens=%s disabled=%s gscale=%s" % [
			str(d.path).replace("/root/", ""), str(d.get("shape_class")), str(d.get("shape_tokens")), str(d.disabled), str(d.global_scale)])
	print("[INDEP][E]   obstacle=%s" % JSON.stringify(rep.obstacle))
	print("[INDEP][E]   movement=%s" % JSON.stringify(rep.movement))
	print("[INDEP][E]   近地(≤%.1fm)凸包半径=%.3f 全投影凸包半径=%.3f 顶点世界AABB=%s..%s" % [
		NEAR_GROUND_BAND, rep.near_ground_hull_radius_m, rep.full_projection_hull_radius_m,
		str(rep.all_vertex_world_aabb[0]), str(rep.all_vertex_world_aabb[1])])
	for m in rep.meshes:
		print("[INDEP][E]   mesh %s verts=%d meshLocalAABB=%s gscale=%s worldVertsAABBsize=%s" % [
			str(m.path), m.vertex_count, str(m.mesh_local_aabb_size), str(m.global_scale), str(m.world_vertex_aabb_size)])


func _flush() -> void:
	var f := FileAccess.open(OUT_JSON, FileAccess.WRITE)
	if f == null:
		push_error("[INDEP] 无法写入 " + OUT_JSON)
		return
	f.store_string(JSON.stringify(_out, "  "))
	f.close()
	print("[INDEP] 已写入 " + OUT_JSON)
