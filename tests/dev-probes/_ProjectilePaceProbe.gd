extends Node

## 弹速实测探针（2026-10-12，"除重坦外所有弹种 ×2 + 命中判定范围放大"验收用）。
##
## 为什么单独写：弹速的场景 meta 是唯一权威，但"改了 tscn 却没被权威发射路径吃进去"这类假绿
## 只有真局实测才能排除。本探针在真实 Match 里让四种单位各开一枪，抓到自己那发弹体，
## 用弹体**内部算出的飞行时长**（CannonShell 的 `_flight_seconds`，或 Rocket 由
## `speed_scale = 动画长度 / 时长` 反解）除以实际发射距离，得到实测 m/s。
##
## 同时打印命中判定窗的三个来源，便于对账：直击容差（代码里的 WarheadDamageResolver 常数，
## 因为 schema 禁止 IntendedTargetOnly 弹头带半径）与两种溅射半径（balance）。

const MatchSettings = preload("res://source/data-model/MatchSettings.gd")
const TankScene = preload("res://source/match/units/Tank.tscn")
const HeavyTankScene = preload("res://source/match/units/HeavyTank.tscn")
const SniperScene = preload("res://source/match/units/Sniper.tscn")
const RocketeerScene = preload("res://source/match/units/Rocketeer.tscn")
const ShellExplosionScript = preload("res://source/match/units/projectiles/ShellExplosion.gd")
const ShellExplosionScene = preload("res://source/match/units/projectiles/ShellExplosion.tscn")

## 单位 → [标签, 单位场景, 期望弹体场景, 期望弹速 m/s, 开火距离 m, 应否出现落点特效]
const ROSTER := [
	["Tank", TankScene, "CannonShell.tscn", 24.0, 10.0, true],
	["HeavyTank", HeavyTankScene, "HeavyCannonShell.tscn", 15.0, 10.0, true],
	["Sniper", SniperScene, "RifleRound.tscn", 90.0, 10.0, false],
	["Rocketeer", RocketeerScene, "Rocket.tscn", 10.66, 10.0, true],
]

const SHELL_DIR := Vector3(1.0, 0.0, 0.0)

var _match: Node = null


