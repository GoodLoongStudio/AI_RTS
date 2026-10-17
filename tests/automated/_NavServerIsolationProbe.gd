extends Node

## R35：隔离"寻路 + 地图同步" —— RVO 关 + NavigationServer 停（非侵入 ✓ 可逆 ✓）
const ROSTER := ["Tank", "APC", "HeavyTank", "Infantry", "Sniper"]
const MARGIN := 26.0
const SPACING := 5.0
const COLS := 32
const SECONDS := 5.0
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
	get_tree().create_timer(800.0).timeout.connect(func() -> void: get_tree().quit(3))
	await _run()


func _run() -> void:
	print("[NAVISOL] NavigationServer3D 有 set_active 方法:", NavigationServer3D.has_method("set_active"))
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
	for u in get_tree().get_nodes_in_group("units"):
		var m = u.get_node_or_null("Movement")
		if m != null:
			_agents.append(m)
	for k in range(_agents.size()):
		_agents[k].move(Vector3(MARGIN + 70.0, 0, MARGIN + 70.0))
	await get_tree().create_timer(3.0).timeout
	print("[NAVISOL] movers=%d 节点=%d" % [_agents.size(), Performance.get_monitor(Performance.OBJECT_NODE_COUNT)])
	await _stage("① RVO 开（基线）")
	for a in _agents:
		a.set("avoidance_enabled", false)
	await _stage("② RVO 关 ✓")
	# 停掉整个导航服务器 ✓（隔离寻路 + 地图同步 ✓ 可逆 ✓）
	NavigationServer3D.set_active(false)
	await _stage("③ 再停 NavigationServer（寻路/地图同步都没了）")
	NavigationServer3D.set_active(true)
	await _stage("④ 恢复 NavigationServer（应约等于 ②）")
	get_tree().quit(0)


func _stage(label: String) -> void:
	await get_tree().create_timer(0.8).timeout
	var wall: Array = []
	var last := Time.get_ticks_usec()
	var start := last
	var f0 := Engine.get_physics_frames()
	while float(Time.get_ticks_usec() - start) / 1000000.0 < SECONDS:
		await get_tree().process_frame
		var now := Time.get_ticks_usec()
		wall.append(float(now - last) / 1000.0)
		last = now
	var df := Engine.get_physics_frames() - f0
	var dw := float(Time.get_ticks_usec() - start) / 1000000.0
	wall.sort()
	var c := wall.size()
	print("[NAVISOL] %-32s | FPS=%.2f frame p50=%.0f p95=%.0f | 物理步/秒=%.1f" % [
		label, float(c) / dw, wall[c / 2], wall[int(c * 0.95)], float(df) / dw])
