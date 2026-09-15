extends SceneTree
## AI_RTS 冒烟：4 名 SimpleClairvoyantAI 对局 5 分钟（非联网、无 Human、FULL 可见）。
## 30 s / 5 min 各抓一张正交俯视帧；记录 4 家 resource_a 与单位位置变化（卡死检查）。
## 用法：Godot_mono.exe --rendering-driver opengl3 --resolution 1280x800 --path <AI_RTS工程根> \
##   --script smoke_test.gd -- --map=res://source/match/maps/generated/seed_44.tscn \
##   --out_dir=<abs dir> --minutes=5

const COLORS := [Color("66b1ff"), Color("ff5c73"), Color("a5ff99"), Color("ed85ff")]

var _errors := 0
# Codex F2：采集用真实入账事件（EconomyRuntime.BalanceChanged, reason=WorkerDelivery）
# 累计，而非“5min 余额 > 30s 余额”——建造/生产消耗会掩盖真实采集。
var _collect_income := {}      # playerId -> {a, b, events}
var _prev_balance := {}        # playerId -> {a, b}（上一笔权威余额，用于求 delta）
var _player_id_to_name := {}   # playerId -> Players 子节点名


## EconomyRuntime.BalanceChanged 回调：按 reason 累计真实采集入账（与支出无关）。
func _on_balance_changed(player_id: String, _tx: String, reason: String,
		ra: int, rb: int, _version) -> void:
	var prev = _prev_balance.get(player_id, {"a": ra, "b": rb})
	var da := ra - int(prev["a"])
	var db := rb - int(prev["b"])
	_prev_balance[player_id] = {"a": ra, "b": rb}
	if reason == "WorkerDelivery":
		var inc = _collect_income.get(player_id, {"a": 0, "b": 0, "events": 0})
		inc["a"] = int(inc["a"]) + maxi(da, 0)
		inc["b"] = int(inc["b"]) + maxi(db, 0)
		inc["events"] = int(inc["events"]) + 1
		_collect_income[player_id] = inc


## 单位移动意图（Codex F2）：卡死必须“有移动意图却无进展”，空闲不算卡死。
func _unit_move_intent(u: Node) -> Dictionary:
	var mv = u.find_child("Movement") if u.has_method("find_child") else null
	if mv == null:
		return {"has_intent": false, "nav_finished": true}
	var tp = mv.get("target_position")
	var has_target: bool = tp != null and tp != Vector3.INF
	var finished := true
	if mv.has_method("is_navigation_finished"):
		finished = bool(mv.is_navigation_finished())
	return {"has_intent": bool(has_target and not finished), "nav_finished": finished}


func _init() -> void:
	_run()


func _snapshot_units(match_node: Node) -> Dictionary:
	var snap := {}
	for u in get_nodes_in_group("units"):
		if match_node.is_ancestor_of(u) and u is Node3D:
			snap[u.get_instance_id()] = {
				"name": String(u.name),
				"pos": (u as Node3D).global_position,
				"player": str(u.get("player")) if u.get("player") != null else "?",
				"intent": _unit_move_intent(u),
			}
	return snap


