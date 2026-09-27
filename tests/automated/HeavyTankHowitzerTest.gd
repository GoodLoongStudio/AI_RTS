extends Node

## 重坦榴弹验证（2026-09-27 用户要求）：
##   ① 射程：heavy_tank_cannon = 20m > 全部防御塔（16/16/14）
##   ② 弹道：HeavyCannonShell 走真抛物线——爬升过峰（明显高于出膛高度）再落地
## 用真实 Match + 真实 BalanceConfigRuntime 配置单位，请求强制攻击地面后
## 逐帧采样 Projectiles 容器里弹体的 Y。

const MatchSettings = preload("res://source/data-model/MatchSettings.gd")
const HeavyTankScene = preload("res://source/match/units/HeavyTank.tscn")

var _failures := 0


func _check(cond: bool, msg: String) -> void:
	if cond:
		print("[PASS] " + msg)
	else:
		_failures += 1
		print("[FAIL] " + msg)


func _ready():
	await get_tree().process_frame
	await get_tree().process_frame

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
	a_match.settings = settings
	a_match.map = load("res://source/match/maps/PlainAndSimple.tscn").instantiate()
	get_tree().root.add_child(a_match)

	var deadline := Time.get_ticks_msec() + 90000
	var ready := false
	while Time.get_ticks_msec() < deadline:
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

	# ---- ① 射程口径：重坦 20 > 防御塔 16/16/14 ----
	var catalog = a_match.get_node("BalanceConfigRuntime")
	var turret_scenes := {
		"anti_ground_turret": load("res://source/match/units/AntiGroundTurret.tscn"),
		"machine_gun_turret": load("res://source/match/units/MachineGunTurret.tscn"),
		"anti_air_turret": load("res://source/match/units/AntiAirTurret.tscn"),
	}
	var heavy_range := -1.0
	var turret_ranges := {}
	# ConfigureUnit 把主武器射程写在单位的 attack_range（GDScript 镜像）
	var read_range := func(node) -> float:
		var value: Variant = node.get("attack_range")
		return -1.0 if value == null else float(value)

	for name in turret_scenes:
		var node = turret_scenes[name].instantiate()
		catalog.ConfigureUnit(node)
		turret_ranges[name] = read_range.call(node)
		node.free()
	var heavy = HeavyTankScene.instantiate()
	catalog.ConfigureUnit(heavy)
	heavy_range = read_range.call(heavy)
	var heavy_sight := float(heavy.get("sight_range"))
	heavy.free()
	print("[INFO] heavy range=", heavy_range, " sight=", heavy_sight,
		" turret_ranges=", turret_ranges)
	_check(heavy_range == 20.0, "重坦炮射程应为 20m（实际 %s）" % heavy_range)
	# 【2026-09-27 用户改口径】视野 10m（多兵种配合，小于射程是设计意图：
	# 20m 的炮需要队友点亮目标），不再断言"视野 ≥ 射程"。
	_check(heavy_sight == 10.0, "重坦视野应为 10m（实际 %s）" % heavy_sight)
	for name in turret_ranges:
		_check(heavy_range > float(turret_ranges[name]),
			"重坦射程应比 %s 远（%s > %s）" % [name, heavy_range, turret_ranges[name]])

	# ---- ② 实弹抛物线：强制攻击 15m 外地面点，采样弹体 Y ----
	var players: Node = a_match.get_node("Players")
	var human_player = players.get_child(0)
	heavy = HeavyTankScene.instantiate()
	a_match._setup_and_spawn_unit(
		heavy, Transform3D(Basis.IDENTITY, Vector3(40.0, 0.0, 40.0)), human_player, false)
	await get_tree().physics_frame
	var start_pos: Vector3 = heavy.global_position
	var target_pos := start_pos + Vector3(15.0, 0.0, 0.0)
	var requested: bool = heavy.request_legacy_ground_force_attack(target_pos)
	_check(requested, "重坦应接受强制攻击地面指令")
	if not requested:
		_finish()
		return

	var projectiles: Node = a_match.get_node_or_null("Projectiles")
	_check(projectiles != null, "应有 Projectiles 容器")
	var launch_y := -1.0
	var peak_y := -1000.0
	var saw_shell := false
	var sample_deadline := Time.get_ticks_msec() + 6000
	while Time.get_ticks_msec() < sample_deadline:
		await get_tree().process_frame
		for child in (projectiles as Node).get_children():
			if child is Node3D and not (child as Node3D).is_queued_for_deletion():
				var p: Vector3 = (child as Node3D).global_position
				if launch_y < 0.0:
					launch_y = p.y
					saw_shell = true
				peak_y = maxf(peak_y, p.y)
		if saw_shell and (projectiles as Node).get_child_count() == 0:
			break
	print("[INFO] shell launch_y=", launch_y, " peak_y=", peak_y,
		" rise=", peak_y - maxf(launch_y, 0.0))
	_check(saw_shell, "应观察到飞行中的重坦炮弹")
	# 峰值必须明显高于出膛高度（抛物线爬升），且高于目标地面（落点在上方越过）
	_check(peak_y - maxf(launch_y, 0.0) >= 1.2,
		"弹道应爬升过峰（峰值高出膛 ≥1.2m，实际 %.2f）——真抛物线" % (peak_y - maxf(launch_y, 0.0)))
	_finish()


func _finish() -> void:
	if _failures == 0:
		print("Heavy tank howitzer: 0 failure(s)")
		get_tree().quit(0)
	else:
		print("Heavy tank howitzer: %d failure(s)" % _failures)
		get_tree().quit(1)
