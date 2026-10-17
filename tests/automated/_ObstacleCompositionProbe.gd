extends Node

## R28：只读统计 —— 障碍组构成 + _push_out 每次成本（多档 ✓ 只读 ✓ 不改组 ✗）
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
		_match._setup_and_spawn_unit(u, Transform3D(Basis(), Vector3(85.0 + float(i % 20) * 2.4, 0, 85.0 + float((i / 20) % 20) * 2.4)), ai)
	await get_tree().create_timer(4.0).timeout
	# 只读：看看每个域组里到底有什么 ✓（绝不 remove/add ✗ 上轮因此挂起 ✓）
	for d in Constants.Match.Navigation.DOMAIN_TO_OBSTACLE_GROUP_MAPPING.keys():
		var gn: String = str(Constants.Match.Navigation.DOMAIN_TO_OBSTACLE_GROUP_MAPPING[d])
		var nodes: Array = get_tree().get_nodes_in_group(gn)
		var with_movement := 0
		var structures := 0
		for x in nodes:
			if (x as Node).get_node_or_null("Movement") != null:
				with_movement += 1
			elif (x as Node).get_node_or_null("CollisionShape3D") != null:
				structures += 1
		if nodes.size() > 0:
			print("[COMP] 域=%s 组=%s 规模=%d 其中带Movement(单位)=%d 带碰撞(建筑)=%d" % [str(d), gn, nodes.size(), with_movement, structures])
	# 单次 push 成本（关引擎驱动 ✓ 手动调用 ✓ 只读 ✓）
	var movers: Array = []
	for u in get_tree().get_nodes_in_group("units"):
		var m = u.get_node_or_null("Movement")
		if m != null:
			movers.append(m)
	print("[COMP] movers=%d" % movers.size())
	if movers.size() >= 10:
		var sample: Array = movers.slice(0, 10)
		for m in sample:
			m.stop()
			m.set_physics_process(false)
		await get_tree().physics_frame
		var t0 := Time.get_ticks_usec()
		for _c in range(K):
			for m in sample:
				m._push_out_of_static_obstacles(m.get("_unit").global_position, true)
		var per := float(Time.get_ticks_usec() - t0) / float(K) / float(sample.size())
		for m in sample:
			m.set_physics_process(true)
		var gname: String = str(Constants.Match.Navigation.DOMAIN_TO_OBSTACLE_GROUP_MAPPING.get(Constants.Match.Navigation.Domain.GROUND, ""))
		var gsize := get_tree().get_nodes_in_group(gname).size()
		print("[COMP] _push_out 每次=%.1f us | 地面组规模=%d ⇒ 每次访问≈%.2f us" % [per, gsize, (per / float(maxi(1, gsize)))])
		print("[COMP] 推算：%d 单位 × 8 步 × %.1f us = %.0f ms/帧" % [movers.size(), per, per * float(movers.size()) * 8.0 / 1000.0])
	get_tree().quit(0)