func _run() -> void:
	await process_frame
	var map_path := ""
	var out_dir := "."
	var minutes := 5.0
	var size := 256.0
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--map="):
			map_path = a.substr(6)
		elif a.begins_with("--out_dir="):
			out_dir = a.substr(10)
		elif a.begins_with("--minutes="):
			minutes = float(a.substr(10))
		elif a.begins_with("--size="):
			size = float(a.substr(7))
	var map = load(map_path).instantiate()
	var match_node = load("res://source/match/Match.tscn").instantiate()
	var settings = load("res://source/data-model/MatchSettings.gd").new()
	var ps_script = load("res://source/data-model/PlayerSettings.gd")
	var players: Array[Resource] = []
	for i in range(4):
		var p = ps_script.new()
		p.controller = 2  # Constants.PlayerType.SIMPLE_CLAIRVOYANT_AI
		p.color = COLORS[i]
		players.append(p)
	settings.players = players
	settings.visibility = 2  # FULL
	settings.local_player_index = -1
	match_node.settings = settings
	match_node.map = map
	root.add_child(match_node)
	# 冒烟期间屏蔽真实鼠标/键盘输入：AI_RTS 的框选代码调用本版 Godot 不存在的
	# Camera3D API（get_ray_intersection_with_plane / set_position_safely），
	# 桌面偶发点击会触发并中断对局——属游戏既有问题，与地图无关
	root.gui_disable_input = true
	# 窗口移出屏幕 + 去边框：避免干扰桌面使用，也避免窗口被误关导致对局中断
	root.borderless = true
	root.position = Vector2i(3600, 80)
	for _i in range(12):
		await process_frame
		await physics_frame

	# Codex F2：接入 EconomyRuntime.BalanceChanged 累计真实采集入账（WorkerDelivery）。
	# playerId → 玩家名映射取自 Player._resource_account_id（setup_resource_account 写入）。
	var econ = match_node.get_node_or_null("EconomyRuntime")
	var players_node = match_node.get_node_or_null("Players")
	if econ != null and players_node != null:
		for p in players_node.get_children():
			var pid = p.get("_resource_account_id")
			if pid != null and String(pid) != "":
				_player_id_to_name[String(pid)] = String(p.name)
				_prev_balance[String(pid)] = {
					"a": int(p.get("resource_a")) if p.get("resource_a") != null else 0,
					"b": int(p.get("resource_b")) if p.get("resource_b") != null else 0,
				}
				_collect_income[String(pid)] = {"a": 0, "b": 0, "events": 0}
		if not econ.is_connected("BalanceChanged", _on_balance_changed):
			econ.connect("BalanceChanged", _on_balance_changed)

	# navmesh 连通检查：用 Match 内 TerrainNavigation 已烘焙并 force_update 过的
	# navigation map（--script 模式下手动 bake 的 map 不被 NavigationServer 同步）
	var nav_connected := {}
	var nav_all := true
	var _report_path: String = out_dir.path_join("smoke_report.json")
	var nav = match_node.get("navigation")
	var bake_wait_s := -1.0
	if nav != null:
		var terrain_map: RID = nav.get_navigation_map_rid_by_domain(1)  # TERRAIN
		# 轮询等待 TerrainNavigation 烘焙完成（closest 点离开原点即视为就绪）；
		# 计时 = Match 上下文内真实烘焙耗时（parse+bake+sync）
		var bake_t0 := Time.get_ticks_msec()
		for _w in range(600):
			var probe: Vector3 = NavigationServer3D.map_get_closest_point(
				terrain_map, Vector3(size / 2.0, 0.2, size / 2.0))
			if probe.length() > 1.0:
				break
			await process_frame
		bake_wait_s = (Time.get_ticks_msec() - bake_t0) / 1000.0
		var spawns_v: Array[Vector3] = []
		var sp: Node = map.find_child("SpawnPoints", true, false)
		if sp != null:
			for c in sp.get_children():
				spawns_v.append((c as Node3D).global_transform.origin + Vector3(0, 0.2, 0))
		# 验收目标（接手提示词 §8：4 出生点两两 + 到扩张连通；无中央战场下 center 不是
		# 玩法关键点，且 G2 中合法掩体可占中心格——center 路线仅作 informative 报告）。
		# 2026-09-06 真实高程版：优先读 --targets=nav_targets.json（出生/扩张/台地顶/
		# 坡口上下端/桥头/资源的实际地表高度），防止投影到错误平面后假连通；
		# 无 --targets 时回退旧行为（扩张锚点 Y=0.2，旧平地图兼容）。
		var targets := {}
		var key_targets := {}
		var kinds := {}
		var nav_targets_loaded := false
		for a in OS.get_cmdline_user_args():
			if a.begins_with("--targets="):
				var tf := FileAccess.open(a.substr(10), FileAccess.READ)
				if tf != null:
					var tdata = JSON.parse_string(tf.get_as_text())
					tf.close()
					if tdata is Dictionary and tdata.has("targets"):
						nav_targets_loaded = true
						for t in tdata["targets"]:
							var v := Vector3(float(t["x"]), float(t["y"]), float(t["z"]))
							targets[String(t["name"])] = v
							key_targets[String(t["name"])] = bool(t.get("required", true))
							kinds[String(t["name"])] = String(t.get("kind", ""))
		if not nav_targets_loaded:
			for k in range(spawns_v.size()):
				targets["P%d" % k] = spawns_v[k]
				key_targets["P%d" % k] = true
			var center_v := Vector3(size / 2.0, 0.2, size / 2.0)
			targets["center"] = center_v
			for a in OS.get_cmdline_user_args():
				if a.begins_with("--keypoints="):
					var kf := FileAccess.open(a.substr(12), FileAccess.READ)
					if kf != null:
						var parsed = JSON.parse_string(kf.get_as_text())
						if parsed is Dictionary and parsed.has("expansion_anchors"):
							var anchors: Array = parsed["expansion_anchors"]
							for k in range(min(anchors.size(), spawns_v.size())):
								var av: Array = anchors[k]
								targets["exp_P%d" % k] = Vector3(float(av[0]), 0.2, float(av[1]))
								key_targets["exp_P%d" % k] = true
		# 两两连通只验出生/扩张（对局相关）；坡口/桥头/资源的定向连通由 nav_check 负责，
		# 避免目标过多时路径查询爆炸（69 目标全两两 ≈4700 次，过慢）。
		var pairwise := []
		for nm in targets.keys():
			if not nav_targets_loaded or kinds.get(nm, "") in ["spawn", "expansion"]:
				pairwise.append(nm)
		for a_i in range(pairwise.size()):
			var name_a: String = pairwise[a_i]
			for b_i in range(pairwise.size()):
				if a_i == b_i:
					continue
				var name_b: String = pairwise[b_i]
				# 旧行为只验出生/扩张两两；目标多时（真实高程版含坡口/桥头/资源）
				# 保持两两全验——目标数 ~40，路径查询 ~1600 次，秒级开销可接受。
				var from_v: Vector3 = NavigationServer3D.map_get_closest_point(
					terrain_map, targets[name_a])
				var to_v: Vector3 = NavigationServer3D.map_get_closest_point(
					terrain_map, targets[name_b])
				var path := NavigationServer3D.map_get_path(terrain_map, from_v, to_v, true)
				var ok := path.size() > 0 and path[path.size() - 1].distance_to(to_v) < 1.5
				var key := "%s->%s" % [name_a, name_b]
				nav_connected[key] = {"connected": ok, "path_len": _path_len(path)}
				# 只有验收目标对的失败才置 nav_all=false；center 仅 informative
				if not ok and key_targets.has(name_a) and key_targets.has(name_b) \
						and bool(key_targets[name_a]) and bool(key_targets[name_b]):
					nav_all = false
	print("navmesh_connectivity: all=%s" % nav_all)
	# 增量落盘：先写导航验收数据（之后每拍重写；对局若被外部中断也不丢数据）
	var f_inc := FileAccess.open(_report_path, FileAccess.WRITE)
	f_inc.store_string(JSON.stringify({
		"map": map_path, "navmesh_bake_wait_s": bake_wait_s,
		"navmesh_all_connected": nav_all, "navmesh_results": nav_connected,
	}, "  "))
	f_inc.close()

	var cam := Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.size = size
	cam.position = Vector3(size / 2.0, 60.0, size / 2.0)
	cam.rotation_degrees = Vector3(-90, 0, 0)
	cam.far = size * 2.0
	root.add_child(cam)
	cam.current = true

	var res_t0 := {}
	var res_t30 := {}
	var res_t5 := {}
	var snap_t4 := {}
	var snap_t5 := {}
	var res_series := {}
	var t0_ms := Time.get_ticks_msec()
	var t := 0.0
	var shot30 := false
	var snap4 := false
	while t < minutes * 60.0:
		await process_frame
		t = (Time.get_ticks_msec() - t0_ms) / 1000.0  # 墙钟计时（Window 的 process delta 恒 0）
		if int(t) != int(t - 1.0) and int(t) % 15 == 0:
			_beat(out_dir, "running t=%.0f units=%d" % [t, get_nodes_in_group("units").size()])
			res_series["t%d" % int(t)] = _resources(match_node)
			var f_beat := FileAccess.open(_report_path, FileAccess.WRITE)
			f_beat.store_string(JSON.stringify({
				"map": map_path, "navmesh_bake_wait_s": bake_wait_s,
				"navmesh_all_connected": nav_all, "navmesh_results": nav_connected,
				"resource_series": res_series,
			}, "  "))
			f_beat.close()
		if not shot30 and t >= 30.0:
			shot30 = true
			_beat(out_dir, "shot30 begin")
			await RenderingServer.frame_post_draw
			root.get_viewport().get_texture().get_image().save_png(
				out_dir.path_join("smoke_30s.png"))
			_beat(out_dir, "shot30 saved")
			res_t30 = _resources(match_node)
		if not snap4 and t >= (minutes - 1.0) * 60.0:
			snap4 = true
			snap_t4 = _snapshot_units(match_node)
	res_t5 = _resources(match_node)
	_beat(out_dir, "shot5 begin")
	await RenderingServer.frame_post_draw
	root.get_viewport().get_texture().get_image().save_png(out_dir.path_join("smoke_5min.png"))
	_beat(out_dir, "snap5 begin")
	snap_t5 = _snapshot_units(match_node)
	_beat(out_dir, "snap5 done")

	# 卡死检查（Codex F2）：仅“有移动意图却无净进展”的非建筑单位算卡死；
	# 空闲（无移动意图）单位正常静止，不计入。轨迹用最后一分钟净位移判定。
	var stuck := []
	var movers := 0
	var intent_movers := 0
	for id in snap_t5:
		if not snap_t4.has(id):
			continue
		var nm: String = snap_t5[id]["name"]
		var is_structure: bool = "CommandCenter" in nm or "Factory" in nm \
			or "Turret" in nm or "Barracks" in nm
		if is_structure:
			continue
		movers += 1
		var net_move: float = snap_t4[id]["pos"].distance_to(snap_t5[id]["pos"])
		var intent_t4: bool = bool(snap_t4[id].get("intent", {}).get("has_intent", false))
		var intent_t5: bool = bool(snap_t5[id].get("intent", {}).get("has_intent", false))
		if intent_t4 or intent_t5:
			intent_movers += 1
		# 整分钟持续有移动意图却几乎无净位移（<0.5m）= 真卡死
		if intent_t4 and intent_t5 and net_move < 0.5:
			stuck.append({"name": nm, "player": snap_t5[id].get("player", "?"),
				"net_move_m": round(net_move * 1000.0) / 1000.0})

	# 采集（Codex F2）：真实 WorkerDelivery 累计入账，逐玩家；mining = 入账 > 0。
	var collection_by_name := {}
	for pid in _collect_income:
		collection_by_name[_player_id_to_name.get(pid, pid)] = _collect_income[pid]
	var mining_players := 0
	var n_players := _collect_income.size()
	for pid in _collect_income:
		var inc = _collect_income[pid]
		if int(inc["a"]) + int(inc["b"]) > 0:
			mining_players += 1

	# 显式验收断言：pass / fail / not_run 分别记录，不硬编码。
	var match_ran: bool = snap_t5.size() > 0 and t >= minutes * 60.0 - 5.0
	var assertions := {
		"match_ran_full_duration": _status(true, match_ran,
			"units=%d elapsed=%.0fs/%.0fs" % [snap_t5.size(), t, minutes * 60.0]),
		"navmesh_all_connected": _status(nav_connected.size() > 0, nav_all,
			"%d 条路径检查" % nav_connected.size()),
		"all_players_collected": _status(n_players > 0,
			mining_players >= n_players and n_players > 0,
			"采集入账玩家 %d/%d" % [mining_players, n_players]),
		"no_intent_stuck_units": _status(match_ran, stuck.size() == 0,
			"%d 个单位有移动意图却无进展" % stuck.size()),
	}

	var report := {
		"map": map_path,
		"minutes": minutes,
		"elapsed_s": round(t * 10.0) / 10.0,
		"navmesh_bake_wait_s": bake_wait_s,
		"navmesh_all_connected": nav_all,
		"navmesh_results": nav_connected,
		"resource_a_t30": res_t30,
		"resource_a_t5": res_t5,
		"resource_series": res_series,
		"collection_income": collection_by_name,
		"collection_events_total": _total_events(),
		"mining_players": mining_players,
		"players_tracked": n_players,
		"units_t5": snap_t5.size(),
		"movers_checked": movers,
		"intent_movers": intent_movers,
		"stuck_units_last_minute": stuck,
		"stuck_count": stuck.size(),
		"assertions": assertions,
	}
	var f := FileAccess.open(_report_path, FileAccess.WRITE)
	f.store_string(JSON.stringify(report, "  "))
	f.close()
	print("smoke: mining_players=%d/%d (WorkerDelivery income) units=%d intent_stuck=%d nav_all=%s" % [
		mining_players, n_players, snap_t5.size(), stuck.size(), nav_all])
	quit(0)


