extends Node

## R33：RVO 参数 A/B（只读 ✓ 可逆 ✓）—— max_neighbors / neighbor_distance / time_horizon
## 依据：代码注释指出"下发的速度极小 ⇒ time_horizon 形同虚设"⇒ 大 max_neighbors 是白付
const ROSTER := ["Tank", "APC", "HeavyTank", "Infantry", "Sniper"]
const MARGIN := 26.0
const SPACING := 5.0
const COLS := 32
const SECONDS := 5.0
var _match: Node
var _n := 300


func _process(_d: float) -> void:
	if get_tree().paused:
		get_tree().paused = false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	var e := OS.get_environment("AIRTS_AI_ARMY")
	_n = int(e) if e != "" else 300
	get_tree().create_timer(800.0).timeout.connect(func() -> void: get_tree().quit(3))
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
	await get_tree().create_timer(4.0).timeout
	var ag: Array = []
	for u in get_tree().get_nodes_in_group("units"):
		var m = u.get_node_or_null("Movement")
		if m != null:
			ag.append(m)
	for k in range(ag.size()):
		ag[k].move(Vector3(MARGIN + 70.0, 0, MARGIN + 70.0))
	await get_tree().create_timer(3.0).timeout
	var cur_max := int(ag[0].get("max_neighbors"))
	var cur_nd := float(ag[0].get("neighbor_distance"))
	var cur_th := float(ag[0].get("time_horizon_agents"))
	print("[TUNE] 现状 max_neighbors=%d neighbor_distance=%.2f time_horizon=%.2f | movers=%d" % [cur_max, cur_nd, cur_th, ag.size()])
	await _stage("① 现状（%d 邻居 ✓）" % cur_max)
	for v in [10, 6, 3]:
		for a in ag:
			a.set("max_neighbors", v)
		await _stage("② max_neighbors=%d" % v)
	# 恢复 ✓
	for a in ag:
		a.set("max_neighbors", cur_max)
	await _stage("③ 恢复 %d（应回到 ① ✓）" % cur_max)
	get_tree().quit(0)


func _stage(label: String) -> void:
	await get_tree().create_timer(0.8).timeout
	var wall: Array = []
	var phys: Array = []
	var last := Time.get_ticks_usec()
	var start := last
	var f0 := Engine.get_physics_frames()
	while float(Time.get_ticks_usec() - start) / 1000000.0 < SECONDS:
		await get_tree().process_frame
		var now := Time.get_ticks_usec()
		wall.append(float(now - last) / 1000.0)
		last = now
		phys.append(Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0)
	var df := Engine.get_physics_frames() - f0
	var dw := float(Time.get_ticks_usec() - start) / 1000000.0
	wall.sort(); phys.sort()
	var c := wall.size()
	print("[TUNE] %s | FPS=%.2f frame p50=%.0f p95=%.0f | physics p50=%.0f | 物理步/秒=%.1f" % [
		label, float(c) / dw, wall[c / 2], wall[int(c * 0.95)], phys[c / 2], float(df) / dw])
