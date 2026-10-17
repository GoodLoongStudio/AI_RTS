extends Node

## R12b：生产口径（30 FPS + vsync）下的负载扩展 50/100/200 ✓

const SECONDS := 8.0
var _match: Node
var _target := 50


func _process(_d: float) -> void:
	if get_tree().paused:
		get_tree().paused = false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	var env := OS.get_environment("AIRTS_LOAD")
	_target = int(env) if env != "" else 50
	get_tree().create_timer(400.0).timeout.connect(func() -> void: get_tree().quit(3))
	await _run()


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
	await get_tree().create_timer(5.0).timeout
	for _f in range(60):
		await get_tree().physics_frame
	# 【修正】必须用 local player ✓（夹具同款 ✓）；Players.get_child(0) 不是它 ✗
	var player: Node = _match.get_local_player()
	# 【R13】照夹具做法：先造**车厂**（建筑可直接生成 ✓）并让它完工 ⇒ 由它**生产**单位 ✓
	var factories := 0
	var max_factories: int = maxi(3, int(ceil(float(_target) / 8.0)))
	for i in range(max_factories):
		var b = load("res://source/match/units/VehicleFactory.tscn").instantiate()
		var pos := Vector3(50 + (i % 3) * 18, 0, 45 + (i / 3) * 18)
		if _match._setup_and_spawn_unit(b, Transform3D(Basis(), pos), player) != null:
			b.apply_authoritative_construction_work(1, 1)
			b.complete_authoritative_construction()
			factories += 1
	print("[LOAD] 车厂=%d（目标 mover=%d ✓）" % [factories, _target])
	# 等生产到目标数量（上限 90 秒 ✓）
	var deadline := Time.get_ticks_msec() + 90000
	while _count_units(player) < _target and Time.get_ticks_msec() < deadline:
		await get_tree().physics_frame
	print("[LOAD] 生产等待结束：units=%d（用时 %.1fs）" % [_count_units(player), float(Time.get_ticks_msec() - (deadline - 90000)) / 1000.0])
	for _f in range(30):
		await get_tree().physics_frame
	var movers: Array = []
	for u in player.get_children():
		var m = u.get_node_or_null("Movement")
		if m != null:
			movers.append(m)
	print("[LOAD] 目标=%d 实际=%d movers=%d 生成失败=%d max_fps=%d vsync=%d" % [
		_target, _count_units(player), movers.size(), fails, Engine.max_fps, DisplayServer.window_get_vsync_mode()])
	for k in range(movers.size()):
		movers[k].move(Vector3(100 + (k % 10) * 6.0, 0, 100 + (k / 10) * 6.0))
	var wall: Array = []
	var phys: Array = []
	var proc: Array = []
	var last_t := Time.get_ticks_usec()
	var start := last_t
	while float(Time.get_ticks_usec() - start) / 1000000.0 < SECONDS:
		await get_tree().process_frame
		var now := Time.get_ticks_usec()
		wall.append(float(now - last_t) / 1000.0)
		last_t = now
		phys.append(Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0)
		proc.append(Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0)
	wall.sort(); phys.sort(); proc.sort()
	var n := wall.size()
	var fps := float(n) / (float(Time.get_ticks_usec() - start) / 1000000.0)
	print("[LOAD] N=%d units=%d FPS=%.1f frame p50=%.2f p95=%.2f p99=%.2f physics p50=%.2f process p50=%.2f" % [
		_target, _count_units(player), fps, wall[n / 2], wall[int(n * 0.95)], wall[int(n * 0.99)],
		phys[n / 2], proc[n / 2]])
	get_tree().quit(0)


func _count_units(player: Node) -> int:
	var c := 0
	for u in player.get_children():
		if u.get_node_or_null("Movement") != null:
			c += 1
	return c