## not_run：本轮没有可判定数据（如对局未生成单位/未接入经济）；否则 pass/fail。
func _status(tested: bool, passed: bool, detail: String) -> Dictionary:
	if not tested:
		return {"status": "not_run", "detail": detail}
	return {"status": "pass" if passed else "fail", "detail": detail}


func _total_events() -> int:
	var n := 0
	for pid in _collect_income:
		n += int(_collect_income[pid]["events"])
	return n


func _beat(out_dir: String, phase: String) -> void:
	var f := FileAccess.open(out_dir.path_join("smoke_progress.txt"), FileAccess.WRITE)
	if f != null:
		f.store_string("%s | %s" % [Time.get_datetime_string_from_system(), phase])
		f.close()


func _path_len(p: PackedVector3Array) -> float:
	var t := 0.0
	for i in range(1, p.size()):
		t += p[i - 1].distance_to(p[i])
	return t


func _resources(match_node: Node) -> Dictionary:
	var out := {}
	var players = match_node.get_node_or_null("Players")
	if players == null:
		return out
	for p in players.get_children():
		out[String(p.name)] = {
			"a": float(p.get("resource_a")) if p.get("resource_a") != null else -1.0,
			"b": float(p.get("resource_b")) if p.get("resource_b") != null else -1.0,
		}
	return out
