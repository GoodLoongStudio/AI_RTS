extends Node

## R31：**干净地**隔离 RVO —— agent.avoidance_enabled = false（保留寻路 ✓ 只关避障 ✓）
## 这是 GPT-6 要求的"可控 A/B"：不是断信号（那会改状态 ✗），而是引擎开关 ✓
const ROSTER := ["Tank", "APC", "HeavyTank", "Infantry", "Sniper"]
const MARGIN := 26.0
const SPACING := 5.0
const COLS := 32
const SECONDS := 6.0
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
	var agents: Array = []
	for u in get_tree().get_nodes_in_group("units"):
		var m = u.get_node_or_null("Movement")
		if m != null:
			agents.append(m)
	for k in range(agents.size()):
		agents[k].move(Vector3(MARGIN + 70.0, 0, MARGIN + 70.0))
	await get_tree().create_timer(3.0).timeout
	var enabled := 0
	for a in agents:
		if bool(a.get("avoidance_enabled")):
			enabled += 1
	print("[RVO2] movers=%d 其中 avoidance_enabled=%d | 节点=%d" % [agents.size(), enabled, Performance.get_monitor(Performance.OBJECT_NODE_COUNT)])
	await _stage("① 基线（RVO 开 ✓）")
	var off := 0
	for a in agents:
		a.set("avoidance_enabled", false)
		off += 1
	await _stage("② avoidance_enabled=false（%d 个 ✓ 寻路保留 ✓）" % off)
	var on := 0
	for a in agents:
		a.set("avoidance_enabled", true)
		on += 1
	await _stage("③ 恢复（应回到 ① ✓）")
	get_tree().quit(0)


func _stage(label: String) -> void:
	await get_tree().create_timer(0.8).timeout
	var wall: Array = []
	var phys: Array = []
	var proc: Array = []
	var last := Time.get_ticks_usec()
	var start := last
	var f0 := Engine.get_physics_frames()
	while float(Time.get_ticks_usec() - start) / 1000000.0 < SECONDS:
		await get_tree().process_frame
		var now := Time.get_ticks_usec()
		wall.append(float(now - last) / 1000.0)
		last = now
		phys.append(Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0)
		proc.append(Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0)
	var df := Engine.get_physics_frames() - f0
	var dw := float(Time.get_ticks_usec() - start) / 1000000.0
	wall.sort(); phys.sort(); proc.sort()
	var c := wall.size()
	print("[RVO2] %s | FPS=%.2f frame p50=%.0f p95=%.0f | physics=%.0f process=%.0f | 物理步/秒=%.1f" % [
		label, float(c) / dw, wall[c / 2], wall[int(c * 0.95)], phys[c / 2], proc[c / 2], float(df) / dw])
