extends Node

## 容量与线程画像探针。不改 project.godot，不关避障/碰撞，不降模拟频率。
## 线程开关必须由进程启动前的 override.cfg 固定；这里只读取实际值。

const ROSTER := ["Tank", "APC", "HeavyTank", "Infantry", "Sniper"]
const MAP_LIMIT := 200.0


class SpanMark extends Node:
	var tag := ""
	var _script = null
	var _buckets = null

	func _ready() -> void:
		_script = load("res://source/match/units/traits/Movement.gd")
		_buckets = load("res://source/match/PerfBuckets.gd")

	func _physics_process(_delta: float) -> void:
		if _script == null:
			return
		if tag == "phys_first" or tag == "phys_last":
			_script.diag_bookend(tag)
		else:
			_script.diag_mark(tag)
			if tag == "match_out":
				_script.diag_bookend("phys_last")
				if _buckets != null and _buckets.enabled:
					_buckets.on_match_out()


class ProcEnd extends Node:
	var _buckets = null

	func _ready() -> void:
		_buckets = load("res://source/match/PerfBuckets.gd")
		var timer := Timer.new()
		timer.name = "TperfAfterTimers"
		timer.wait_time = 0.001
		timer.autostart = true
		add_child(timer)
		timer.timeout.connect(func() -> void:
			if _buckets != null and _buckets.enabled:
				_buckets.on_after_timers()
		)

	func _process(_delta: float) -> void:
		if _buckets != null and _buckets.enabled:
			_buckets.on_process_end()
			call_deferred("_after_messages")

	func _after_messages() -> void:
		if _buckets != null and _buckets.enabled:
			_buckets.on_after_messages()

var _match: Node
var _count := 100
var _mode := "spread"
var _seconds := 12.0
var _unlock := true
var _out := ""


func _enter_tree() -> void:
	if OS.get_environment("AIRTS_MOV_DIAG") == "":
		return
	var buckets = load("res://source/match/PerfBuckets.gd")
	var tree := get_tree()
	tree.physics_frame.connect(Callable(buckets, "on_physics_frame"))
	tree.process_frame.connect(Callable(buckets, "on_process_frame"))
	RenderingServer.frame_pre_draw.connect(Callable(buckets, "on_pre_draw"))
	RenderingServer.frame_post_draw.connect(Callable(buckets, "on_post_draw"))


func _process(_delta: float) -> void:
	if get_tree().paused:
		get_tree().paused = false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_count = maxi(1, int(OS.get_environment("AIRTS_TPERF_COUNT") if OS.get_environment("AIRTS_TPERF_COUNT") != "" else "100"))
	_mode = OS.get_environment("AIRTS_TPERF_MODE") if OS.get_environment("AIRTS_TPERF_MODE") != "" else "spread"
	_seconds = float(OS.get_environment("AIRTS_TPERF_SECONDS") if OS.get_environment("AIRTS_TPERF_SECONDS") != "" else "12")
	_unlock = OS.get_environment("AIRTS_TPERF_UNLOCK") != "0"
	_out = OS.get_environment("AIRTS_TPERF_OUT")
	get_tree().create_timer(150.0).timeout.connect(func() -> void:
		print("[TPERF] TIMEOUT")
		get_tree().quit(3)
	)
	_print_thread_config("boot")
	print("[TPERF] MAIN_TID=%d" % OS.get_thread_caller_id())
	print("[TPERF] version=%s processors=%d physics_hz=%d" % [
		Engine.get_version_info().get("string", ""),
		OS.get_processor_count(),
		Engine.physics_ticks_per_second,
	])
	await _run()


func _print_thread_config(tag: String) -> void:
	var keys := [
		"navigation/avoidance/thread_model/avoidance_use_multiple_threads",
		"navigation/avoidance/thread_model/avoidance_use_high_priority_threads",
		"physics/3d/run_on_separate_thread",
	]
	for key in keys:
		print("[TPERF] cfg %s %s exists=%s value=%s" % [
			tag, key, str(ProjectSettings.has_setting(key)), str(ProjectSettings.get_setting(key, "<unset>")),
		])


