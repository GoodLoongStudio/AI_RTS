extends Node

## 重坦炮弹速度口径（2026-10-10 用户要求：重型坦克炮弹速度 ×1.5）。
##
## 弹速的**唯一权威来源**是弹体场景根节点的 `metadata/flight_speed_mps`
## （`CannonShell.gd._ready` 读它算 `_flight_seconds = 发射距离 / 速度`）。
## 本测试同时验两件事：
##   ① 静态：四个弹体场景的 meta 与下方弹速总表逐一对齐；
##   ② 运行时：真实 Match 里对 15m 外地面强制攻击，读弹体**自己的** `_flight_seconds`
##      反推实测弹速，确认 meta 真的被权威发射路径吃进去（不是只改了场景文件）。
##
## 【2026-10-12 用户要求】除重型坦克外所有弹种弹速 ×2：炮弹 12→24、步枪曳光 45→90、
## 火箭 5.33→10.66；重坦 15 m/s 不动（慢榴弹是刻意手感），但命中判定范围对所有单位放大，
## 所以重坦的豁免只豁免速度，不豁免命中窗（溅射半径见 balance 的 tank_cannon_splash）。

const MatchSettings = preload("res://source/data-model/MatchSettings.gd")
const HeavyTankScene = preload("res://source/match/units/HeavyTank.tscn")

const HEAVY_SHELL_SCENE := "res://source/match/units/projectiles/HeavyCannonShell.tscn"
const TANK_SHELL_SCENE := "res://source/match/units/projectiles/CannonShell.tscn"

## 弹速总表：场景 → 应有 m/s（重坦是唯一被豁免的条目）。
const EXPECTED_SPEEDS := {
	"res://source/match/units/projectiles/CannonShell.tscn": 24.0,
	"res://source/match/units/projectiles/HeavyCannonShell.tscn": 15.0,
	"res://source/match/units/projectiles/RifleRound.tscn": 90.0,
	"res://source/match/units/projectiles/Rocket.tscn": 10.66,
}

const EXPECTED_HEAVY_SPEED := 15.0
const EXPECTED_TANK_SPEED := 24.0
const SHOT_DISTANCE := 15.0
const SPEED_TOLERANCE := 0.05

var _failures := 0
## 整局根节点：收尾必须回收，否则 Match 下的音乐/资源单位会命中回归 runner 的
## forbidden_output_patterns（ObjectDB / resources still in use / RID 泄漏）。
var _match: Node = null


func _check(cond: bool, msg: String) -> void:
	if cond:
		print("[PASS] " + msg)
	else:
		_failures += 1
		print("[FAIL] " + msg)


## 读弹体场景根节点的飞行速度 meta；缺失返回 -1。
func _scene_flight_speed(scene_path: String) -> float:
	var packed: PackedScene = load(scene_path)
	if packed == null:
		return -1.0
	var inst: Node = packed.instantiate()
	var value: Variant = inst.get_meta("flight_speed_mps", null)
	inst.free()
	if value == null:
		return -1.0
	return float(value)


