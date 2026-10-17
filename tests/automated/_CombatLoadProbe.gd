extends Node

## R19b：交火负载容量检查（champion 口径 ✓）——补上 skill 要求的"持续交火" ✓
const ROSTER := ["Infantry", "Tank", "APC", "Worker", "HeavyTank", "Sniper"]
const N_FRIEND := 40
const N_ENEMY := 30
const SECONDS := 10.0

var _match: Node


func _process(_d: float) -> void:
	if get_tree().paused:
		get_tree().paused = false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	get_tree().create_timer(320.0).timeout.connect(func() -> void: get_tree().quit(3))
	await _run()


func _run() -> void:
	var settings = load("res://source/data-model/MatchSettings.gd").new()
	var human_ps = load("res://source/data-model/PlayerSettings.gd").new()
	human_ps.controller = Constants.PlayerType.HUMAN
	human_ps.color = Constants.Player.COLORS[0]
	settings.players.append(human_ps)
	var ai_ps = load("res://source/data-model/PlayerSettings.gd").new()
	ai_ps.controller = Constants.PlayerType.AI_EASY
	ai_ps.color = Constants.Player.COLORS[1]
	ai_ps.spawn_index_offset = 1
	settings.players.append(ai_ps)
	settings.visible_player = 0
	_match = load("res://source/match/Match.tscn").instantiate()
	_match.settings = settings
	_match.map = load("res://source/match/maps/PlainAndSimple.tscn").instantiate()
	get_tree().root.add_child.call_deferred(_match)
	await get_tree().process_frame
	get_tree().current_scene = _match
	await get_tree().create_timer(5.0).timeout
	var human: Node = _match.get_local_player()
	var players: Array = _match.get_node("Players").get_children()
	var ai: Node = null
	for p in players:
		if p != human and p.get_node_or_null("ConstructionWorksController") != null:
			ai = p
	if ai == null:
		print("[COMBAT] 找不到 AI 玩家 ✗"); get_tree().quit(0); return
	# 友军（我方）与敌军（AI 方）✓ 两军相向 ✓
	for i in range(N_FRIEND):
		var u = load("res://source/match/units/%s.tscn" % ROSTER[i % ROSTER.size()]).instantiate()
		_match._setup_and_spawn_unit(u, Transform3D(Basis(), Vector3(70 + (i % 8) * 4.0, 0, 70 + (i / 8) * 4.0)), human)
	for i in range(N_ENEMY):
		var u = load("res://source/match/units/%s.tscn" % ROSTER[i % ROSTER.size()]).instantiate()
		_match._setup_and_spawn_unit(u, Transform3D(Basis(), Vector3(70 + (i % 8) * 4.0, 0, 100 + (i / 8) * 4.0)), ai)
	await get_tree().create_timer(4.0).timeout
	var friendly: Array = []
	var enemy: Array = []
	for u in get_tree().get_nodes_in_group("units"):
		var m = u.get_node_or_null("Movement")
		if m == null:
			continue
		var owner_player: Node = u.get("player") if u.get("player") != null else null
		if owner_player == human: friendly.append(m)
		elif owner_player == ai: enemy.append(m)
	print("[COMBAT] 友军 movers=%d 敌军 movers=%d" % [friendly.size(), enemy.size()])
	# 双方相向推进 ⇒ 接触即交火 ✓
	for k in range(friendly.size()):
		friendly[k].move(Vector3(80 + (k % 8) * 3.0, 0, 95))
	for k in range(enemy.size()):
		enemy[k].move(Vector3(80 + (k % 8) * 3.0, 0, 75))
	var wall: Array = []
	var phys: Array = []
	var proc: Array = []
	var last := Time.get_ticks_usec()
	var start := last
	while float(Time.get_ticks_usec() - start) / 1000000.0 < SECONDS:
		await get_tree().process_frame
		var now := Time.get_ticks_usec()
		wall.append(float(now - last) / 1000.0)
		last = now
		phys.append(Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0)
		proc.append(Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0)
	wall.sort(); phys.sort(); proc.sort()
	var n := wall.size()
	var alive := get_tree().get_nodes_in_group("units").size()
	print("[COMBAT] 交火 %.0fs：FPS=%.1f frame p50=%.2f p95=%.2f physics p50=%.2f process p50=%.2f | 剩余实体=%d" % [
		SECONDS, float(n) / (float(Time.get_ticks_usec() - start) / 1000000.0), wall[n / 2], wall[int(n * 0.95)],
		phys[n / 2], proc[n / 2], alive])
	get_tree().quit(0)