func _run() -> void:
	var settings = load("res://source/data-model/MatchSettings.gd").new()
	var human = load("res://source/data-model/PlayerSettings.gd").new()
	human.controller = Constants.PlayerType.HUMAN
	human.color = Constants.Player.COLORS[0]
	settings.players.append(human)
	settings.visible_player = 0
	_match = load("res://source/match/Match.tscn").instantiate()
	_match.settings = settings
	_match.map = load("res://source/match/maps/PlainAndSimple.tscn").instantiate()
	add_child(_match)
	get_tree().current_scene = _match
	_install_span_marks()
	await _watch_phase("boot", 6.0)
	_apply_presentation()
	var player: Node = _match.get_local_player()
	_spawn_buildings(player)
	var spawned := _spawn_army(player)
	await _watch_phase("after_spawn", 3.0)
	for _i in range(30):
		await get_tree().physics_frame
	var movers := _collect_movers()
	var unique := _unique_xz(movers)
	var avoidance_on := 0
	for movement in movers:
		if bool(movement.avoidance_enabled):
			avoidance_on += 1
	print("[TPERF] spawned_requests=%d movers=%d unique_xz=%d avoidance_on=%d mode=%s" % [
		spawned, movers.size(), unique, avoidance_on, _mode,
	])
	_print_obstacles()
	print("[TPERF] YAW before_move %s" % _air_yaw_line())
	if movers.is_empty():
		print("[TPERF] FAIL no movers")
		get_tree().quit(1)
		return
	_issue_moves(movers, false)
	await _watch_phase("after_first_move", 2.0)
	print("[TPERF] YAW after_first_move %s" % _air_yaw_line())
	var before := _positions(movers)
	var movement_script = load("res://source/match/units/traits/Movement.gd")
	movement_script.agg_reset()
	var buckets = load("res://source/match/PerfBuckets.gd")
	buckets.reset()
	_print_scene_counts()
	_apply_exp()
	RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), true)
	var phys0 := Engine.get_physics_frames()
	var wall0 := Time.get_ticks_usec()
	print("[TPERF] SAMPLE_START usec=%d" % wall0)
	var frames: Array[float] = []
	var nav_ms: Array[float] = []
	var phys_ms: Array[float] = []
	var proc_ms: Array[float] = []
	var render_cpu: Array[float] = []
	var render_gpu: Array[float] = []
	var tick_deltas: Array[int] = []
	var last := wall0
	var last_phys := phys0
	var flip := false
	var next_flip := wall0 + 4000000
	var commands := 1
	var early := false
	var catastrophic := 0
	while float(Time.get_ticks_usec() - wall0) / 1000000.0 < _seconds:
		await get_tree().process_frame
		var now := Time.get_ticks_usec()
		var dt := float(now - last) / 1000.0
		last = now
		frames.append(dt)
		if dt > 2000.0:
			catastrophic += 1
		var phys_now := Engine.get_physics_frames()
		tick_deltas.append(phys_now - last_phys)
		last_phys = phys_now
		nav_ms.append(Performance.get_monitor(Performance.TIME_NAVIGATION_PROCESS) * 1000.0)
		phys_ms.append(Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0)
		proc_ms.append(Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0)
		var viewport_rid := get_viewport().get_viewport_rid()
		render_cpu.append(RenderingServer.viewport_get_measured_render_time_cpu(viewport_rid))
		render_gpu.append(RenderingServer.viewport_get_measured_render_time_gpu(viewport_rid))
		if now >= next_flip:
			flip = not flip
			_issue_moves(movers, flip)
			commands += 1
			next_flip = now + 4000000
		if catastrophic >= 2:
			early = true
			print("[TPERF] EARLY_STOP catastrophic_frames=%d last_ms=%.1f" % [catastrophic, dt])
			break
	print("[TPERF] YAW sample_end %s" % _air_yaw_line())
	var wall1 := Time.get_ticks_usec()
	print("[TPERF] SAMPLE_END usec=%d" % wall1)
	await get_tree().physics_frame
	var after := _positions(movers)
	var agg: String = movement_script.agg_line()
	print("[TPERF] AGG %s" % agg)
	var grid := _match.find_child("TargetAcquisitionGrid", true, false) if _match != null else null
	if grid != null and grid.get("stats") is Dictionary:
		var grid_stats: Dictionary = grid.stats
		print("[TPERF] GRID index_maintain_us=%s query_calls=%s cell_moves=%s registered=%s" % [
			grid_stats["index_maintain_us"], grid_stats["query_calls"],
			grid_stats["cell_moves"], grid_stats["registered"],
		])
	var bucket_line: String = buckets.line()
	print("[TPERF] BUCKETS %s" % bucket_line)
	var wall_s := float(wall1 - wall0) / 1000000.0
	var phys_steps := Engine.get_physics_frames() - phys0
	var moved := _motion(before, after)
	var summary := {
		"mode": _mode,
		"requested": _count,
		"movers": movers.size(),
		"unique_xz": unique,
		"commands": commands,
		"sample_s": wall_s,
		"frames": frames.size(),
		"valid": frames.size() >= 20 and not early,
		"early_stop": early,
		"catastrophic_frames": catastrophic,
		"fps": float(frames.size()) / maxf(wall_s, 0.001),
		"frame_p50_ms": _pct(frames, 0.50),
		"frame_p95_ms": _pct(frames, 0.95),
		"frame_p99_ms": _pct(frames, 0.99),
		"frame_max_ms": _max(frames),
		"hitch_gt_33ms": _count_over(frames, 33.3),
		"hitch_gt_100ms": _count_over(frames, 100.0),
		"hitch_gt_500ms": _count_over(frames, 500.0),
		"physics_steps": phys_steps,
		"physics_hz_actual": float(phys_steps) / maxf(wall_s, 0.001),
		"ticks_per_frame_p50": _pct_i(tick_deltas, 0.50),
		"monitor_nav_p50_ms": _pct(nav_ms, 0.50),
		"monitor_physics_p50_ms": _pct(phys_ms, 0.50),
		"monitor_process_p50_ms": _pct(proc_ms, 0.50),
		"render_cpu_p50_ms": _pct(render_cpu, 0.50),
		"render_gpu_p50_ms": _pct(render_gpu, 0.50),
		"render_note": "viewport render time is already milliseconds; monitors are seconds*1000 and overlap, do not add",
		"moved_gt_0_5m": int(moved["moved"]),
		"stuck_lt_0_15m": int(moved["stuck"]),
		"displacement_sum_m": float(moved["sum"]),
		"agg": agg,
		"buckets": bucket_line,
		"presentation": _presentation(),
		"main_tid": OS.get_thread_caller_id(),
		"avoidance_multiple_threads": ProjectSettings.get_setting(
			"navigation/avoidance/thread_model/avoidance_use_multiple_threads", "<unset>"),
		"avoidance_high_priority": ProjectSettings.get_setting(
			"navigation/avoidance/thread_model/avoidance_use_high_priority_threads", "<unset>"),
		"physics_separate_thread": ProjectSettings.get_setting("physics/3d/run_on_separate_thread", "<unset>"),
		"processors": OS.get_processor_count(),
		"physics_ticks_setting": Engine.physics_ticks_per_second,
		"max_fps": Engine.max_fps,
		"vsync": int(DisplayServer.window_get_vsync_mode()),
		"sample_avoidance_enabled": bool(movers[0].avoidance_enabled),
		"avoidance_enabled_count": avoidance_on,
	}
	print("[TPERF_JSON] " + JSON.stringify(summary))
	_write_outputs(summary, frames)
	await _shots()
	print("[TPERF] DONE")
	get_tree().quit(2 if early else 0)


