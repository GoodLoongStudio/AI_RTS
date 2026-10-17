extends Node

## AI 建造行为实测（用户报告：建筑贴得很紧 + 不造矿场）
## 真实 Match（人 + 简单 AI）✓，跑固定时长后统计：AI 的建筑数量、最近邻间距、矿场数量 ✓。

const RUN_SECONDS := 150.0
const OUT := "res://agent/runs/2026-10-07-ai-build-behavior/ai-build.json"

var _m: Node
var _frames := 0


func _process(_delta: float) -> void:
	if get_tree().paused:
		get_tree().paused = false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	get_tree().create_timer(600.0).timeout.connect(func() -> void:
		push_error("[AIBUILD] 超时")
		_finish(2))
	await _run()


func _run() -> void:
	var settings = load("res://source/data-model/MatchSettings.gd").new()
	var human = load("res://source/data-model/PlayerSettings.gd").new()
	human.controller = Constants.PlayerType.HUMAN
	human.color = Constants.Player.COLORS[0]
	settings.players.append(human)
	var ai = load("res://source/data-model/PlayerSettings.gd").new()
	ai.controller = Constants.PlayerType.AI_EASY
	ai.color = Constants.Player.COLORS[1]
	ai.spawn_index_offset = 1
	settings.players.append(ai)
	settings.visible_player = 0
	_m = load("res://source/match/Match.tscn").instantiate()
	_m.settings = settings
	_m.map = load("res://source/match/maps/PlainAndSimple.tscn").instantiate()
	add_child(_m)
	get_tree().current_scene = _m
	for _f in range(180):
		await get_tree().physics_frame
	var players: Array = _m.get_node("Players").get_children()
	# 【修正】players[1] 是**空占位** ✗ ⇒ 真正的 AI 是含 ConstructionWorksController 的那个 ✓
	var ai_player: Node = null
	for pl in players:
		if pl.get_node_or_null("ConstructionWorksController") != null or pl.get_node_or_null("EconomyController") != null:
			ai_player = pl
			break
	_check(ai_player != null, "必须存在 AI 玩家")
	# 【诊断】打印双方玩家的直接子节点，确认 AI 到底有没有建筑 ✓
	for pi in range(players.size()):
		var pl: Node = players[pi]
		var names: Array = []
		for ch in pl.get_children():
			names.append(str(ch.name))
		print("[AIBUILD] 玩家%d '%s' 子节点(%d): %s" % [pi, pl.name, names.size(), ", ".join(names).substr(0, 200)])
	var t0 := Time.get_ticks_msec()
	while float(Time.get_ticks_msec() - t0) / 1000.0 < RUN_SECONDS:
		await get_tree().physics_frame
		_frames += 1
	# 统计 AI 的建筑 ✓
	var rows: Array = []
	if ai_player != null:
		# 【修正】建筑不在 AI 玩家的直接子节点下 ✗ ⇒ 递归整棵子树找"有 MovementObstacle 且无 Movement"的节点 ✓
		# （MovementObstacle 只挂在建筑/静态障碍上；单位另有 Movement ✓）
		var known := {}
		for n in ai_player.find_children("*", "Node3D", true, false):
			var n3 := n as Node3D
			if n3 == null or known.has(n3.get_instance_id()):
				continue
			if n3.get_node_or_null("MovementObstacle") == null:
				continue
			if n3.get_node_or_null("Movement") != null:
				continue
			known[n3.get_instance_id()] = true
			rows.append({"name": str(n3.name), "x": n3.global_position.x, "z": n3.global_position.z})
	var refineries := 0
	for r in rows:
		if str(r["name"]).to_lower().contains("refinery") or str(r["name"]).contains("矿"):
			refineries += 1
	# 最近邻间距 ✓
	var min_gap := 1.0e9
	for i in range(rows.size()):
		for j in range(i + 1, rows.size()):
			var d := Vector2(float(rows[i]["x"]) - float(rows[j]["x"]), float(rows[i]["z"]) - float(rows[j]["z"])).length()
			min_gap = minf(min_gap, d)
	print("[AIBUILD] 时长=%.0fs AI 建筑数=%d 矿场=%d 最近邻间距=%.2fm" % [RUN_SECONDS, rows.size(), refineries, (0.0 if min_gap > 1.0e8 else min_gap)])
	for r in rows:
		print("[AIBUILD]   %s @ (%.1f, %.1f)" % [r["name"], float(r["x"]), float(r["z"])])
	_check(rows.size() >= 3, "AI 应当建造若干建筑（实际 %d）" % rows.size())
	_check(refineries >= 1, "AI 应当建造**矿场**（实际 %d）" % refineries)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://agent/runs/2026-10-07-ai-build-behavior/"))
	var f := FileAccess.open(ProjectSettings.globalize_path(OUT), FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify({"run_seconds": RUN_SECONDS, "ai_structures": rows, "refineries": refineries,
			"min_neighbor_gap_m": (0.0 if min_gap > 1.0e8 else min_gap), "frames": _frames}, "  "))
		f.close()
	_finish(0)


func _check(cond: bool, msg: String) -> void:
	if cond: print("[AIBUILD] OK: " + msg)
	else: push_error("[AIBUILD] FAIL: " + msg)


func _finish(code: int) -> void:
	print("AI build behavior probe completed")
	get_tree().quit(code)
