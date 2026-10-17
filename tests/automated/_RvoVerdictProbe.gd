extends Node

## R24：决定性实验 —— 300 单位下断开 velocity_computed（RVO 是否就是那 39ms/tick）
## 只读 ✓ 测完立即恢复 ✓（同一进程内 A/B ✓ 无环境漂移 ✓）
const ROSTER := ["Tank", "APC", "HeavyTank", "Infantry", "Sniper"]
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
	get_tree().create_timer(700.0).timeout.connect(func() -> void: get_tree().quit(3))
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
		_match._setup_and_spawn_unit(u, Transform3D(Basis(), Vector3(60.0 + float(i % 20) * 3.2, 0, 60.0 + float((i / 20) % 20) * 3.2)), ai)
	await get_tree().create_timer(4.0).timeout
	var movers: Array = []
	for u in get_tree().get_nodes_in_group("units"):
		var m = u.get_node_or_null("Movement")
		if m != null:
			movers.append(m)
	for k in range(movers.size()):
		movers[k].move(Vector3(100.0 + float(k % 12) * 4.0, 0, 100.0))
	await get_tree().create_timer(4.0).timeout
	print("[RVO] movers=%d 节点=%d" % [movers.size(), Performance.get_monitor(Performance.OBJECT_NODE_COUNT)])
	await _stage("① 基线（RVO 开 ✓）")
	# 断开回调 ✓（引擎的 RVO 计算随之停 ✓ —— 这正是夹具验证过的手法 ✓）
	var disconnected := 0
	for m in movers:
		if m.velocity_computed.is_connected(m._on_velocity_computed):
			m.velocity_computed.disconnect(m._on_velocity_computed)
			disconnected += 1
	await _stage("② 断开 velocity_computed(%d)" % disconnected)
	# 恢复 ✓
	for m in movers:
		if not m.velocity_computed.is_connected(m._on_velocity_computed):
			m.velocity_computed.connect(m._on_velocity_computed)
	await _stage("③ 恢复（应与①接近 ✓）")
	get_tree().quit(0)


func _stage(label: String) -> void:
	await get_tree().create_timer(1.0).timeout
	var wall: Array = []
	var proc: Array = []
	var phys: Array = []
	var last := Time.get_ticks_usec()
	var start := last
	while float(Time.get_ticks_usec() - start) / 1000000.0 < SECONDS:
		await get_tree().process_frame
		var now := Time.get_ticks_usec()
		wall.append(float(now - last) / 1000.0)
		last = now
		proc.append(Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0)
		phys.append(Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0)
	wall.sort(); proc.sort(); phys.sort()
	var c := wall.size()
	print("[RVO] %s | FPS=%.1f frame p50=%.1f p95=%.1f | physics=%.1f process=%.1f" % [
		label, float(c) / (float(Time.get_ticks_usec() - start) / 1000000.0),
		wall[c / 2], wall[int(c * 0.95)], phys[c / 2], proc[c / 2]])
