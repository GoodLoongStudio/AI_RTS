extends Node

## R19：验证"生成单位"的正确姿势（夹具同款：add_child.call_deferred ✓ + ROSTER ✓ + get_local_player ✓）
const ROSTER := ["Infantry", "Tank", "APC", "Worker", "HeavyTank", "Sniper"]

var _match: Node


func _process(_d: float) -> void:
	if get_tree().paused:
		get_tree().paused = false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	get_tree().create_timer(200.0).timeout.connect(func() -> void: get_tree().quit(3))
	await _run()


func _run() -> void:
	var settings = load("res://source/data-model/MatchSettings.gd").new()
	var ps = load("res://source/data-model/PlayerSettings.gd").new()
	ps.controller = Constants.PlayerType.HUMAN
	ps.color = Constants.Player.COLORS[0]
	settings.players.append(ps)
	settings.visible_player = 0
	_match = load("res://source/match/Match.tscn").instantiate()
	_match.settings = settings
	_match.map = load("res://source/match/maps/PlainAndSimple.tscn").instantiate()
	# 【关键】夹具用的是 call_deferred ✓（我此前直接 add_child ✗）
	get_tree().root.add_child.call_deferred(_match)
	await get_tree().process_frame
	get_tree().current_scene = _match
	await get_tree().create_timer(5.0).timeout
	var human: Node = _match.get_local_player()
	print("[SPAWN2] human=%s" % str(human.name if human != null else "null"))
	var before := get_tree().get_nodes_in_group("units").size()
	for i in range(60):
		var u = load("res://source/match/units/%s.tscn" % ROSTER[i % ROSTER.size()]).instantiate()
		_match._setup_and_spawn_unit(u, Transform3D(Basis(), Vector3(65 + i % 8 * 6, 0, 65 + i / 8 * 6)), human)
	await get_tree().create_timer(3.0).timeout
	var after := get_tree().get_nodes_in_group("units").size()
	var movers := 0
	for u in get_tree().get_nodes_in_group("units"):
		if u.get_node_or_null("Movement") != null:
			movers += 1
	print("[SPAWN2] units 组 %d → %d（+%d）；其中 movers=%d" % [before, after, after - before, movers])
	if after - before >= 30:
		print("[SPAWN2] ✅ 生成成功 ⇒ 我的高负载探针从此可用 ✓")
	else:
		print("[SPAWN2] ✗ 仍未生成 ⇒ 还有别的差异")
	get_tree().quit(0)