func _apply_presentation() -> void:
	if not _unlock:
		print("[TPERF] presentation locked max_fps=%d vsync=%d" % [
			Engine.max_fps, int(DisplayServer.window_get_vsync_mode())])
		return
	Engine.max_fps = 0
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	var governor := get_node_or_null("/root/PerformanceGovernor")
	if governor != null:
		governor.enabled = false
	print("[TPERF] presentation unlocked max_fps=%d vsync=%d governor_enabled=%s" % [
		Engine.max_fps,
		int(DisplayServer.window_get_vsync_mode()),
		str(governor.enabled) if governor != null else "missing",
	])


func _presentation() -> Dictionary:
	var env_node := _match.get_node_or_null("WorldEnvironment") as WorldEnvironment
	var environment: Environment = env_node.environment if env_node != null else null
	var sun := _match.get_node_or_null("DirectionalLight3D") as DirectionalLight3D
	var viewport := get_viewport()
	return {
		"max_fps": Engine.max_fps,
		"vsync": int(DisplayServer.window_get_vsync_mode()),
		"physics_hz": Engine.physics_ticks_per_second,
		"fog_enabled": environment.fog_enabled if environment != null else "unavailable",
		"volumetric_fog": environment.volumetric_fog_enabled if environment != null else "unavailable",
		"shadows": sun.shadow_enabled if sun != null else "unavailable",
		"msaa_3d": int(viewport.msaa_3d),
		"scaling_3d_scale": viewport.scaling_3d_scale,
		"avoidance_still_on": true,
	}


