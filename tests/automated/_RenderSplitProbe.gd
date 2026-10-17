extends Node

## R22：非单位渲染与场景树规模拆分（只读 ✓ 模拟不停 ✓ 行为不变 ✓）
## 阶段：基线 → 关地形 → 关迷雾视口 → 关小地图视口 → 关建筑视觉
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
	await get_tree().create_timer(3.0).timeout
	var mine: Array = []
	for u in get_tree().get_nodes_in_group("units"):
		var m = u.get_node_or_null("Movement")
		if m != null and u.get("player") == human:
			mine.append(m)
	for k in range(mine.size()):
		mine[k].move(Vector3(110.0, 0, 110.0))
	await get_tree().create_timer(4.0).timeout
	print("[SPLIT] 单位=%d 节点总数=%d" % [_n, Performance.get_monitor(Performance.OBJECT_NODE_COUNT)])
	await _stage("① 基线")
	# ② 关地形 ✓
	var terrain := _match.get_node_or_null("Map")
	var terr_nodes: Array = []
	if terrain != null:
		for t in (terrain as Node).find_children("*", "MeshInstance3D", true, false):
			if (t as MeshInstance3D).visible:
				terr_nodes.append(t)
				(t as MeshInstance3D).visible = false
	await _stage("② 关地形网格(%d)" % terr_nodes.size())
	# ③ 关迷雾视口（不隐藏节点 ✓ 只停更新 ✓）
	var fog := _match.get_node_or_null("FogOfWar")
	var vps: Array = []
	if fog != null:
		for v in (fog as Node).find_children("*", "SubViewport", true, false):
			vps.append(v)
			(v as SubViewport).render_target_update_mode = SubViewport.UPDATE_DISABLED
	await _stage("③ 停迷雾视口(%d)" % vps.size())
	# ④ 关小地图视口 ✓
	var mm := _match.get_node_or_null("Minimap")
	var mvps: Array = []
	if mm != null:
		for v in (mm as Node).find_children("*", "SubViewport", true, false):
			mvps.append(v)
			(v as SubViewport).render_target_update_mode = SubViewport.UPDATE_DISABLED
	await _stage("④ 停小地图视口(%d)" % mvps.size())
	# ⑤ 关建筑视觉 ✓
	var bld: Array = []
	for u in get_tree().get_nodes_in_group("units"):
		if u.get_node_or_null("Movement") == null:
			var g = u.get_node_or_null("Geometry")
			if g is Node3D and (g as Node3D).visible:
				bld.append(g)
				(g as Node3D).visible = false
	await _stage("⑤ 关建筑视觉(%d)" % bld.size())
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
	print("[SPLIT] %s | FPS=%.1f frame p50=%.1f p95=%.1f | physics=%.1f process=%.1f | draw=%d" % [
		label, float(c) / (float(Time.get_ticks_usec() - start) / 1000000.0),
		wall[c / 2], wall[int(c * 0.95)], phys[c / 2], proc[c / 2],
		Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)])
