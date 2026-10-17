extends Node

## R9 微基准画像（非侵入 ✓）：按节点给 _physics_process 排序 ✓
## 手法：只挑 is_physics_processing()==true 的节点 ⇒ 关引擎驱动 ⇒ 手动调 K 次 ⇒ 计时 ⇒ 恢复 ✓

const K_CALLS := 200

var _match: Node


func _process(_d: float) -> void:
	if get_tree().paused:
		get_tree().paused = false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	get_tree().create_timer(300.0).timeout.connect(func() -> void: get_tree().quit(3))
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
	_match = load("res://source/match/Match.tscn").instantiate()
	_match.settings = settings
	_match.map = load("res://source/match/maps/PlainAndSimple.tscn").instantiate()
	add_child(_match)
	get_tree().current_scene = _match
	for _f in range(180):
		await get_tree().physics_frame
	# 让 AI 真正运转一段时间（含采矿/建造/索敌）✓
	for _f in range(600):
		await get_tree().physics_frame
	var delta: float = 1.0 / float(Engine.physics_ticks_per_second)
	# 收集真正在跑物理回调的节点 ✓
	var targets: Array = []
	for n in _match.find_children("*", "", true, false):
		if n is Node and (n as Node).is_physics_processing() and (n as Node).has_method("_physics_process"):
			targets.append(n)
	print("[PROFILE] 在跑物理回调的节点数=%d" % targets.size())
	# 按脚本（类）聚合 ✓
	var by_script: Dictionary = {}
	for n in targets:
		var s: Script = n.get_script()
		var key: String = str(s.resource_path).get_file() if s != null else "（无脚本）"
		if not by_script.has(key):
			by_script[key] = []
		by_script[key].append(n)
	# 逐个计时 ✓
	var rows: Array = []
	for key in by_script.keys():
		var nodes: Array = by_script[key]
		var sample: Node = nodes[0]
		var was: bool = sample.is_physics_processing()
		for n in nodes:
			n.set_physics_process(false)
		var t0 := Time.get_ticks_usec()
		for k in range(K_CALLS):
			for n in nodes:
				n._physics_process(delta)
		var us := float(Time.get_ticks_usec() - t0) / float(K_CALLS)
		for n in nodes:
			n.set_physics_process(was)
		rows.append({"script": key, "count": nodes.size(), "per_frame_ms": us / 1000.0})
	rows.sort_custom(func(a, b): return float(a["per_frame_ms"]) > float(b["per_frame_ms"]))
	var total := 0.0
	for r in rows:
		total += float(r["per_frame_ms"])
	print("[PROFILE] 合计脚本物理回调 ≈ %.2f ms/物理帧（K=%d ✓）" % [total, K_CALLS])
	for r in rows.slice(0, 18):
		print("[PROFILE]   %8.3f ms | ×%-3d | %s" % [float(r["per_frame_ms"]), int(r["count"]), str(r["script"])])
	get_tree().quit(0)
