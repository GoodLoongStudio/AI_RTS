extends Node

## R26：**全图视野**下的渲染压力实测（用户要求 ✓）
## 条件：① 关掉迷雾遮罩（全图可见 ✓）② 相机拉到能看见**全部**单位 ✓ ③ 单位全部在画面内 ✓
const ROSTER := ["Tank", "APC", "HeavyTank", "Infantry", "Sniper"]
const SECONDS := 8.0
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
	# 紧凑阵型：全部集中在相机视野内 ✓
	for i in range(_n):
		var u = load("res://source/match/units/%s.tscn" % ROSTER[i % ROSTER.size()]).instantiate()
		_match._setup_and_spawn_unit(u, Transform3D(Basis(), Vector3(85.0 + float(i % 25) * 2.2, 0, 85.0 + float((i / 25) % 25) * 2.2)), ai)
	# ① 全图视野：关掉迷雾遮罩 ✓（测量条件 ✓ 非产品改动 ✓）
	var revealed: Array = []
	var fog := _match.get_node_or_null("FogOfWar")
	if fog != null:
		for m in (fog as Node).find_children("*", "CanvasItem", true, false):
			if (m as CanvasItem).visible:
				revealed.append(m)
				(m as CanvasItem).visible = false
	# 【修正】单位是 Node3D（不是 CanvasItem ✗）⇒ 强制可见 ✓
	# 并**临时停掉逐单位可见性处理器** ✓（否则它每拍把敌人重新隐藏 ✓ 测量就无效 ✗）
	var vh := _match.get_node_or_null("UnitVisibilityHandler")
	if vh == null:
		for n in _match.find_children("*", "", true, false):
			if n.get_script() != null and str((n.get_script() as Script).resource_path).ends_with("UnitVisibilityHandler.gd"):
				vh = n
				break
	var vh_was := false
	if vh != null and (vh as Node).has_method("is_physics_processing"):
		vh_was = (vh as Node).is_physics_processing()
		(vh as Node).set_physics_process(false)
	var forced := 0
	for u in get_tree().get_nodes_in_group("units"):
		if u is Node3D and not (u as Node3D).visible:
			(u as Node3D).visible = true
			forced += 1
	print("[VIS] 强制可见单位=%d；可见性处理器=%s（原 physics=%s ✓）" % [forced, str(vh != null), str(vh_was)])
	# ② 相机拉远到能看见全部单位 ✓
	var cam = _match.get_node_or_null("IsometricCamera3D")
	if cam != null:
		cam.edge_scroll_enabled = false
		cam.size = 320.0
		if cam.has_method("set_position_safely"):
			cam.set_position_safely(Vector3(85.0, 0, 85.0))
	# 每帧再强制一次可见 ✓（保险 ✓）
	for _f in range(120):
		for u in get_tree().get_nodes_in_group("units"):
			if u is Node3D and not (u as Node3D).visible:
				(u as Node3D).visible = true
		await get_tree().process_frame
	await get_tree().create_timer(2.0).timeout
	var vis_now := 0
	for u in get_tree().get_nodes_in_group("units"):
		if u is Node3D and (u as Node3D).visible:
			vis_now += 1
	print("[VIS] 单位=%d 视野内可见=%d 迷雾节点隐藏=%d 相机 size=%s ✓" % [_n, vis_now, revealed.size(), str(cam.size) if cam != null else "n/a"])
	await _stage("① 全图视野 · 全部可见")
	# ③ 对照：藏掉单位视觉 ✓（此时它们**确实在画面里** ✓ 才有意义 ✓）
	var visuals: Array = []
	for u in get_tree().get_nodes_in_group("units"):
		var g = u.get_node_or_null("Geometry")
		if g is Node3D and (g as Node3D).visible:
			visuals.append(g)
			(g as Node3D).visible = false
	await _stage("② 全图视野 + 藏单位模型(%d)" % visuals.size())
	for v in visuals:
		(v as Node3D).visible = true
	if vh != null and vh_was:
		(vh as Node).set_physics_process(true)
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
	print("[VIS] %s | FPS=%.1f frame p50=%.1f p95=%.1f | physics=%.1f process=%.1f | draw=%d" % [
		label, float(c) / (float(Time.get_ticks_usec() - start) / 1000000.0),
		wall[c / 2], wall[int(c * 0.95)], phys[c / 2], proc[c / 2],
		Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)])