func _apply_exp() -> void:
	var exp := OS.get_environment("AIRTS_TPERF_EXP")
	if exp == "":
		return
	var hidden := 0
	var paused := 0
	var roots: Array = get_tree().get_nodes_in_group("units")
	if exp == "strip":
		roots = [_match]
	for root in roots:
		if not is_instance_valid(root):
			continue
		if exp == "strip" or exp == "hide_mesh" or exp == "both":
			for node in root.find_children("*", "MeshInstance3D", true, false):
				(node as MeshInstance3D).visible = false
				hidden += 1
		if exp == "strip" or exp == "pause_anim" or exp == "both":
			for node in root.find_children("*", "AnimationPlayer", true, false):
				(node as AnimationPlayer).active = false
				paused += 1
	if exp == "noshadow" or exp == "strip":
		var sun := _match.get_node_or_null("DirectionalLight3D") as DirectionalLight3D
		if sun != null:
			sun.shadow_enabled = false
	if exp == "nofog" or exp == "strip":
		var env_node := _match.get_node_or_null("WorldEnvironment") as WorldEnvironment
		if env_node != null and env_node.environment != null:
			env_node.environment.volumetric_fog_enabled = false
	if exp == "nav_off":
		NavigationServer3D.set_active(false)
	if exp == "interp_off":
		get_tree().root.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
		var muted := 0
		for node in _match.find_children("*", "Node3D", true, false):
			(node as Node3D).physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
			muted += 1
		print("[TPERF] EXP interp_off nodes=%d" % muted)
	if exp == "hide_units":
		var hidden_units := 0
		for unit in get_tree().get_nodes_in_group("units"):
			if unit is Node3D:
				(unit as Node3D).visible = false
				hidden_units += 1
		print("[TPERF] EXP hide_units n=%d" % hidden_units)
		return
	if exp == "detach_mesh":
		var removed: Array = []
		for node in _match.find_children("*", "MeshInstance3D", true, false):
			removed.append(node)
		var n := 0
		for node in removed:
			var parent := (node as Node).get_parent()
			if parent != null:
				parent.remove_child(node)
				n += 1
		print("[TPERF] EXP detach_mesh n=%d" % n)
		return
	if exp == "toplevel_geom":
		var n := 0
		for unit in get_tree().get_nodes_in_group("units"):
			if not is_instance_valid(unit):
				continue
			var geom := unit.get_node_or_null("Geometry") as Node3D
			if geom == null:
				continue
			geom.top_level = true
			n += 1
		print("[TPERF] EXP toplevel_geom n=%d" % n)
		return
	if exp == "mute_phys":
		var n := 0
		for node in _match.find_children("*", "CollisionObject3D", true, false):
			(node as CollisionObject3D).set_notify_transform(false)
			n += 1
		print("[TPERF] EXP mute_phys bodies=%d" % n)
		return
	if exp == "toplevel_all":
		var n := 0
		for unit in get_tree().get_nodes_in_group("units"):
			if not is_instance_valid(unit):
				continue
			for node in unit.find_children("*", "Node3D", true, false):
				if node is CollisionShape3D or node is CollisionObject3D:
					continue
				(node as Node3D).top_level = true
				n += 1
		print("[TPERF] EXP toplevel_all n=%d" % n)
		return
	if exp == "mute_agent":
		var n := 0
		for node in _match.find_children("*", "NavigationAgent3D", true, false):
			(node as Node).set_notify_transform(false)
			n += 1
		print("[TPERF] EXP mute_agent n=%d" % n)
		return
	if exp == "logic_only":
		var n := 0
		for unit in get_tree().get_nodes_in_group("units"):
			if not is_instance_valid(unit):
				continue
			for node in unit.find_children("*", "", true, false):
				if node is CollisionShape3D or node is NavigationAgent3D:
					continue
				(node as Node).process_mode = Node.PROCESS_MODE_DISABLED
				n += 1
		print("[TPERF] EXP logic_only disabled=%d" % n)
		return
	if exp == "no_actions":
		var n := 0
		for unit in get_tree().get_nodes_in_group("units"):
			if not is_instance_valid(unit):
				continue
			for node in unit.find_children("*", "Node", true, false):
				var script_res = node.get_script()
				if script_res == null:
					continue
				var path := str(script_res.resource_path)
				if "/actions/" in path:
					(node as Node).process_mode = Node.PROCESS_MODE_DISABLED
					n += 1
		print("[TPERF] EXP no_actions disabled=%d" % n)
		return
	if exp == "avoid_off":
		var n := 0
		for node in _match.find_children("*", "NavigationAgent3D", true, false):
			(node as NavigationAgent3D).avoidance_enabled = false
			n += 1
		print("[TPERF] EXP avoid_off n=%d" % n)
		return
		var detached := 0
		for unit in get_tree().get_nodes_in_group("units"):
			if not is_instance_valid(unit):
				continue
			var parent := unit.get_parent()
			if parent != null:
				parent.remove_child(unit)
				detached += 1
		print("[TPERF] EXP detach_units n=%d" % detached)
		return
	if exp == "mute_xform":
		var muted := 0
		for node in _match.find_children("*", "MeshInstance3D", true, false):
			(node as MeshInstance3D).set_notify_transform(false)
			muted += 1
		print("[TPERF] EXP mute_xform meshes=%d" % muted)
		return
	print("[TPERF] EXP %s hidden_meshes=%d paused_anims=%d" % [exp, hidden, paused])


