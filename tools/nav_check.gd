extends SceneTree
## 定向导航验收：真实高程目标（出生/扩张/台地顶/坡口上下端/桥头/资源）。
## 逐目标核对 navmesh 最近点的 XY 与高度（防止投影到错误平面后宣称可达），
## 逐路径对核对连通与端点高度。不运行对局；4AI 冒烟用 smoke_test.gd。
##
## 用法：Godot_mono_console.exe --rendering-driver opengl3 --path G:\AIRTS\AI_RTS \
##   --script nav_check.gd -- --map=res://source/match/maps/generated/<id>/map_<id>.tscn \
##   --targets=<abs nav_targets.json> --out=<abs nav_check.json> [--size=256]

const COLORS := [Color("66b1ff"), Color("ff5c73"), Color("a5ff99"), Color("ed85ff")]


func _init() -> void:
	_run()


func _run() -> void:
	await process_frame
	var map_path := ""
	var targets_path := ""
	var out_path := "nav_check.json"
	var size := 256.0
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--map="):
			map_path = a.substr(6)
		elif a.begins_with("--targets="):
			targets_path = a.substr(10)
		elif a.begins_with("--out="):
			out_path = a.substr(6)
		elif a.begins_with("--size="):
			size = float(a.substr(7))
	if map_path.is_empty() or targets_path.is_empty():
		push_error("nav_check: missing --map/--targets")
		quit(2)
		return
	var tf := FileAccess.open(targets_path, FileAccess.READ)
	if tf == null:
		push_error("nav_check: cannot read targets %s" % targets_path)
		quit(2)
		return
	var tdata = JSON.parse_string(tf.get_as_text())
	tf.close()
	if not (tdata is Dictionary):
		push_error("nav_check: bad targets json")
		quit(2)
		return

	var map = load(map_path).instantiate()
	var match_node = load("res://source/match/Match.tscn").instantiate()
	var settings = load("res://source/data-model/MatchSettings.gd").new()
	var ps_script = load("res://source/data-model/PlayerSettings.gd")
	var players: Array[Resource] = []
	for i in range(4):
		var p = ps_script.new()
		# 导航验收不需要单位/AI：用 NONE 占位保持 4 槽与地图尺寸，帧率快、
		# 烘焙等待循环不被 AI 逻辑拖慢（4AI 对局冒烟用 smoke_test.gd）。
		p.controller = 0  # Constants.PlayerType.NONE
		p.color = COLORS[i]
		players.append(p)
	settings.players = players
	settings.visibility = 2
	settings.local_player_index = -1
	match_node.settings = settings
	match_node.map = map
	root.add_child(match_node)
	root.gui_disable_input = true
	root.borderless = true
	root.position = Vector2i(3600, 80)
	for _i in range(12):
		await process_frame
		await physics_frame

	var nav = match_node.get("navigation")
	if nav == null:
		_write(out_path, map_path, false, {"error": "navigation node missing"}, [], 0.0)
		quit(1)
		return
	var terrain_map: RID = nav.get_navigation_map_rid_by_domain(1)  # TERRAIN
	var t0 := Time.get_ticks_msec()
	var first_target: Vector3 = Vector3(size / 2.0, 1.0, size / 2.0)
	if not tdata["targets"].is_empty():
		var t0d: Dictionary = tdata["targets"][0]
		first_target = Vector3(float(t0d["x"]), float(t0d["y"]), float(t0d["z"]))
	var bake_wait_s := -1.0
	for _w in range(600):
		var probe: Vector3 = NavigationServer3D.map_get_closest_point(terrain_map, first_target)
		if probe.distance_to(first_target) < 25.0 and probe.length() > 1.0:
			break
		await process_frame
	bake_wait_s = (Time.get_ticks_msec() - t0) / 1000.0

	var xy_tol := float(tdata.get("xy_tolerance_m", 2.5))
	var y_tol := float(tdata.get("height_tolerance_m", 0.7))
	var by_name := {}
	var target_results := []
	var all_ok := true
	for t in tdata["targets"]:
		var want := Vector3(float(t["x"]), float(t["y"]), float(t["z"]))
		var closest: Vector3 = NavigationServer3D.map_get_closest_point(terrain_map, want)
		var dxy := Vector2(closest.x - want.x, closest.z - want.z).length()
		var dy := absf(closest.y - want.y)
		var ok := dxy <= xy_tol and dy <= y_tol
		by_name[t["name"]] = closest
		if not ok and bool(t.get("required", true)):
			all_ok = false
		target_results.append({
			"name": t["name"], "kind": t["kind"], "want": [want.x, want.y, want.z],
			"nav_point": [closest.x, closest.y, closest.z],
			"dxy_m": round(dxy * 1000.0) / 1000.0, "dy_m": round(dy * 1000.0) / 1000.0,
			"required": bool(t.get("required", true)), "pass": ok,
		})
	var path_results := []
	for pair in tdata["paths"]:
		var from_v: Vector3 = by_name.get(pair[0], Vector3.INF)
		var to_v: Vector3 = by_name.get(pair[1], Vector3.INF)
		var ok := false
		var plen := 0.0
		var end_dxy := -1.0
		var end_dy := -1.0
		var traj_min_y := 0.0
		var traj_max_y := 0.0
		if from_v != Vector3.INF and to_v != Vector3.INF:
			var path := NavigationServer3D.map_get_path(terrain_map, from_v, to_v, true)
			plen = _path_len(path)
			if path.size() > 0:
				traj_min_y = path[0].y
				traj_max_y = path[0].y
				for pv in path:
					traj_min_y = minf(traj_min_y, pv.y)
					traj_max_y = maxf(traj_max_y, pv.y)
				var last: Vector3 = path[path.size() - 1]
				end_dxy = Vector2(last.x - to_v.x, last.z - to_v.z).length()
				end_dy = absf(last.y - to_v.y)
				# 端点必须真的到达目标高度平面（不能吸附到山脚/地下后算通过）
				ok = end_dxy <= maxf(xy_tol, 1.5) and end_dy <= y_tol
				# Codex F2 上下坡轨迹断言：坡底→坡顶必须真实爬升 >=2.0m（3m 高差），
				# 仅端点高度达标不够，防止贴着崖脚绕行的假连通轨迹冒充爬坡。
				var is_ramp_up: bool = String(pair[0]).ends_with("_bottom") \
					and String(pair[1]).ends_with("_top")
				if is_ramp_up and (traj_max_y - traj_min_y) < 2.0:
					ok = false
		if not ok:
			all_ok = false
		path_results.append({
			"from": pair[0], "to": pair[1], "connected": ok,
			"path_len_m": round(plen * 100.0) / 100.0,
			"end_dxy_m": round(end_dxy * 1000.0) / 1000.0,
			"end_dy_m": round(end_dy * 1000.0) / 1000.0,
			"climb_m": round((traj_max_y - traj_min_y) * 1000.0) / 1000.0,
		})
	# Codex F2 禁止穿越：水域内部与崖面中段不得有可走导航（最近点 3D 距离 >= clearance）。
	var forbidden_results := []
	var forbid = tdata.get("forbidden", {})
	if forbid is Dictionary:
		for kind in ["water", "cliff"]:
			var arr = forbid.get(kind, [])
			if not (arr is Array):
				continue
			for pr in arr:
				var p := Vector3(float(pr["x"]), float(pr["y"]), float(pr["z"]))
				var cp: Vector3 = NavigationServer3D.map_get_closest_point(terrain_map, p)
				var d3: float = cp.distance_to(p)
				var clr: float = float(pr.get("clearance_m", 1.5))
				var okf: bool = d3 >= clr
				if not okf:
					all_ok = false
				forbidden_results.append({
					"kind": kind, "name": String(pr.get("name", "")),
					"probe": [p.x, p.y, p.z], "nav_point": [cp.x, cp.y, cp.z],
					"dist3d_m": round(d3 * 1000.0) / 1000.0,
					"clearance_m": clr, "pass": okf,
				})
	var forbid_fail := 0
	for fr in forbidden_results:
		if not fr["pass"]:
			forbid_fail += 1
	_write(out_path, map_path, all_ok, {
		"bake_wait_s": round(bake_wait_s * 100.0) / 100.0,
		"xy_tolerance_m": xy_tol, "height_tolerance_m": y_tol,
		"targets_checked": target_results.size(),
		"paths_checked": path_results.size(),
		"forbidden_checked": forbidden_results.size(),
		"forbidden_failed": forbid_fail,
		"targets": target_results, "paths": path_results,
		"forbidden": forbidden_results,
	}, [], bake_wait_s)
	print("nav_check: all=%s targets=%d paths=%d forbidden=%d(fail %d) bake=%.2fs" % [
		all_ok, target_results.size(), path_results.size(),
		forbidden_results.size(), forbid_fail, bake_wait_s])
	# 调试：导航网格覆盖采样 + 多边形数，定位“地面/台地顶缺失”类问题。
	var region_node = match_node.find_child("NavigationRegion3D", true, true)
	if region_node != null:
		var nm: NavigationMesh = region_node.navigation_mesh
		print("DEBUG navmesh polygons: ", nm.get_polygon_count())
	var covered := 0
	var total := 0
	var sample_bad := []
	for gx in range(16, 256, 32):
		for gz in range(16, 256, 32):
			# 用高度场之外的高度探测：取导航网格最近点，若水平距离小则覆盖
			var q := Vector3(float(gx), 0.6, float(gz))
			var cp: Vector3 = NavigationServer3D.map_get_closest_point(terrain_map, q)
			total += 1
			if Vector2(cp.x - q.x, cp.z - q.z).length() < 3.0:
				covered += 1
			elif sample_bad.size() < 8:
				sample_bad.append([gx, gz, cp.x, cp.y, cp.z])
	print("DEBUG ground-level coverage: ", covered, "/", total, " bad: ", sample_bad)
	quit(0 if all_ok else 1)


func _write(out_path: String, map_path: String, all_ok: bool, detail: Dictionary,
		_extra: Array, bake_wait_s: float) -> void:
	var report := {"map": map_path, "all_pass": all_ok, "bake_wait_s": bake_wait_s}
	report.merge(detail, true)
	var f := FileAccess.open(out_path, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(report, "  "))
		f.close()


func _path_len(p: PackedVector3Array) -> float:
	var t := 0.0
	for i in range(1, p.size()):
		t += p[i - 1].distance_to(p[i])
	return t
