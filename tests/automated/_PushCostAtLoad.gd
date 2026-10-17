extends Node

## R14：高负载下量 push 路径（非侵入 ✓）—— 验证 O(n²) 推断 ✓
const K_CALLS := 200
var _match: Node


func _process(_d: float) -> void:
	if get_tree().paused:
		get_tree().paused = false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	get_tree().create_timer(360.0).timeout.connect(func() -> void: get_tree().quit(3))
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
	var player: Node = _match.get_local_player()
	# 照夹具：造 8 个车厂并完工 ⇒ 由它们生产 ✓
	# 【修正】夹具**不检查返回值** ✓（返回 null 也可能是成功 ✗ 我判错了 ✓）
	var made := 0
	for i in range(8):
		var b = load("res://source/match/units/VehicleFactory.tscn").instantiate()
		_match._setup_and_spawn_unit(b, Transform3D(Basis(), Vector3(50 + (i % 3) * 18, 0, 45 + (i / 3) * 18)), player)
		b.apply_authoritative_construction_work(1, 1)
		b.complete_authoritative_construction()
		made += 1
	print("[PUSH2] 尝试造车厂=%d" % made)
	await get_tree().create_timer(25.0).timeout
	var movers: Array = []
	for u in player.get_children():
		var m = u.get_node_or_null("Movement")
		if m != null:
			movers.append(m)
	# 障碍组大小 ✓（push 内部用的就是这个组 ✓）
	var mover: Node = movers[0]
	var domain: int = mover.get("domain")
	var group_name: String = Constants.Match.Navigation.DOMAIN_TO_OBSTACLE_GROUP_MAPPING.get(domain, "")
	var group: Array = get_tree().get_nodes_in_group(group_name)
	print("[PUSH2] 域=%s 障碍组名=%s 组内节点=%d movers=%d" % [str(domain), group_name, group.size(), movers.size()])
	var delta: float = 1.0 / float(Engine.physics_ticks_per_second)
	for m in movers:
		m.stop()
	for _f in range(20):
		await get_tree().physics_frame
	# 关引擎驱动 ⇒ 手动计时 push ✓（含"全部障碍"的真实迭代 ✓）
	var sample: Array = movers.slice(0, mini(12, movers.size()))
	for m in sample:
		m.set_physics_process(false)
	var t0 := Time.get_ticks_usec()
	for k in range(K_CALLS):
		for m in sample:
			m._push_out_of_static_obstacles(m._unit.global_position, true)
	var per_call := float(Time.get_ticks_usec() - t0) / float(K_CALLS) / float(sample.size())
	for m in sample:
		m.set_physics_process(true)
	print("[PUSH2] _push_out 每次 = %.1f us（样本 %d 个 mover，K=%d）" % [per_call, sample.size(), K_CALLS])
	print("[PUSH2] 推算全队 %d movers ⇒ %.1f ms/物理帧（若每帧都调一次 ✓）" % [movers.size(), per_call * float(movers.size()) / 1000.0])
	get_tree().quit(0)