func _print_scene_counts() -> void:
	var anim := 0
	var skel := 0
	var shapes := 0
	var units := 0
	var visible_units := 0
	var cam := get_viewport().get_camera_3d()
	for node in _match.find_children("*", "AnimationPlayer", true, false):
		anim += 1
	for node in _match.find_children("*", "Skeleton3D", true, false):
		skel += 1
	for node in _match.find_children("*", "CollisionShape3D", true, false):
		shapes += 1
	for unit in get_tree().get_nodes_in_group("units"):
		units += 1
		if cam != null and unit is Node3D and cam.is_position_in_frustum((unit as Node3D).global_position):
			visible_units += 1
	var under_geom := 0
	var outside_geom := 0
	var outside_hist := {}
	for unit in get_tree().get_nodes_in_group("units"):
		if not is_instance_valid(unit):
			continue
		var geom := unit.get_node_or_null("Geometry") as Node
		for node in unit.find_children("*", "", true, false):
			if geom != null and (node == geom or geom.is_ancestor_of(node)):
				under_geom += 1
			else:
				outside_geom += 1
				var key := (node as Node).get_class()
				outside_hist[key] = int(outside_hist.get(key, 0)) + 1
	print("[TPERF] COUNTS anim=%d skeleton=%d collision_shape=%d units=%d in_frustum=%d interp=%s render_threads=%s under_geom=%d outside_geom=%d" % [
		anim, skel, shapes, units, visible_units,
		str(ProjectSettings.get_setting("physics/common/physics_interpolation", false)),
		str(ProjectSettings.get_setting("rendering/driver/threads/thread_model", "<default>")),
		under_geom, outside_geom,
	])
	print("[TPERF] OUTSIDE_GEOM %s" % str(outside_hist))


func _install_span_marks() -> void:
	var units := _match.get_node_or_null("Units")
	if units == null:
		print("[TPERF] span marks missing Units")
		return
	var head := SpanMark.new()
	head.tag = "units_in"
	head.name = "TperfUnitsIn"
	units.add_child(head)
	units.move_child(head, 0)
	var tail := SpanMark.new()
	tail.tag = "units_out"
	tail.name = "TperfUnitsOut"
	units.add_child(tail)
	var match_out := SpanMark.new()
	match_out.tag = "match_out"
	match_out.name = "TperfMatchOut"
	_match.add_child(match_out)
	var proc_end := ProcEnd.new()
	proc_end.name = "TperfProcEnd"
	proc_end.process_priority = -1000000
	_match.add_child(proc_end)
	var root := get_tree().root
	var first := SpanMark.new()
	first.tag = "phys_first"
	first.name = "TperfPhysFirst"
	first.process_physics_priority = 1000000
	root.add_child(first)
	var last := SpanMark.new()
	last.tag = "phys_last"
	last.name = "TperfPhysLast"
	last.process_physics_priority = -1000000
	root.add_child(last)
	print("[TPERF] span marks installed")


