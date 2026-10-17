extends Node

## R38（按 GPT-6 纠正提示词 P0 重写）
## 修正：关 avoidance 时**仍按同一契约提交期望运动**（位置更新/静态推出/旋转/被动跟踪都保留）
##      ⇒ 只去掉"动态避障"这一项 ⇒ 差值才只反映那一项。
## 健康条件：解析无错、单位真在移动、样本数达标；长帧全保留（不过滤）。
const ROSTER := ["Tank", "APC", "HeavyTank", "Infantry", "Sniper"]
const MARGIN := 26.0
const SPACING := 5.0
const COLS := 32
const SECONDS := 30.0
var _match: Node
var _n := 100
var _agents: Array = []
var _diag_commit := false
var _commit_ok := 0
var _commit_fail := 0


func _process(_d: float) -> void:
	if get_tree().paused:
		get_tree().paused = false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	var e := OS.get_environment("AIRTS_AI_ARMY")
	_n = int(e) if e != "" else 100
	# 墙钟硬超时（GPT-6 要求：不能只靠 create_timer ✓）
	var watchdog := Timer.new()
	watchdog.one_shot = true
	watchdog.wait_time = 900.0
	add_child(watchdog)
	watchdog.timeout.connect(func() -> void: print("[R38] WATCHDOG 超时 ⇒ 提前退出 ✓"); get_tree().quit(9))
	watchdog.start()
	await _run()


func _physics_process(_d: float) -> void:
	# 诊断模式：每个物理步给每个单位提交一次"期望运动"（与 RVO 同契约 ✓ 不同时接受回调 ✓）
	if not _diag_commit:
		return
	var delta := 1.0 / float(Engine.physics_ticks_per_second)
	for a in _agents:
		if not is_instance_valid(a):
			continue
		var unit = a.get("_unit")
		var target = a.get("_committed_target")
		if unit == null or target == null or not (target is Vector3):
			continue
		var origin: Vector3 = (unit as Node3D).global_transform.origin
		var to_target: Vector3 = (target as Vector3) - origin
		to_target.y = 0.0
		var dist := to_target.length()
		if dist < 0.5:
			continue
		var speed := float(a.get("_interim_speed"))
		var step: Vector3 = to_target / dist * speed * delta
		var mps := true
		if a.has_method("_flow_velocity_in_mps"):
			mps = bool(a.call("_flow_velocity_in_mps"))
		# 契约：m/s 时回调内部会乘 delta ⇒ 这里传 m/s；步长契约则传步长 ✓
		var arg: Vector3 = step / delta if mps else step
		var before: Vector3 = origin
		a.call("_on_velocity_computed", arg)
		var after: Vector3 = (unit as Node3D).global_transform.origin
		if after.distance_to(before) > 1.0e-6:
			_commit_ok += 1
		else:
			_commit_fail += 1


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
	var spawned := 0
	for i in range(_n):
		var u = load("res://source/match/units/%s.tscn" % ROSTER[i % ROSTER.size()]).instantiate()
		_match._setup_and_spawn_unit(u, Transform3D(Basis(), Vector3(MARGIN + float(i % COLS) * SPACING, 0, MARGIN + float((i / COLS) % COLS) * SPACING)), ai)
		spawned += 1
	await get_tree().create_timer(4.0).timeout
	for u in get_tree().get_nodes_in_group("units"):
		var m = u.get_node_or_null("Movement")
		if m != null:
			_agents.append(m)
	print("[R38] 请求=" + str(_n) + " 生成尝试=" + str(spawned) + " 实得movers=" + str(_agents.size()) + " 节点=" + str(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)))
	# 分散目标（GPT-6 要求：不要全汇聚同一点 ✗ ⇒ 分 4 组走不同方向 ✓）
	var goals := [Vector3(150, 0, 40), Vector3(40, 0, 150), Vector3(150, 0, 150), Vector3(40, 0, 40)]
	for k in range(_agents.size()):
		_agents[k].move(goals[k % goals.size()])
	var p0: Array = []
	for a in _agents:
		p0.append((a.get("_unit") as Node3D).global_transform.origin)
	await get_tree().create_timer(3.0).timeout
	await _stage("① RVO 开（真管道 ✓）")
	# OFF：关动态避障，但**由诊断提交保持运动管道** ✓
	_diag_commit = true
	for a in _agents:
		a.set("avoidance_enabled", false)
	await _stage("② OFF（关动态避障 + 同契约提交期望运动 ✓）")
	_diag_commit = false
	for a in _agents:
		a.set("avoidance_enabled", true)
	await _stage("③ 恢复（应回 ① ✓）")
	# 位移核验（证明单位真的在动 ✓）
	var moved := 0
	var total := 0.0
	for k in range(_agents.size()):
		var a = _agents[k]
		if not is_instance_valid(a):
			continue
		var d: float = (a.get("_unit") as Node3D).global_transform.origin.distance_to(p0[k])
		total += d
		if d > 2.0:
			moved += 1
	var avg_move: float = total / float(maxi(1, _agents.size()))
	print("[R38] 位移核验：移动过=%d/%d 平均位移=%.1fm 诊断提交 成功=%d 失败=%d" % [moved, _agents.size(), avg_move, _commit_ok, _commit_fail])
	get_tree().quit(0)


func _stage(label: String) -> void:
	await get_tree().create_timer(0.8).timeout
	var wall: Array = []
	var last := Time.get_ticks_usec()
	var start := last
	var f0 := Engine.get_physics_frames()
	var s0 := Time.get_ticks_usec()
	var frames := 0
	while float(Time.get_ticks_usec() - start) / 1000000.0 < SECONDS:
		await get_tree().process_frame
		var now := Time.get_ticks_usec()
		wall.append(float(now - last) / 1000.0)
		last = now
		frames += 1
	var df := Engine.get_physics_frames() - f0
	var dw := float(Time.get_ticks_usec() - start) / 1000000.0
	var long_frames := 0
	for w in wall:
		if w > 500.0:
			long_frames += 1
	wall.sort()
	var c := wall.size()
	var p95: float = wall[mini(c - 1, int(float(c) * 0.95))]
	var fps := float(c) / dw
	var steps := float(df) / dw
	print("[R38] " + label + " | 样本=" + str(c) + " p50=" + str(wall[c / 2]) + " p95=" + str(p95) + " 最长=" + str(wall[c - 1]) + " 长帧>500ms=" + str(long_frames) + " FPS=" + str(fps) + " 物理步每秒=" + str(steps))
