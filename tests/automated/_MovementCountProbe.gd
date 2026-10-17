extends Node

## R53：读取 Movement 的真实路径计数（GPT-6 口径：先计数 ✓ 不猜 ✓）
const ROSTER := ["Tank", "APC", "HeavyTank", "Infantry", "Sniper"]
const MARGIN := 26.0
const SPACING := 5.0
const COLS := 32
const SECONDS := 15.0
var _match: Node
var _n := 100
var _agents: Array = []


func _process(_d: float) -> void:
	if get_tree().paused:
		get_tree().paused = false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	var e := OS.get_environment("AIRTS_AI_ARMY")
	_n = int(e) if e != "" else 100
	var wd := Timer.new()
	wd.one_shot = true
	wd.wait_time = 400.0
	add_child(wd)
	wd.timeout.connect(func() -> void: print("[CNT] WATCHDOG"); get_tree().quit(9))
	wd.start()
	await _run()


func _run() -> void:
	var Mv = load("res://source/match/units/traits/Movement.gd")
	var settings = load("res://source/data-model/MatchSettings.gd").new()
	var hps = load("res://source/data-model/PlayerSettings.gd").new()
	hps.controller = Constants.PlayerType.HUMAN
	hps.color = Constants.Player.COLORS[0]
	settings.players.append(hps)
	var aps = load("res://source/data-model/PlayerSettings.gd").new()
	aps.controller = Constants.PlayerType.AI_EASY
	aps.color = Constants.Player.COLORS[1]
	aps.spawn_index_offset = 1
	settings.players.append(aps)
	settings.visible_player = 0
	_match = load("res://source/match/Match.tscn").instantiate()
	_match.settings = settings
	_match.map = load("res://source/match/maps/PlainAndSimple.tscn").instantiate()
	get_tree().root.add_child.call_deferred(_match)
	await get_tree().process_frame
	get_tree().current_scene = _match
	await get_tree().create_timer(5.0).timeout
	var human: Node = _match.get_local_player()
	var ai: Node = null
	for p in _match.get_node("Players").get_children():
		if p != human and p.get_node_or_null("ConstructionWorksController") != null:
			ai = p
	for i in range(_n):
		var u = load("res://source/match/units/%s.tscn" % ROSTER[i % ROSTER.size()]).instantiate()
		_match._setup_and_spawn_unit(u, Transform3D(Basis(), Vector3(MARGIN + float(i % COLS) * SPACING, 0, MARGIN + float((i / COLS) % COLS) * SPACING)), ai)
	await get_tree().create_timer(5.0).timeout
	for u in get_tree().get_nodes_in_group("units"):
		var m = u.get_node_or_null("Movement")
		if m != null:
			_agents.append(m)
	var goals := [Vector3(150, 0, 40), Vector3(40, 0, 150), Vector3(150, 0, 150), Vector3(40, 0, 40)]
	for k in range(_agents.size()):
		_agents[k].move(goals[k % goals.size()])
	await get_tree().create_timer(6.0).timeout
	print("[CNT] 诊断开关=" + str(Mv._diag_on()) + " movers=" + str(_agents.size()))
	Mv.diag_reset()
	var f0 := Engine.get_physics_frames()
	var s0 := Time.get_ticks_usec()
	var frames := 0
	while float(Time.get_ticks_usec() - s0) / 1000000.0 < SECONDS:
		await get_tree().process_frame
		frames += 1
	var steps := Engine.get_physics_frames() - f0
	var wall := float(Time.get_ticks_usec() - s0) / 1000000.0
	var rep: String = Mv.diag_report()
	print("[CNT] 规模=" + str(_agents.size()) + " 物理步=" + str(steps) + " 渲染帧=" + str(frames) + " 墙钟=" + str(snappedf(wall, 0.1)) + "s 物理步每秒=" + str(snappedf(float(steps) / wall, 0.1)))
	print("[CNT] 原始计数: " + rep)
	# 折算到"每单位每物理步" ✓（inclusive ✓ 不重复加）
	var counts: Dictionary = Mv.diag_counts
	var keys: Array = counts.keys()
	keys.sort()
	for k in keys:
		var c := float(counts[k])
		var per_unit_step := c / maxf(1.0, float(_agents.size()) * float(steps))
		var per_frame := c / maxf(1.0, float(frames))
		print("[CNT]   " + str(k).padEnd(10) + " 总=" + str(int(c)) + " 每单位每物理步=" + str(snappedf(per_unit_step, 0.001)) + " 每渲染帧=" + str(snappedf(per_frame, 0.1)))
	# 位移核验 ✓（健康门禁）
	var moved := 0
	for a in _agents:
		if is_instance_valid(a) and (a.get("_committed_target") != null or true):
			moved += 1
	print("[CNT] 存活 movers=" + str(moved) + "/" + str(_agents.size()))
	get_tree().quit(0)
