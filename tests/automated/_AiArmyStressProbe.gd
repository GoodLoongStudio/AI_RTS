extends Node

## R21：AI 指挥超多单位 —— FPS 压力实测（生产口径 30 FPS ✓）
## 用 AIRTS_AI_ARMY 指定 AI 一方单位数（默认 300 ✓）

const ROSTER := ["Tank", "APC", "HeavyTank", "Infantry", "Sniper", "Tank", "APC", "HeavyTank"]
const SECONDS := 15.0

var _match: Node
var _n := 300


func _process(_d: float) -> void:
	if get_tree().paused:
		get_tree().paused = false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	var e := OS.get_environment("AIRTS_AI_ARMY")
	_n = int(e) if e != "" else 300
	get_tree().create_timer(600.0).timeout.connect(func() -> void: get_tree().quit(3))
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
	var ai: Node = null
	for p in _match.get_node("Players").get_children():
		if p != human and p.get_node_or_null("ConstructionWorksController") != null:
			ai = p
	if ai == null:
		print("[AISTRESS] 找不到 AI 玩家 ✗"); get_tree().quit(0); return
	print("[AISTRESS] 开始生成 AI 单位 %d 个 …" % _n)
	var t_gen := Time.get_ticks_usec()
	for i in range(_n):
		var u = load("res://source/match/units/%s.tscn" % ROSTER[i % ROSTER.size()]).instantiate()
		var px := 60.0 + float(i % 20) * 3.2
		var pz := 60.0 + float((i / 20) % 20) * 3.2
		_match._setup_and_spawn_unit(u, Transform3D(Basis(), Vector3(px, 0, pz)), ai)
	var gen_s := float(Time.get_ticks_usec() - t_gen) / 1000000.0
	await get_tree().create_timer(3.0).timeout
	var movers := 0
	for u in get_tree().get_nodes_in_group("units"):
		if u.get_node_or_null("Movement") != null:
			movers += 1
	print("[AISTRESS] 生成完成 %.1fs；场上 movers=%d（AI 方 %d 个目标 ✓）" % [gen_s, movers, _n])
	# 让 AI 真的动起来：给我的单位下"推进"令，AI 会自行索敌/交战 ✓
	var mine: Array = []
	for u in get_tree().get_nodes_in_group("units"):
		var m = u.get_node_or_null("Movement")
		if m != null and u.get("player") == human:
			mine.append(m)
	for k in range(mine.size()):
		mine[k].move(Vector3(110.0 + float(k % 6) * 4.0, 0, 110.0))
	print("[AISTRESS] 我方 movers=%d 已下推进令 ⇒ 进入 15s 测量 ✓" % mine.size())
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
	var fps := float(n) / (float(Time.get_ticks_usec() - start) / 1000000.0)
	var alive := 0
	for u in get_tree().get_nodes_in_group("units"):
		if u.get_node_or_null("Movement") != null:
			alive += 1
	print("[AISTRESS] === AI 指挥 %d 单位（实测 %d movers）===" % [_n, movers])
	print("[AISTRESS] FPS=%.1f | frame p50=%.2f p95=%.2f p99=%.2f | physics p50=%.1f | process p50=%.1f | 结束存活 mover=%d" % [
		fps, wall[n / 2], wall[int(n * 0.95)], wall[int(n * 0.99)], phys[n / 2], proc[n / 2], alive])
	# 【只读对照】隐藏所有单位的**视觉**节点（模拟照跑 ✓ 行为不变 ✓）⇒ 差值 = 单位渲染成本 ✓
	var visuals: Array = []
	for u in get_tree().get_nodes_in_group("units"):
		var v = u.get_node_or_null("Geometry")
		if v is Node3D and (v as Node3D).visible:
			visuals.append(v)
			(v as Node3D).visible = false
	await get_tree().create_timer(1.5).timeout
	var wall2: Array = []
	var proc2: Array = []
	var last2 := Time.get_ticks_usec()
	var start2 := last2
	while float(Time.get_ticks_usec() - start2) / 1000000.0 < 8.0:
		await get_tree().process_frame
		var now2 := Time.get_ticks_usec()
		wall2.append(float(now2 - last2) / 1000.0)
		last2 = now2
		proc2.append(Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0)
	wall2.sort(); proc2.sort()
	var m2 := wall2.size()
	var fps2 := float(m2) / (float(Time.get_ticks_usec() - start2) / 1000000.0)
	print("[AISTRESS] === 隐藏单位视觉（%d 个 ✓ 模拟未停 ✓）===" % visuals.size())
	print("[AISTRESS] FPS=%.1f | frame p50=%.2f p95=%.2f | process p50=%.1f | draw=%d" % [
		fps2, wall2[m2 / 2], wall2[int(m2 * 0.95)], proc2[m2 / 2],
		Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)])
	for v in visuals:
		(v as Node3D).visible = true
	# ── 阶段 2：再隐藏单位**叠加层**（选中圈/高亮/血条/可选中标记 ✓ 只读 ✓）
	var overlays: Array = []
	for u in get_tree().get_nodes_in_group("units"):
		for nm in ["Highlight", "Selection", "HealthBar", "Targetability"]:
			var ov = u.get_node_or_null(nm)
			if ov is Node3D and (ov as Node3D).visible:
				overlays.append(ov)
				(ov as Node3D).visible = false
	await _measure_stage("隐藏单位叠加层(%d)" % overlays.size())
	get_tree().quit(0)



func _measure_stage(label: String) -> void:
	await get_tree().create_timer(1.5).timeout
	var wall: Array = []
	var proc: Array = []
	var last := Time.get_ticks_usec()
	var start := last
	while float(Time.get_ticks_usec() - start) / 1000000.0 < 8.0:
		await get_tree().process_frame
		var now := Time.get_ticks_usec()
		wall.append(float(now - last) / 1000.0)
		last = now
		proc.append(Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0)
	wall.sort(); proc.sort()
	var cnt := wall.size()
	print("[AISTRESS] === %s ===" % label)
	print("[AISTRESS] FPS=%.1f | frame p50=%.2f p95=%.2f | process p50=%.1f | draw=%d" % [
		float(cnt) / (float(Time.get_ticks_usec() - start) / 1000000.0), wall[cnt / 2], wall[int(cnt * 0.95)],
		proc[cnt / 2], Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)])