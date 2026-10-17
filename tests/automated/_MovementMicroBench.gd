extends Node

## R8 微基准（非侵入 ✓）：手动调用 Movement._physics_process，量出每次真实成本 ✓
## 手法：先 set_physics_process(false) 关掉引擎驱动 ⇒ 再手动调用 ⇒ 不重复执行、不改游戏代码 ✓

const N_UNITS := 40
const K_CALLS := 400

var _match: Node


func _process(_d: float) -> void:
	if get_tree().paused:
		get_tree().paused = false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	get_tree().create_timer(240.0).timeout.connect(func() -> void: get_tree().quit(3))
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
	for _f in range(150):
		await get_tree().physics_frame
	# 造单位 ✓
	var player: Node = _match.get_node("Players").get_child(0)
	var tank := load("res://source/match/units/Tank.tscn")
	var made := 0
	for i in range(N_UNITS):
		var u = tank.instantiate()
		if _match._setup_and_spawn_unit(u, Transform3D(Basis(), Vector3(120 + (i % 8) * 3.0, 0, 120 + (i / 8) * 3.0)), player) != null:
			made += 1
	for _f in range(120):
		await get_tree().physics_frame
	var movers: Array = []
	for u in player.get_children():
		var m = u.get_node_or_null("Movement")
		if m != null:
			m.stop()
			movers.append(m)
	print("[MICRO] 单位构建=%d movers=%d" % [made, movers.size()])
	_check(movers.size() >= 10, "应有足够 mover（实际 %d）" % movers.size())
	# 关掉引擎驱动 ⇒ 手动计时 ✓（幂等：测完恢复 ✓）
	for m in movers:
		m.set_physics_process(false)
	var delta: float = 1.0 / float(Engine.physics_ticks_per_second)
	var per_mover: Array = []
	var t_start := Time.get_ticks_usec()
	for m in movers:
		var t0 := Time.get_ticks_usec()
		for k in range(K_CALLS):
			m._physics_process(delta)
		per_mover.append(float(Time.get_ticks_usec() - t0) / float(K_CALLS))
	var total_us := Time.get_ticks_usec() - t_start
	for m in movers:
		m.set_physics_process(true)
	per_mover.sort()
	var p50: float = per_mover[per_mover.size() / 2]
	var p95: float = per_mover[int(per_mover.size() * 0.95)]
	print("[MICRO] Movement._physics_process 每次调用: p50=%.1fus p95=%.1fus min=%.1f max=%.1f | 总 %.1fms / %d movers × %d calls" % [
		p50, p95, per_mover[0], per_mover[per_mover.size() - 1], float(total_us) / 1000.0, movers.size(), K_CALLS])
	print("[MICRO] 推算：%d movers × p50 ⇒ **%.2f ms/物理帧**" % [movers.size(), per_mover.size() * p50 / 1000.0])
	# 同样手法测空转：不调用任何东西的基线 ✓
	var t_empty := Time.get_ticks_usec()
	for k in range(K_CALLS * movers.size()):
		pass
	print("[MICRO] 循环空转基线 %.3fms" % (float(Time.get_ticks_usec() - t_empty) / 1000.0))
	get_tree().quit(0)


func _check(c: bool, m: String) -> void:
	if c: print("[MICRO] OK: " + m)
	else: push_error("[MICRO] FAIL: " + m)
