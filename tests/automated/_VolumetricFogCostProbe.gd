extends Node

## R42：体积雾到底占不占性能（体积雾只影响渲染 ✓ 同进程开关不改变模拟状态 ✓）
const ROSTER := ["Tank", "APC", "HeavyTank", "Infantry", "Sniper"]
const MARGIN := 26.0
const SPACING := 5.0
const COLS := 32
const SECONDS := 12.0
var _match: Node
var _n := 300
var _agents: Array = []


func _process(_d: float) -> void:
	if get_tree().paused:
		get_tree().paused = false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	var e := OS.get_environment("AIRTS_AI_ARMY")
	_n = int(e) if e != "" else 300
	var wd := Timer.new()
	wd.one_shot = true
	wd.wait_time = 600.0
	add_child(wd)
	wd.timeout.connect(func() -> void: get_tree().quit(9))
	wd.start()
	await _run()


func _run() -> void:
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
	var world := get_viewport().find_world_3d()
	var env: Environment = world.environment if world != null else null
	print("[VFOG] movers=" + str(_agents.size()) + " env=" + str(env != null) + " 当前 volumetric=" + str(env.volumetric_fog_enabled if env != null else false))
	await _stage("① 体积雾 开（原样 ✓）")
	if env != null:
		env.volumetric_fog_enabled = false
	await _stage("② 体积雾 关")
	if env != null:
		env.volumetric_fog_enabled = true
	await _stage("③ 恢复（应回 ① ✓）")
	get_tree().quit(0)


func _stage(label: String) -> void:
	await get_tree().create_timer(1.0).timeout
	var wall: Array = []
	var last := Time.get_ticks_usec()
	var start := last
	while float(Time.get_ticks_usec() - start) / 1000000.0 < SECONDS:
		await get_tree().process_frame
		var now := Time.get_ticks_usec()
		wall.append(float(now - last) / 1000.0)
		last = now
	var dw := float(Time.get_ticks_usec() - start) / 1000000.0
	wall.sort()
	var c := wall.size()
	var draw := int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
	print("[VFOG] " + label + " 样本=" + str(c) + " p50=" + str(wall[c / 2]) + " p95=" + str(wall[mini(c - 1, int(float(c) * 0.95))]) + " FPS=" + str(float(c) / dw) + " draw=" + str(draw))
