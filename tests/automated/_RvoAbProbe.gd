extends Node

## R41：独立重启的 ON/OFF 对照（GPT-6 第 3/4 条）
## 单进程只跑一种模式（由 AIRTS_RVO_MODE 决定）⇒ 无同进程漂移 ✓
## OFF 模式仍按同契约提交期望运动（位置更新/推出/旋转/跟踪保留）✓
const ROSTER := ["Tank", "APC", "HeavyTank", "Infantry", "Sniper"]
const MARGIN := 26.0
const SPACING := 5.0
const COLS := 32
const SECONDS := 30.0
var _match: Node
var _n := 100
var _agents: Array = []
var _mode := "on"
var _commit_ok := 0
var _commit_fail := 0


func _process(_d: float) -> void:
	if get_tree().paused:
		get_tree().paused = false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_mode = OS.get_environment("AIRTS_RVO_MODE")
	if _mode == "":
		_mode = "on"
	var e := OS.get_environment("AIRTS_AI_ARMY")
	_n = int(e) if e != "" else 100
	var wd := Timer.new()
	wd.one_shot = true
	wd.wait_time = 600.0
	add_child(wd)
	wd.timeout.connect(func() -> void: print("[AB] WATCHDOG"); get_tree().quit(9))
	wd.start()
	print("[AB] 模式=" + _mode + " 规模=" + str(_n))
	await _run()


func _physics_process(_d: float) -> void:
	if _mode != "off":
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
		# _interim_speed 本身已是"每步位移"（Movement.gd 里 = speed*mult*delta）⇒ 不能再乘 delta ✗
		var step_len := float(a.get("_interim_speed"))
		var step: Vector3 = to_target / dist * step_len
		var mps := true
		if a.has_method("_flow_velocity_in_mps"):
			mps = bool(a.call("_flow_velocity_in_mps"))
		var arg: Vector3 = step / delta if mps else step
		var before: Vector3 = origin
		a.call("_on_velocity_computed", arg)
		if (unit as Node3D).global_transform.origin.distance_to(before) > 1.0e-6:
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
	for i in range(_n):
		var u = load("res://source/match/units/%s.tscn" % ROSTER[i % ROSTER.size()]).instantiate()
		_match._setup_and_spawn_unit(u, Transform3D(Basis(), Vector3(MARGIN + float(i % COLS) * SPACING, 0, MARGIN + float((i / COLS) % COLS) * SPACING)), ai)
	await get_tree().create_timer(5.0).timeout
	for u in get_tree().get_nodes_in_group("units"):
		var m = u.get_node_or_null("Movement")
		if m != null:
			_agents.append(m)
	var goals := [Vector3(150, 0, 40), Vector3(40, 0, 150), Vector3(150, 0, 150), Vector3(40, 0, 40)]
	for k in range(_agents.size()):
		_agents[k].move(goals[k % goals.size()])
	if _mode == "off":
		for a in _agents:
			a.set("avoidance_enabled", false)
	var p0: Array = []
	for a in _agents:
		p0.append((a.get("_unit") as Node3D).global_transform.origin)
	print("[AB] movers=" + str(_agents.size()) + " 节点=" + str(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)))
	# 统一预热 5 秒后开始 30 秒采样 ✓（固定模拟时刻 ✓）
	await get_tree().create_timer(5.0).timeout
	var wall: Array = []
	var last := Time.get_ticks_usec()
	var start := last
	var f0 := Engine.get_physics_frames()
	while float(Time.get_ticks_usec() - start) / 1000000.0 < SECONDS:
		await get_tree().process_frame
		var now := Time.get_ticks_usec()
		wall.append(float(now - last) / 1000.0)
		last = now
	var df := Engine.get_physics_frames() - f0
	var dw := float(Time.get_ticks_usec() - start) / 1000000.0
	var longf := 0
	for w in wall:
		if w > 500.0:
			longf += 1
	wall.sort()
	var c := wall.size()
	var moved := 0
	var total := 0.0
	for k in range(_agents.size()):
		if not is_instance_valid(_agents[k]):
			continue
		var dd: float = (_agents[k].get("_unit") as Node3D).global_transform.origin.distance_to(p0[k])
		total += dd
		if dd > 2.0:
			moved += 1
	var fps := float(c) / dw
	var sps := float(df) / dw
	print("[AB] 模式=" + _mode + " 样本=" + str(c) + " p50=" + str(wall[c / 2]) + " p95=" + str(wall[mini(c - 1, int(float(c) * 0.95))]) + " 最长=" + str(wall[c - 1]) + " 长帧>500ms=" + str(longf))
	print("[AB] 模式=" + _mode + " FPS=" + str(fps) + " 物理步每秒=" + str(sps) + " 移动过=" + str(moved) + "/" + str(_agents.size()) + " 平均位移=" + str(total / float(maxi(1, _agents.size()))) + "m 提交成功=" + str(_commit_ok) + " 失败=" + str(_commit_fail))
	get_tree().quit(0)