func _ready():
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

	_match = load("res://source/match/Match.tscn").instantiate()
	_match.settings = settings
	_match.map = load("res://source/match/maps/PlainAndSimple.tscn").instantiate()
	get_tree().root.add_child(_match)

	var ready := false
	var deadline := Time.get_ticks_msec() + 90000
	while Time.get_ticks_msec() < deadline and not ready:
		await get_tree().physics_frame
		var players: Node = _match.get_node_or_null("Players")
		ready = players != null and players.get_child_count() >= 2 \
			and players.get_child(0).get_child_count() > 0
	_check(ready, "对局应就绪")
	if not ready:
		_finish()
		return

	var projectiles: Node = _match.get_node("Projectiles")
	var owner_player: Node = _match.get_node("Players").get_child(0)
	var index := 0
	for entry in ROSTER:
		var label: String = entry[0]
		var unit_scene: PackedScene = entry[1]
		var want_shell: String = entry[2]
		var expected_speed: float = entry[3]
		var shot_distance: float = entry[4]
		var want_explosion: bool = entry[5]
		# 每个单位换一处空地，避免上一发的弹体混进这一轮的容器扫描。
		var spawn := Vector3(30.0 + 25.0 * (index % 2), 0.0, 30.0 + 25.0 * int(index / 2))
		# 先等上一发的落点特效散场（自毁 1.8s）：特效和弹体是兄弟节点，
		# 不清场就会把上一轮的爆炸认领成本轮的（2026-10-12 实测踩到）。
		await _wait_explosions_cleared(projectiles, 3.0)
		var unit = unit_scene.instantiate()
		_match._setup_and_spawn_unit(unit, Transform3D(Basis.IDENTITY, spawn), owner_player, false)
		await get_tree().physics_frame
		var aim: Vector3 = spawn + SHELL_DIR * shot_distance
		# 上一发的弹体可能还在飞：先记下容器里的既有节点，本轮只认新增的。
		var before := {}
		for existing in projectiles.get_children():
			before[existing.get_instance_id()] = true
		if unit.has_method("request_legacy_ground_force_attack"):
			_check(unit.request_legacy_ground_force_attack(aim), "%s 应接受对地强制攻击" % label)
		var shell = await _await_shell(projectiles, want_shell, before, 12.0)
		if shell == null:
			_check(false, "%s 应观察到 %s 弹体" % [label, want_shell])
			index += 1
			continue
		var flight := _flight_seconds_of(shell)
		var launch = shell.get("launch_transform")
		var shell_aim = shell.get("_aim_point")
		var measured_distance := shot_distance
		if launch is Transform3D and shell_aim is Vector3 and (shell_aim as Vector3).is_finite():
			measured_distance = (launch as Transform3D).origin.distance_to(shell_aim)
		var meta_speed := float(shell.get_meta("flight_speed_mps", -1.0))
		var measured_speed := measured_distance / flight if flight > 0.0 else -1.0
		_info("%s shell=%s dist=%.2fm flight=%.3fs meta=%s ⇒ 实测 %.2f m/s（期望 %.2f）" % [
			label, want_shell, measured_distance, flight, str(meta_speed),
			measured_speed, expected_speed])
		_check(absf(meta_speed - expected_speed) <= 0.01,
			"%s 的场景 flight_speed_mps 应为 %.2f（实际 %s）" % [label, expected_speed, str(meta_speed)])
		if flight > 0.0:
			_check(absf(measured_speed - expected_speed) <= expected_speed * 0.10,
				"%s 实测弹速应 ≈%.2f m/s（实际 %.2f，容差 10%%）"
					% [label, expected_speed, measured_speed])
		if want_explosion:
			await _measure_explosion(projectiles, shell, label)
		else:
			_info("%s 无落点特效（直射弹种 impact_explosion=false，预期内）" % label)
		index += 1

	await _measure_no_friendly_collateral(owner_player)
	_print_hit_windows()
	_finish()


func _has_explosion(projectiles: Node) -> bool:
	for child in projectiles.get_children():
		if str(child.scene_file_path).ends_with("ShellExplosion.tscn"):
			return true
	return false


## 等上一发的特效散场（它自毁要 1.8s），否则会把别人的尺寸认领成本轮的。
func _wait_explosions_cleared(projectiles: Node, max_seconds: float):
	var deadline := Time.get_ticks_msec() + int(max_seconds * 1000.0)
	while Time.get_ticks_msec() < deadline and _has_explosion(projectiles):
		await get_tree().physics_frame