func _ready():
	await get_tree().process_frame
	await get_tree().process_frame

	# ---- ① 静态口径：meta 是弹速唯一来源 ----
	var heavy_speed := _scene_flight_speed(HEAVY_SHELL_SCENE)
	var tank_speed := _scene_flight_speed(TANK_SHELL_SCENE)
	print("[INFO] meta flight_speed_mps: heavy=", heavy_speed, " tank=", tank_speed)
	for scene_path in EXPECTED_SPEEDS:
		var actual := _scene_flight_speed(scene_path)
		var expected := float(EXPECTED_SPEEDS[scene_path])
		_check(absf(actual - expected) <= 0.001,
			"弹速总表 %s 应为 %s m/s（实际 %s）"
				% [str(scene_path).get_file(), str(expected), str(actual)])
	_check(is_equal_approx(heavy_speed, EXPECTED_HEAVY_SPEED),
		"重坦炮弹飞行速度应为 %s m/s（实际 %s）" % [EXPECTED_HEAVY_SPEED, heavy_speed])
	_check(is_equal_approx(tank_speed, EXPECTED_TANK_SPEED),
		"坦克炮弹飞行速度应为 %s m/s（2026-10-12 起 ×2，实际 %s）"
			% [EXPECTED_TANK_SPEED, tank_speed])

	# ---- 真实 Match ----
	var settings = MatchSettings.new()
	var human = load("res://source/data-model/PlayerSettings.gd").new()
	human.controller = Constants.PlayerType.HUMAN
	human.color = Color.BLUE
	settings.players.append(human)
	var ai = load("res://source/data-model/PlayerSettings.gd").new()
	ai.controller = Constants.PlayerType.SIMPLE_CLAIRVOYANT_AI
	ai.color = Color.RED
	settings.players.append(ai)
	settings.visible_player = 0
	settings.visibility = MatchSettings.Visibility.PER_PLAYER

	var a_match = load("res://source/match/Match.tscn").instantiate()
	_match = a_match
	a_match.settings = settings
	a_match.map = load("res://source/match/maps/PlainAndSimple.tscn").instantiate()
	get_tree().root.add_child(a_match)

	var ready_deadline := Time.get_ticks_msec() + 90000
	var ready := false
	while Time.get_ticks_msec() < ready_deadline:
		await get_tree().physics_frame
		var players: Node = a_match.get_node_or_null("Players")
		if players != null and players.get_child_count() >= 2:
			var ok := true
			for p in players.get_children():
				if p.get_child_count() == 0:
					ok = false
			if ok:
				ready = true
				break
	_check(ready, "对局应就绪")
	if not ready:
		_finish()
		return

	var projectiles: Node = a_match.get_node_or_null("Projectiles")
	_check(projectiles != null, "应有 Projectiles 容器")
	if projectiles == null:
		_finish()
		return

	var players: Node = a_match.get_node("Players")
	var heavy = HeavyTankScene.instantiate()
	a_match._setup_and_spawn_unit(
		heavy, Transform3D(Basis.IDENTITY, Vector3(40.0, 0.0, 40.0)), players.get_child(0), false)
	await get_tree().physics_frame
	var target_pos: Vector3 = heavy.global_position + Vector3(SHOT_DISTANCE, 0.0, 0.0)
	_check(heavy.request_legacy_ground_force_attack(target_pos), "重坦应接受强制攻击地面指令")

	# ---- ② 运行时：等弹体出现，读它自己算出的飞行时长 ----
	var shell = null
	var appear_deadline := Time.get_ticks_msec() + 12000
	while Time.get_ticks_msec() < appear_deadline and shell == null:
		await get_tree().physics_frame
		for child in (projectiles as Node).get_children():
			if child is Node3D and str(child.scene_file_path) == HEAVY_SHELL_SCENE:
				shell = child
				break
	_check(shell != null, "应观察到飞行中的重坦炮弹")
	if shell == null:
		_finish()
		return

	var launch: Transform3D = shell.get("launch_transform")
	var aim: Vector3 = shell.get("_aim_point")
	var measured_seconds := float(shell.get("_flight_seconds"))
	var measured_distance := launch.origin.distance_to(aim) if aim.is_finite() else -1.0
	var measured_speed := measured_distance / measured_seconds if measured_seconds > 0.0 else -1.0
	print("[INFO] 实测：距离=%.2fm 飞行=%.3fs 反推弹速=%.2f m/s（meta=%s，落点=%.2f,%.2f,%.2f）" % [
		measured_distance, measured_seconds, measured_speed, heavy_speed,
		aim.x, aim.y, aim.z])

	# 等命中：弹体飞满后自毁（真正结算伤害的时刻）
	var impact_seen := false
	var impact_deadline := Time.get_ticks_msec() + 10000
	while Time.get_ticks_msec() < impact_deadline:
		await get_tree().physics_frame
		if not is_instance_valid(shell) or shell.is_queued_for_deletion():
			impact_seen = true
			break

	_check(measured_speed > 0.0, "应能读到弹体的飞行时长并反推弹速")
	_check(measured_distance > 5.0 and measured_distance < 25.0,
		"发射距离应落在 15m 射击的合理区间（实际 %.2f）" % measured_distance)
	if measured_speed > 0.0:
		var ratio := measured_speed / EXPECTED_HEAVY_SPEED
		_check(absf(ratio - 1.0) <= SPEED_TOLERANCE,
			"实测弹速应等于 %.1f m/s（实际 %.2f，比值 %.3f）"
				% [EXPECTED_HEAVY_SPEED, measured_speed, ratio])
	_check(impact_seen, "炮弹应在采样窗口内飞满并命中回收")
	_finish()


func _finish() -> void:
	print("Heavy tank shell speed: %d failure(s)" % _failures)
	# 走 SmokeTestExit：先回收整局 → 静音 → 退出。直接 quit() 会把 Match 留在树上，
	# 命中 ObjectDB / resources / RID 三条泄漏禁则（独立复核实测 43 实例 + 9 资源）。
	SmokeTestExit.request(get_tree(), 0 if _failures == 0 else 1, _match)
