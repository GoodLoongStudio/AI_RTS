extends Node

const ROSTER := ["Infantry", "Tank", "APC", "Worker", "HeavyTank", "Sniper"]
var _match: Node
var _movers: Array = []
var _out := "res://agent/runs/2026-10-07-small-army-performance/before"
var _results: Array = []
var _army_count := 46
var _fps_cap := 0


func _ready() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--perf-out="):
			_out = arg.trim_prefix("--perf-out=")
		elif arg.begins_with("--army-count="):
			_army_count = int(arg.trim_prefix("--army-count="))
		elif arg.begins_with("--fps-cap="):
			_fps_cap = int(arg.trim_prefix("--fps-cap="))
	DirAccess.make_dir_recursive_absolute(_out)
	FeatureFlags.handle_match_end = false
	FeatureFlags.match_augments = false
	var settings = load("res://source/data-model/MatchSettings.gd").new()
	var player_settings = load("res://source/data-model/PlayerSettings.gd").new()
	player_settings.controller = Constants.PlayerType.HUMAN
	player_settings.color = Constants.Player.COLORS[0]
	settings.players.append(player_settings)
	settings.visible_player = 0
	_match = load("res://source/match/Match.tscn").instantiate()
	_match.settings = settings
	_match.map = load("res://source/match/maps/PlainAndSimple.tscn").instantiate()
	get_tree().root.add_child.call_deferred(_match)
	await get_tree().process_frame
	get_tree().current_scene = _match
	await get_tree().create_timer(5.0).timeout
	var human: Node = _match.get_local_player()
	for i in range(_army_count):
		var unit = load("res://source/match/units/%s.tscn" % ROSTER[i % ROSTER.size()]).instantiate()
		_match._setup_and_spawn_unit(unit, Transform3D(Basis(), Vector3(65 + i % 8 * 6, 0, 65 + i / 8 * 6)), human)
	for i in range(5):
		var building = load("res://source/match/units/VehicleFactory.tscn").instantiate()
		_match._setup_and_spawn_unit(building, Transform3D(Basis(), Vector3(50 + i % 3 * 18, 0, 45 + i / 3 * 18)), human)
		building.apply_authoritative_construction_work(1, 1)
		building.complete_authoritative_construction()
	await get_tree().create_timer(8.0).timeout
	for unit in get_tree().get_nodes_in_group("units"):
		var mover = unit.get_node_or_null("Movement")
		if mover != null:
			mover.stop()
			_movers.append(mover)
	Engine.max_fps = _fps_cap
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	var camera: Camera3D = _match.get_node("IsometricCamera3D")
	camera.edge_scroll_enabled = false
	camera.size = 80.0
	camera.set_position_safely(Vector3(80, 0, 65))
	await _measure("baseline")
	# Diagnostic only: isolate the callback, then restore the exact connection.
	for mover in _movers:
		mover.velocity_computed.disconnect(mover._on_velocity_computed)
	await _measure("without_velocity_callback")
	for mover in _movers:
		mover.velocity_computed.connect(mover._on_velocity_computed)
	await _measure("restored")
	for i in range(_movers.size()):
		_movers[i].move(Vector3(70 + i % 8 * 6, 0, 30 + i / 8 * 6))
	await _measure("moving")
	if _fps_cap == 0:
		Engine.max_fps = 30
		await _measure("production_30fps_cap")
	await _diagnose_callback_machinery()
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(_out.path_join("army.png"))
	var file := FileAccess.open(_out.path_join("summary.json"), FileAccess.WRITE)
	file.store_string(JSON.stringify({"written_at": Time.get_datetime_string_from_system(), "samples": _results}, "  "))
	file.close()
	print("Small army performance probe completed: 0 failure(s)")
	_match.queue_free()
	await get_tree().process_frame
	await get_tree().process_frame
	get_tree().quit(0)