## 等这一发弹体命中自毁后抓它刚落地的特效，核对"权威判定半径 → 特效尺寸"这条链真的自适应。
func _measure_explosion(projectiles: Node, shell, label: String):
	var gone_deadline := Time.get_ticks_msec() + 6000
	while Time.get_ticks_msec() < gone_deadline:
		if shell == null or not is_instance_valid(shell):
			break
		await get_tree().physics_frame
	var seen := {}
	for existing in projectiles.get_children():
		seen[existing.get_instance_id()] = true
	var deadline := Time.get_ticks_msec() + 3000
	while Time.get_ticks_msec() < deadline:
		await get_tree().physics_frame
		for child in projectiles.get_children():
			if seen.has(child.get_instance_id()):
				continue
			if not str(child.scene_file_path).ends_with("ShellExplosion.tscn"):
				continue
			var radius := float(child.get_meta("blast_radius_m", -1.0))
			# 期望值直接调特效自己的静态映射函数，绝不在探针里重抄一遍公式。
			var expected_spread := ShellExplosionScript.spread_scale_for(radius)
			var expected_puff := ShellExplosionScript.puff_scale_for(radius)
			var pristine = ShellExplosionScene.instantiate()
			var base_mat: ParticleProcessMaterial = pristine.get_child(0).process_material
			var live_mat: ParticleProcessMaterial = child.get_child(0).process_material
			var pristine_child_name: String = str(pristine.get_child(0).name)
			var puff_ratio := live_mat.scale_max / base_mat.scale_max \
				if base_mat.scale_max > 0.0 else -1.0
			pristine.free()
			_info("%s 落点特效：blast_radius_m=%.2f 散开=%.3f（期望 %.3f）火花=%.3f（期望 %.3f，%s）" % [
				label, radius, child.scale.x, expected_spread, puff_ratio, expected_puff,
				pristine_child_name])
			_check(radius > 0.0, "%s 的落点特效应带上正判定半径" % label)
			_check(absf(child.scale.x - expected_spread) <= 0.01,
				"%s 散开尺寸应 = 判定半径 ÷ 参考档（实际 %.3f vs %.3f）" % [
					label, child.scale.x, expected_spread])
			_check(child.scale.x <= 1.0 + 0.001,
				"%s 特效不得放大到原美术尺寸以上（实际 %.3f）" % [label, child.scale.x])
			_check(absf(puff_ratio - expected_puff) <= 0.02,
				"%s 火花尺寸应只按平方根长（比值 %.3f vs 期望 %.3f）" % [
					label, puff_ratio, expected_puff])
			return
	_check(false, "%s 应观察到落点特效" % label)


## 友军零误伤的正反例：爆点 3m 处放一个自己人（溅射窗 = 半径 + footprint ≈ 7m），
## 同时放一个敌人作**正向对照**——没有正向对照的"没掉血"可能只是什么都没发生。
## 旧口径（area 弹头友伤倍率 0.5）下自己人必掉 1.75 血，新口径（0.0）必须一点不掉。
func _measure_no_friendly_collateral(owner_player: Node):
	var map_node = _match.get_node_or_null("Map")
	var map_size = map_node.get("size") if map_node != null else null
	var center := Vector3(60.0, 0.0, 60.0)
	if map_size is Vector2:
		center = Vector3(float(map_size.x) * 0.72, 0.0, float(map_size.y) * 0.45)
	var shooter = TankScene.instantiate()
	_match._setup_and_spawn_unit(shooter,
		Transform3D(Basis.IDENTITY, center - SHELL_DIR * 10.0), owner_player, false)
	await get_tree().physics_frame
	var bystander = TankScene.instantiate()
	_match._setup_and_spawn_unit(bystander,
		Transform3D(Basis.IDENTITY, center + Vector3(0.0, 0.0, 3.0)), owner_player, false)
	await get_tree().physics_frame
	# 正向对照：敌人就站在爆点上，属于另一个玩家（AI）。
	var enemy_player: Node = _match.get_node("Players").get_child(1)
	var victim = TankScene.instantiate()
	_match._setup_and_spawn_unit(victim,
		Transform3D(Basis.IDENTITY, center), enemy_player, false)
	await get_tree().physics_frame
	if not is_instance_valid(bystander) or not is_instance_valid(shooter) \
			or not is_instance_valid(victim):
		_check(false, "友伤反例需要射手、己方旁观单位与敌方对照单位都在场")
		return
	var gateway = owner_player.get_node_or_null("UnitCommandGateway")
	if gateway != null:
		# 让敌方对照单位还手会污染血量判据（既有冒烟同款做法）。
		gateway.SetFirePolicy([victim], "HoldFire", enemy_player)
	# 血量抬到 100：坦克 10 血会被 3~4 发连续命中打死，节点一释放就读不到 hp 了
	# （2026-10-12 踩过：脚本错误让后面三条断言静默没跑，结论仍是 0 failure 的假绿）。
	victim.hp = 100.0
	bystander.hp = 100.0
	await get_tree().physics_frame
	var before := float(bystander.hp)
	var victim_before := float(victim.hp)
	var shooter_before := float(shooter.hp)
	_check(bool(shooter.request_legacy_ground_force_attack(center)), "友伤反例：应接受对地强制攻击")
	await get_tree().create_timer(3.0).timeout
	_check(is_instance_valid(bystander) and is_instance_valid(victim),
		"3 秒后对照单位与己方旁观单位都应还在场（否则血量判据无从谈起）")
	var after := float(bystander.hp) if is_instance_valid(bystander) else -1.0
	var victim_after := float(victim.hp) if is_instance_valid(victim) else -1.0
	var shooter_after := float(shooter.hp) if is_instance_valid(shooter) else -1.0
	_info("爆点 3.0m 的己方旁观单位 hp %.2f → %.2f；爆点上的敌方对照 hp %.2f → %.2f；射手 %.2f → %.2f" % [
		before, after, victim_before, victim_after, shooter_before, shooter_after])
	_check(victim_after < victim_before,
		"正向对照必须掉血，否则说明这一发根本没结算（实际 %.2f → %.2f）" % [victim_before, victim_after])
	_check(after == before,
		"溅射不得误伤友军（3m 内自己人 hp 必须不变，实际 %.2f → %.2f）" % [before, after])
	_check(shooter_after == shooter_before, "射手自身也不应被自己的弹头伤到")


