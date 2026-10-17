extends Node

## R29（按 GPT-6 提示词 P0 修正版夹具）
## 修正点：① 32×32 网格 × 5m 间距 ⇒ 1000 个单位各有唯一坐标、互不重叠、不出界；
##        ② 运行时打印**每域障碍组成员与类别**（不把 mover 数当障碍数）；
##        ③ 记录**真实物理步数**（Engine.get_physics_frames 差分）与墙钟，不用 max_steps 上限冒充。
const ROSTER := ["Tank", "APC", "HeavyTank", "Infantry", "Sniper"]
const MARGIN := 26.0
const SPACING := 5.0
const COLS := 32
const SECONDS := 8.0
var _match: Node
var _n := 1000


func _process(_d: float) -> void:
	if get_tree().paused:
		get_tree().paused = false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	var e := OS.get_environment("AIRTS_AI_ARMY")
	_n = int(e) if e != "" else 1000
	get_tree().create_timer(900.0).timeout.connect(func() -> void: get_tree().quit(3))
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
	# ① 唯一坐标的合法网格 ✓（32 列 × 5m ⇒ 1000 个各占一格 ✓ 不出界 ✓）
	var spawned := 0
	for i in range(_n):
		var u = load("res://source/match/units/%s.tscn" % ROSTER[i % ROSTER.size()]).instantiate()
		var px := MARGIN + float(i % COLS) * SPACING
		var pz := MARGIN + float((i / COLS) % COLS) * SPACING
		_match._setup_and_spawn_unit(u, Transform3D(Basis(), Vector3(px, 0, pz)), ai)
		spawned += 1
	await get_tree().create_timer(4.0).timeout
	var movers := 0
	for u in get_tree().get_nodes_in_group("units"):
		if u.get_node_or_null("Movement") != null:
			movers += 1
	print("[FIX] 请求=%d 生成尝试=%d 实得 movers=%d | 网格 %dx%d 间距 %.1fm 起点 %.0f ⇒ 覆盖 %.0f..%.0f" % [
		_n, spawned, movers, COLS, int(ceil(float(_n) / float(COLS))), SPACING, MARGIN,
		MARGIN, MARGIN + float(COLS - 1) * SPACING])
	# ② 每域障碍组成员与类别 ✓（不把 mover 当障碍）
	for d in Constants.Match.Navigation.DOMAIN_TO_OBSTACLE_GROUP_MAPPING.keys():
		var gn: String = str(Constants.Match.Navigation.DOMAIN_TO_OBSTACLE_GROUP_MAPPING[d])
		var nodes: Array = get_tree().get_nodes_in_group(gn)
		if nodes.is_empty():
			continue
		var units_with_movement := 0
		var obstacles := 0
		var other := 0
		for x in nodes:
			if (x as Node).get_node_or_null("MovementObstacle") != null:
				obstacles += 1
			elif (x as Node).get_node_or_null("Movement") != null:
				units_with_movement += 1
			else:
				other += 1
		print("[FIX] 域=%s 组=%s 规模=%d ⇒ MovementObstacle=%d / 带Movement单位=%d / 其它=%d" % [
			str(d), gn, nodes.size(), obstacles, units_with_movement, other])
	# ③ 真实物理步与墙钟 ✓（不再用 max_steps 上限）
	var f0 := Engine.get_physics_frames()
	var w0 := Time.get_ticks_usec()
	var wall: Array = []
	var phys: Array = []
	var proc: Array = []
	var last := w0
	while float(Time.get_ticks_usec() - w0) / 1000000.0 < SECONDS:
		await get_tree().process_frame
		var now := Time.get_ticks_usec()
		wall.append(float(now - last) / 1000.0)
		last = now
		phys.append(Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0)
		proc.append(Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0)
	var df := Engine.get_physics_frames() - f0
	var dw := float(Time.get_ticks_usec() - w0) / 1000000.0
	wall.sort(); phys.sort(); proc.sort()
	var c := wall.size()
	print("[FIX] === 基线（%d 单位 ✓ 合法网格 ✓）===" % movers)
	print("[FIX] FPS=%.2f frame p50=%.1f p95=%.1f | physics p50=%.1f process p50=%.1f" % [
		float(c) / dw, wall[c / 2], wall[int(c * 0.95)], phys[c / 2], proc[c / 2]])
	print("[FIX] **真实物理步**=%d 步 / %.1f 秒 = **%.2f 步/秒**；渲染帧 %d ⇒ **%.2f 物理步/帧**" % [
		df, dw, float(df) / dw, c, float(df) / float(maxi(1, c))])
	get_tree().quit(0)
