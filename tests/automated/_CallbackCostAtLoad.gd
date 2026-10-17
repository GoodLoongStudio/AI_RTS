extends Node

## R15：高负载下量"回调机制"（非侵入 ✓）
## 修 R14 探针错误：用 units **组**收集（夹具同款 ✓），而不是 player.get_children() ✗
const K_CALLS := 150
var _match: Node
var _cb_hits := 0


func _process(_d: float) -> void:
	if get_tree().paused:
		get_tree().paused = false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	get_tree().create_timer(420.0).timeout.connect(func() -> void: get_tree().quit(3))
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
	await get_tree().create_timer(5.0).timeout
	for _f in range(40):
		await get_tree().physics_frame
	var human_player: Node = _match.get_local_player()
	for i in range(8):
		var b = load("res://source/match/units/VehicleFactory.tscn").instantiate()
		_match._setup_and_spawn_unit(b, Transform3D(Basis(), Vector3(50 + (i % 3) * 18, 0, 45 + (i / 3) * 18)), human_player)
		b.apply_authoritative_construction_work(1, 1)
		b.complete_authoritative_construction()
	print("[CB] 车厂已尝试 8 个，等生产 25s …")
	await get_tree().create_timer(25.0).timeout
	# 【修正】用 units 组 ✓（夹具同款 ✓）
	var all_units: Array = get_tree().get_nodes_in_group("units")
	var movers: Array = []
	for u in all_units:
		var m = u.get_node_or_null("Movement")
		if m != null:
			movers.append(m)
	print("[CB] units 组=%d ÷ 其中 movers=%d" % [all_units.size(), movers.size()])
	if movers.size() < 5:
		print("[CB] movers 太少，无法给出高负载结论 ✗")
		get_tree().quit(0)
		return
	# 统计一次物理帧里 velocity_computed 的触发次数（额外监听 ✓ 只计数 ✓ 不改行为 ✓）
	var counter := func(_v: Vector3) -> void: _cb_hits += 1
	var hooked: Array = []
	for m in movers:
		if m.has_signal("velocity_computed"):
			m.velocity_computed.connect(counter)
			hooked.append(m)
	# 让它们动起来 ✓
	for k in range(movers.size()):
		movers[k].move(Vector3(90 + (k % 12) * 5.0, 0, 90 + (k / 12) * 5.0))
	for _f in range(60):
		await get_tree().physics_frame
	_cb_hits = 0
	var f0 := Engine.get_physics_frames()
	var t_frames := Time.get_ticks_usec()
	for _f in range(30):
		await get_tree().physics_frame
	var df := Engine.get_physics_frames() - f0
	var dt := float(Time.get_ticks_usec() - t_frames) / 1000000.0
	print("[CB] 30 物理帧里 velocity_computed 触发 %d 次 ⇒ **%.1f 次/物理帧**（movers=%d，%.1f 次/帧/单位）" % [
		_cb_hits, float(_cb_hits) / float(maxi(1, df)), movers.size(), float(_cb_hits) / float(maxi(1, df)) / float(movers.size())])
	# 关引擎驱动 ⇒ 手动计时回调本体 ✓
	var sample: Array = movers.slice(0, mini(20, movers.size()))
	for m in sample:
		m.set_physics_process(false)
	var delta: float = 1.0 / float(Engine.physics_ticks_per_second)
	var t0 := Time.get_ticks_usec()
	for k in range(K_CALLS):
		for m in sample:
			m._physics_process(delta)
	var proc_us := float(Time.get_ticks_usec() - t0) / float(K_CALLS) / float(sample.size())
	var t1 := Time.get_ticks_usec()
	for k in range(K_CALLS):
		for m in sample:
			m._on_velocity_computed(Vector3(0.1, 0, 0.1))
	var cb_us := float(Time.get_ticks_usec() - t1) / float(K_CALLS) / float(sample.size())
	for m in sample:
		m.set_physics_process(true)
	for m in hooked:
		if m.velocity_computed.is_connected(counter):
			m.velocity_computed.disconnect(counter)
	print("[CB] 每次耗时：_physics_process=%.1f us | _on_velocity_computed=%.1f us（样本 %d，K=%d）" % [proc_us, cb_us, sample.size(), K_CALLS])
	print("[CB] 推算全队 %d movers：_physics_process=%.1f ms/帧 | 回调本体=%.1f ms/帧" % [
		movers.size(), proc_us * float(movers.size()) / 1000.0, cb_us * float(movers.size()) / 1000.0])
	get_tree().quit(0)