func _measure(label: String) -> void:
	await get_tree().create_timer(2.0).timeout
	var frames: Array[float] = []
	var process: Array[float] = []
	var physics: Array[float] = []
	# 【R6·非侵入测量】每帧采样，避免"窗口末一次快照"的偶然性 ✓
	var nav: Array[float] = []
	var draw: Array[float] = []
	var nodes: Array[float] = []
	# 【R7】物理服务器画像：active objects / collision pairs / islands ⇒ 拆 physics_p50 的 15ms 缺口
	var p3d: Array[float] = []
	var pairs: Array[float] = []
	var islands: Array[float] = []
	var start := Time.get_ticks_usec()
	var previous := start
	while Time.get_ticks_usec() - start < 6000000:
		await get_tree().process_frame
		var now := Time.get_ticks_usec()
		frames.append(float(now - previous) / 1000.0)
		previous = now
		process.append(Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0)
		physics.append(Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0)
		nav.append(Performance.get_monitor(Performance.TIME_NAVIGATION_PROCESS) * 1000.0)
		draw.append(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
		nodes.append(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))
		p3d.append(Performance.get_monitor(Performance.PHYSICS_3D_ACTIVE_OBJECTS))
		pairs.append(Performance.get_monitor(Performance.PHYSICS_3D_COLLISION_PAIRS))
		islands.append(Performance.get_monitor(Performance.PHYSICS_3D_ISLAND_COUNT))
	frames.sort()
	process.sort()
	physics.sort()
	nav.sort()
	draw.sort()
	nodes.sort()
	p3d.sort()
	pairs.sort()
	islands.sort()
	var row := {"stage": label, "units": get_tree().get_nodes_in_group("units").size(),
		"movers": _movers.size(), "fps_cap": Engine.max_fps,
		"obstacles": get_tree().get_nodes_in_group(Constants.Match.Navigation.DOMAIN_TO_OBSTACLE_GROUP_MAPPING[
			Constants.Match.Navigation.Domain.TERRAIN]).size(),
		"frame_p50_ms": frames[frames.size() / 2], "frame_p95_ms": frames[int(frames.size() * 0.95)],
		"fps": float(frames.size()) / (float(Time.get_ticks_usec() - start) / 1000000.0),
		"process_p50_ms": process[process.size() / 2], "physics_p50_ms": physics[physics.size() / 2],
		"nav_ms": Performance.get_monitor(Performance.TIME_NAVIGATION_PROCESS) * 1000.0,
		"nav_p50_ms": nav[nav.size() / 2], "nav_p95_ms": nav[int(nav.size() * 0.95)],
		"draw_p50": draw[draw.size() / 2], "nodes_p50": nodes[nodes.size() / 2],
		"p3d_objects": p3d[p3d.size() / 2], "p3d_pairs": pairs[pairs.size() / 2],
		"p3d_islands": islands[islands.size() / 2]}
	_results.append(row)
	print("SMALL_ARMY_PERF ", JSON.stringify(row))


## 【R15·只读诊断】量"每单位每帧回调机制"的两项成本（不改产品行为 ✓ 现场恢复 ✓）
func _diagnose_callback_machinery() -> void:
	if _movers.is_empty():
		return
	var hits := [0]
	var counter := func(_v: Vector3) -> void: hits[0] += 1
	var hooked: Array = []
	for m in _movers:
		if m.has_signal("velocity_computed") and not m.velocity_computed.is_connected(counter):
			m.velocity_computed.connect(counter)
			hooked.append(m)
	for i in range(_movers.size()):
		_movers[i].move(Vector3(90 + (i % 12) * 5.0, 0, 90 + (i / 12) * 5.0))
	for _w in range(60):
		await get_tree().physics_frame
	hits[0] = 0
	var f0 := Engine.get_physics_frames()
	for _w in range(30):
		await get_tree().physics_frame
	var df := maxi(1, Engine.get_physics_frames() - f0)
	for m in hooked:
		if m.velocity_computed.is_connected(counter):
			m.velocity_computed.disconnect(counter)
	var per_frame := float(hits[0]) / float(df)
	print("[DIAG] movers=%d | velocity_computed 触发 %.1f 次/物理帧（%.2f 次/单位/帧）" % [
		_movers.size(), per_frame, per_frame / float(_movers.size())])
	# 手动计时回调本体与 _physics_process（关引擎驱动 ⇒ 恢复 ✓）
	var sample: Array = _movers.slice(0, mini(20, _movers.size()))
	var was: Array = []
	for m in sample:
		was.append(m.is_physics_processing())
		m.set_physics_process(false)
	var delta: float = 1.0 / float(Engine.physics_ticks_per_second)
	var k := 120
	var t1 := Time.get_ticks_usec()
	for _c in range(k):
		for m in sample:
			m._on_velocity_computed(Vector3(0.1, 0.0, 0.1))
	var cb_us := float(Time.get_ticks_usec() - t1) / float(k) / float(sample.size())
	var t2 := Time.get_ticks_usec()
	for _c in range(k):
		for m in sample:
			m._physics_process(delta)
	var pp_us := float(Time.get_ticks_usec() - t2) / float(k) / float(sample.size())
	for i in range(sample.size()):
		sample[i].set_physics_process(was[i])
	print("[DIAG] 每次：_on_velocity_computed=%.1f us | _physics_process=%.1f us" % [cb_us, pp_us])
	print("[DIAG] 推算全队 %d：回调=%.1f ms/帧 主循环=%.1f ms/帧 合计=%.1f ms/帧" % [
		_movers.size(), cb_us * float(_movers.size()) / 1000.0, pp_us * float(_movers.size()) / 1000.0,
		(cb_us + pp_us) * float(_movers.size()) / 1000.0])
