extends Node

## R27：实验 B —— 单位是否被"双重避让"（RVO 已在避让 + 静态推出又扫一遍）
## 手法：把单位**临时移出障碍组** ⇒ 推出循环只剩建筑 ⇒ 测帧时间 ⇒ 立刻恢复 ✓
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
		_match._setup_and_spawn_unit(u, Transform3D(Basis(), Vector3(85.0 + float(i % 20) * 2.4, 0, 85.0 + float((i / 20) % 20) * 2.4)), ai)
	await get_tree().create_timer(4.0).timeout
	var movers: Array = []
	for u in get_tree().get_nodes_in_group("units"):
		var m = u.get_node_or_null("Movement")
		if m != null:
			movers.append(m)
	for k in range(movers.size()):
		movers[k].move(Vector3(95.0 + float(k % 10) * 3.0, 0, 95.0))
	await get_tree().create_timer(4.0).timeout
	# 【修正】用**地面域** ✓（movers[0] 可能是空中单位 ✗ 上轮因此实验无效 ✓）
	var ground: int = Constants.Match.Navigation.Domain.GROUND
	var group_name: String = Constants.Match.Navigation.DOMAIN_TO_OBSTACLE_GROUP_MAPPING.get(ground, "")
	print("[DBL] 地面域=%s 组=%s 组内=%d" % [str(ground), group_name, get_tree().get_nodes_in_group(group_name).size()])
	# 打印所有域的组规模 ✓（看清 303 个障碍到底来自哪个组 ✓）
	for d in Constants.Match.Navigation.DOMAIN_TO_OBSTACLE_GROUP_MAPPING.keys():
		var gn: String = str(Constants.Match.Navigation.DOMAIN_TO_OBSTACLE_GROUP_MAPPING[d])
		print("[DBL]   域=%s 组=%s 规模=%d" % [str(d), gn, get_tree().get_nodes_in_group(gn).size()])
	var in_group := get_tree().get_nodes_in_group(group_name).size()
	print("[DBL] movers=%d" % movers.size())
	await _stage("① 基线（单位在障碍组里 ✓）")
	# 把单位临时移出障碍组 ✓（只读实验 ✓ 立刻恢复 ✓）
	var removed := 0
	for m in movers:
		var u = m.get("_unit")
		if u != null and (u as Node).is_in_group(group_name):
			(u as Node).remove_from_group(group_name)
			removed += 1
	print("[DBL] 已移出 %d 个；现在组内=%d" % [removed, get_tree().get_nodes_in_group(group_name).size()])
	await _stage("② 单位移出障碍组（只剩建筑）")
	# 恢复 ✓
	for m in movers:
		var u = m.get("_unit")
		if u != null and not (u as Node).is_in_group(group_name):
			(u as Node).add_to_group(group_name)
	print("[DBL] 已恢复；组内=%d" % get_tree().get_nodes_in_group(group_name).size())
	await _stage("③ 恢复（应回到 ① ✓）")
	get_tree().quit(0)


func _stage(label: String) -> void:
	await get_tree().create_timer(1.0).timeout
	var wall: Array = []
	var phys: Array = []
	var last := Time.get_ticks_usec()
	var start := last
	while float(Time.get_ticks_usec() - start) / 1000000.0 < SECONDS:
		await get_tree().process_frame
		var now := Time.get_ticks_usec()
		wall.append(float(now - last) / 1000.0)
		last = now
		phys.append(Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0)
	wall.sort(); phys.sort()
	var c := wall.size()
	print("[DBL] %s | FPS=%.1f frame p50=%.1f p95=%.1f | physics=%.1f" % [
		label, float(c) / (float(Time.get_ticks_usec() - start) / 1000000.0),
		wall[c / 2], wall[int(c * 0.95)], phys[c / 2]])