func _spawn_buildings(player: Node) -> void:
	var spots := [Vector3(12, 0, 70), Vector3(12, 0, 96), Vector3(12, 0, 122)]
	for spot in spots:
		var building = load("res://source/match/units/VehicleFactory.tscn").instantiate()
		if _match._setup_and_spawn_unit(building, Transform3D(Basis(), spot), player) == null:
			continue
		building.apply_authoritative_construction_work(1, 1)
		building.complete_authoritative_construction()


func _spawn_army(player: Node) -> int:
	var spacing := 5.0 if _mode != "dense" else 2.4
	var cols := 16
	if _count > 256:
		cols = 32
	elif _count > 120:
		cols = 20
	var origin := Vector3(36, 0, 24)
	var spawned := 0
	for i in range(_count):
		var scene := load("res://source/match/units/%s.tscn" % ROSTER[i % ROSTER.size()])
		var unit = scene.instantiate()
		var col := i % cols
		var row := int(i / cols)
		var pos := origin + Vector3(float(col) * spacing, 0, float(row) * spacing)
		pos.x = clampf(pos.x, 8.0, MAP_LIMIT)
		pos.z = clampf(pos.z, 8.0, MAP_LIMIT)
		if _match._setup_and_spawn_unit(unit, Transform3D(Basis(), pos), player) != null:
			spawned += 1
	return spawned


func _collect_movers() -> Array:
	var movers: Array = []
	for unit in get_tree().get_nodes_in_group("units"):
		var movement = unit.get_node_or_null("Movement")
		if movement != null:
			movers.append(movement)
	return movers


func _unique_xz(movers: Array) -> int:
	var seen := {}
	for movement in movers:
		var pos: Vector3 = movement.get_parent().global_position
		seen["%d,%d" % [int(round(pos.x * 10.0)), int(round(pos.z * 10.0))]] = true
	return seen.size()


func _print_obstacles() -> void:
	for domain in Constants.Match.Navigation.DOMAIN_TO_OBSTACLE_GROUP_MAPPING.keys():
		var group_name := str(Constants.Match.Navigation.DOMAIN_TO_OBSTACLE_GROUP_MAPPING[domain])
		var nodes := get_tree().get_nodes_in_group(group_name)
		var obstacle_n := 0
		for node in nodes:
			if node.get_node_or_null("MovementObstacle") != null or node.get("radius") != null:
				obstacle_n += 1
		print("[TPERF] obstacles domain=%s group=%s nodes=%d tagged=%d" % [
			str(domain), group_name, nodes.size(), obstacle_n,
		])


func _issue_moves(movers: Array, reverse: bool) -> void:
	for movement in movers:
		if not is_instance_valid(movement):
			continue
		var pos: Vector3 = movement.get_parent().global_position
		var target := pos
		if _mode == "dense":
			target = Vector3(30, 0, 104) if reverse else Vector3(150, 0, 104)
		else:
			var delta := -36.0 if reverse else 36.0
			target = Vector3(clampf(pos.x + delta, 24.0, 190.0), pos.y, pos.z)
		movement.move(target)


func _positions(movers: Array) -> Dictionary:
	var out := {}
	for movement in movers:
		if is_instance_valid(movement):
			var pos: Vector3 = movement.get_parent().global_position
			out[movement.get_instance_id()] = Vector2(pos.x, pos.z)
	return out


func _motion(before: Dictionary, after: Dictionary) -> Dictionary:
	var moved := 0
	var stuck := 0
	var sum := 0.0
	for key in before.keys():
		if not after.has(key):
			continue
		var dist: float = (after[key] as Vector2).distance_to(before[key])
		sum += dist
		if dist > 0.5:
			moved += 1
		elif dist < 0.15:
			stuck += 1
	return {"moved": moved, "stuck": stuck, "sum": sum}


