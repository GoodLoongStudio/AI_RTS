extends Node

## R30（GPT-6 P0 要求）：逐类**移出场景树**诊断每类节点的每帧引擎成本
## 移除 ≠ 隐藏：隐藏的节点仍在树里、仍被引擎处理（此前实测隐藏无效 ✓ 这是原因）
## 只作诊断 ✓ 每阶段累积移除 ✓ 300 单位（378ms/帧 ⇒ 迭代快 ✓）
const ROSTER := ["Tank", "APC", "HeavyTank", "Infantry", "Sniper"]
const MARGIN := 26.0
const SPACING := 5.0
const COLS := 32
const SECONDS := 5.0
const CLASSES := ["Highlight", "Selection", "HealthBar", "Targetability", "Geometry"]
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
	var movers: Array = []
	for u in get_tree().get_nodes_in_group("units"):
		var m = u.get_node_or_null("Movement")
		if m != null:
			movers.append(m)
	for k in range(movers.size()):
		movers[k].move(Vector3(MARGIN + 60.0, 0, MARGIN + 60.0))
	await get_tree().create_timer(3.0).timeout
	print("[CLASS] movers=%d 节点=%d" % [movers.size(), Performance.get_monitor(Performance.OBJECT_NODE_COUNT)])
	await _stage("① 基线")
	for cls in CLASSES:
		var removed := 0
		for u in get_tree().get_nodes_in_group("units"):
			var c = u.get_node_or_null(cls)
			if c != null:
				u.remove_child(c)
				c.queue_free()
				removed += 1
		await get_tree().create_timer(0.5).timeout
		await _stage("② 移除 %s ×%d" % [cls, removed])
	get_tree().quit(0)


func _stage(label: String) -> void:
	await get_tree().create_timer(0.6).timeout
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
	print("[CLASS] %s | 节点=%d | FPS=%.2f frame p50=%.0f | physics=%.0f process=%.0f | 物理步/秒=%.1f" % [
		label, Performance.get_monitor(Performance.OBJECT_NODE_COUNT),
		float(c) / dw, wall[c / 2], phys[c / 2], proc[c / 2], float(df) / dw])
