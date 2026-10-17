extends Node

## R23：300 单位下**按脚本聚合**的 _process 与 _physics_process 成本（非侵入 ✓）
const ROSTER := ["Tank", "APC", "HeavyTank", "Infantry", "Sniper"]
const K := 60
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
	print("[AGG] 节点总数=%d" % Performance.get_monitor(Performance.OBJECT_NODE_COUNT))
	await _agg("_physics_process", true)
	await _agg("_process", false)
	# 【GPT-6 纠正 #3】信号回调与点名函数也要单独聚合（原版漏掉 ✗）
	await _agg_method("_on_velocity_computed", 1.0 / 60.0, "CALLBACK_AGG")
	await _agg_method("_nearby_unit_stats", 1.0 / 60.0, "CALLBACK_AGG")
	await _agg_method("_update_recovery", 1.0 / 60.0, "CALLBACK_AGG")
	get_tree().quit(0)


func _agg(method: String, is_physics: bool) -> void:
	var delta: float = 1.0 / float(Engine.physics_ticks_per_second) if is_physics else 0.016
	var by_script: Dictionary = {}
	for n in _match.find_children("*", "", true, false):
		if not (n is Node):
			continue
		var node := n as Node
		if not node.has_method(method):
			continue
		var on := node.is_physics_processing() if is_physics else node.is_processing()
		if not on:
			continue
		var s: Script = node.get_script()
		var key: String = str(s.resource_path).get_file() if s != null else "（无脚本）"
		if not by_script.has(key):
			by_script[key] = []
		by_script[key].append(node)
	var rows: Array = []
	var total := 0.0
	for key in by_script.keys():
		var nodes: Array = by_script[key]
		for nd in nodes:
			if is_physics:
				(nd as Node).set_physics_process(false)
			else:
				(nd as Node).set_process(false)
		var t0 := Time.get_ticks_usec()
		for _c in range(K):
			for nd in nodes:
				(nd as Node).call(method, delta)
		var us := float(Time.get_ticks_usec() - t0) / float(K) / 1000.0
		for nd in nodes:
			if is_physics:
				(nd as Node).set_physics_process(true)
			else:
				(nd as Node).set_process(true)
		rows.append({"key": key, "cnt": nodes.size(), "ms": us})
		total += us
	rows.sort_custom(func(a, b): return float(a["ms"]) > float(b["ms"]))
	print("[AGG] === %s 合计 %.1f ms/帧（K=%d）===" % [method, total, K])
	for r in rows.slice(0, 10):
		print("[AGG]   %7.3f ms | ×%-4d | %s" % [float(r["ms"]), int(r["cnt"]), str(r["key"])])


## 通用方法聚合（按"每帧调用次数"折算 ✓ 只读 ✓）
func _agg_method(method: String, delta: float, tag: String) -> void:
	var by_script: Dictionary = {}
	for n in _match.find_children("*", "", true, false):
		if not (n is Node):
			continue
		var node := n as Node
		if not node.has_method(method):
			continue
		var s: Script = node.get_script()
		var key: String = str(s.resource_path).get_file() if s != null else "（无脚本）"
		if not by_script.has(key):
			by_script[key] = []
		by_script[key].append(node)
	if by_script.is_empty():
		print("[%s] %s：无节点提供该方法" % [tag, method])
		return
	var per := 30
	for key in by_script.keys():
		var nodes: Array = by_script[key]
		var t0 := Time.get_ticks_usec()
		for _c in range(per):
			for nd in nodes:
				(nd as Node).call(method, delta)
		var us := float(Time.get_ticks_usec() - t0) / float(per)
		print("[%s] %-26s ×%-4d ⇒ **%.3f ms/次全体调用**" % [tag, key + ":" + method, nodes.size(), us / 1000.0])