func _air_yaw_line() -> String:
	var parts: PackedStringArray = []
	for unit in get_tree().get_nodes_in_group("units"):
		if not (unit is Node3D):
			continue
		var movement = unit.get_node_or_null("Movement")
		if movement == null or int(movement.domain) != 0:
			continue
		var yaw := (unit as Node3D).global_transform.basis.get_euler().y
		parts.append("%s:%.3f" % [str(unit.name), yaw])
	return " ".join(parts) if parts.size() > 0 else "none"


func _watch_phase(phase: String, seconds: float) -> void:
	var frames: Array[float] = []
	var origin := Time.get_ticks_usec()
	var last := origin
	var max_ms := 0.0
	var max_at_ms := 0.0
	while float(Time.get_ticks_usec() - origin) / 1000000.0 < seconds:
		await get_tree().process_frame
		var now := Time.get_ticks_usec()
		var dt := float(now - last) / 1000.0
		last = now
		frames.append(dt)
		var at_ms := float(now - origin) / 1000.0
		if dt > max_ms:
			max_ms = dt
			max_at_ms = at_ms
		if dt >= 45.0:
			print("[TPERF] HITCH phase=%s at_ms=%.1f frame_ms=%.1f phys_mon=%.1f proc_mon=%.1f nav_mon=%.1f" % [
				phase, at_ms, dt,
				Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0,
				Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0,
				Performance.get_monitor(Performance.TIME_NAVIGATION_PROCESS) * 1000.0,
			])
	print("[TPERF] PHASE %s n=%d p50=%.2f p95=%.2f p99=%.2f max=%.2f max_at_ms=%.1f units=%d" % [
		phase, frames.size(), _pct(frames, 0.50), _pct(frames, 0.95), _pct(frames, 0.99),
		max_ms, max_at_ms, get_tree().get_nodes_in_group("units").size(),
	])


func _pct(values: Array, p: float) -> float:
	if values.is_empty():
		return -1.0
	var copy = values.duplicate()
	copy.sort()
	var index := clampi(int(round((copy.size() - 1) * p)), 0, copy.size() - 1)
	return float(copy[index])


func _pct_i(values: Array, p: float) -> float:
	var floats: Array[float] = []
	for value in values:
		floats.append(float(value))
	return _pct(floats, p)


func _max(values: Array) -> float:
	var out := 0.0
	for value in values:
		out = maxf(out, float(value))
	return out


func _count_over(values: Array, limit: float) -> int:
	var count := 0
	for value in values:
		if float(value) > limit:
			count += 1
	return count


func _write_outputs(summary: Dictionary, frames: Array) -> void:
	if _out == "":
		return
	DirAccess.make_dir_recursive_absolute(_out)
	var summary_file := FileAccess.open(_out.path_join("result.json"), FileAccess.WRITE)
	if summary_file != null:
		summary_file.store_string(JSON.stringify(summary, "\t"))
		summary_file.close()
	var frame_file := FileAccess.open(_out.path_join("frames.json"), FileAccess.WRITE)
	if frame_file != null:
		frame_file.store_string(JSON.stringify(frames))
		frame_file.close()


func _shots() -> void:
	if _out == "":
		return
	var camera = _match.get_node_or_null("IsometricCamera3D")
	if camera != null and camera.has_method("set_position_safely"):
		camera.set_position_safely(Vector3(96, 0, 96))
		camera.size = 80.0
	await RenderingServer.frame_post_draw
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var image := get_viewport().get_texture().get_image()
	if image != null:
		image.save_png(_out.path_join("fog.png"))
		print("[TPERF] shot fog %dx%d" % [image.get_width(), image.get_height()])
	var fog = _match.get_node_or_null("FogOfWar")
	if fog != null and fog.has_method("set_runtime_enabled"):
		fog.set_runtime_enabled(false)
	await RenderingServer.frame_post_draw
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var revealed := get_viewport().get_texture().get_image()
	if revealed != null:
		revealed.save_png(_out.path_join("full_vision.png"))
		print("[TPERF] shot full_vision %dx%d" % [revealed.get_width(), revealed.get_height()])
