extends Node

## R11b：**移动中**的 Movement 微基准（非侵入 ✓）—— R8 只测了停住的单位 ✗
const K_CALLS := 300

var _match: Node


func _process(_d: float) -> void:
	if get_tree().paused:
		get_tree().paused = false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	get_tree().create_timer(280.0).timeout.connect(func() -> void: get_tree().quit(3))
	await _run()


func _run() -> void:
	var settings = load("res://source/data-model/MatchSettings.gd").new()
	var human = load("res://source/data-model/PlayerSettings.gd").new()
	human.controller = Constants.PlayerType.HUMAN
	human.color = Constants.Player.COLORS[0]
	settings.players.append(human)
	settings.visible_player = 0
	_match = load("res://source/match/Match.tscn").instantiate()
	_match.settings = settings
	_match.map = load("res://source/match/maps/PlainAndSimple.tscn").instantiate()
	add_child(_match)
	get_tree().current_scene = _match
	for _f in range(160):
		await get_tree().physics_frame
	var player: Node = _match.get_node("Players").get_child(0)
	var movers: Array = []
	for u in player.get_children():
		var m = u.get_node_or_null("Movement")
		if m != null:
			movers.append(m)
	print("[MOVBENCH] movers=%d" % movers.size())
	var delta: float = 1.0 / float(Engine.physics_ticks_per_second)
	# ① 停住状态 ✓
	for m in movers:
		m.stop()
	for _f in range(30):
		await get_tree().physics_frame
	var idle_us := await _bench(movers, delta)
	# ② 移动状态 ✓（各给不同目标 ✓）
	for i in range(movers.size()):
		movers[i].move(Vector3(90 + (i % 8) * 5.0, 0, 90 + (i / 8) * 5.0))
	for _f in range(60):
		await get_tree().physics_frame
	var move_us := await _bench(movers, delta)
	# ③ 拥挤移动：全部挤向同一点 ✓
	for m in movers:
		m.move(Vector3(110, 0, 110))
	for _f in range(120):
		await get_tree().physics_frame
	var crowd_us := await _bench(movers, delta)
	print("[MOVBENCH] 每次 _physics_process： idle=%.1fus  moving=%.1fus  crowd=%.1fus" % [idle_us, move_us, crowd_us])
	print("[MOVBENCH] 推算 %d movers ⇒ idle=%.2fms moving=%.2fms crowd=%.2fms /物理帧" % [
		movers.size(), movers.size() * idle_us / 1000.0, movers.size() * move_us / 1000.0, movers.size() * crowd_us / 1000.0])
	get_tree().quit(0)


func _bench(movers: Array, delta: float) -> float:
	for m in movers:
		m.set_physics_process(false)
	var t0 := Time.get_ticks_usec()
	for k in range(K_CALLS):
		for m in movers:
			m._physics_process(delta)
	var us := float(Time.get_ticks_usec() - t0) / float(K_CALLS) / float(maxi(1, movers.size()))
	for m in movers:
		m.set_physics_process(true)
	return us