## 命中判定窗的三个权威：代码容差 + balance 两种溅射半径。
func _print_hit_windows():
	var text := FileAccess.get_file_as_string("res://config/balance/demo.balance.v1.json")
	if text.is_empty():
		_info("读不到 balance，命中窗未打印")
		return
	var parsed = JSON.parse_string(text)
	for warhead in parsed.get("warheads", []):
		_info("warhead %s mode=%s radiusMeters=%s" % [
			str(warhead.get("id")), str(warhead.get("impactSelectionMode")),
			str(warhead.get("radiusMeters"))])
	# 直击命中窗 = 弹头半径(0) + 目标碰撞半径 + WarheadDamageResolver.DirectHitToleranceMeters(2.0)
	_info("直击窗 = 0 + 目标 radius + 2.0m 容差；单位 radius 见各场景（如 Tank radius≈2.02）")


## 弹体自身算出的飞行时长：CannonShell 用成员，Rocket 由 speed_scale 反解。
func _flight_seconds_of(shell) -> float:
	var stored = shell.get("_flight_seconds")
	if stored != null and float(stored) > 0.0:
		return float(stored)
	var player: AnimationPlayer = shell.find_child("AnimationPlayer", true, false) \
		if shell is Node else null
	if player == null:
		return -1.0
	var animation: Animation = player.get_animation("animate")
	if animation == null or animation.length <= 0.0 or player.speed_scale <= 0.0:
		return -1.0
	return animation.length / player.speed_scale


func _await_shell(projectiles: Node, shell_file: String, before: Dictionary, max_seconds: float):
	var deadline := Time.get_ticks_msec() + int(max_seconds * 1000.0)
	while Time.get_ticks_msec() < deadline:
		await get_tree().physics_frame
		for child in projectiles.get_children():
			if before.has(child.get_instance_id()):
				continue
			if child is Node3D and str(child.scene_file_path).ends_with(shell_file):
				return child
	return null


var _failures := 0


func _check(cond: bool, msg: String) -> void:
	if cond:
		print("[PASS] " + msg)
	else:
		_failures += 1
		print("[FAIL] " + msg)


func _info(msg: String) -> void:
	print("[SHL] " + msg)


func _finish() -> void:
	print("Projectile pace probe: %d failure(s)" % _failures)
	# 走 SmokeTestExit：先回收整局再退出，避免 Match 残树命中回归 runner 的泄漏禁则。
	SmokeTestExit.request(get_tree(), 0 if _failures == 0 else 1, _match)
