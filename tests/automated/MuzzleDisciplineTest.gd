extends Node

## 炮口出膛 + 双管交替验证（2026-09-27 用户要求）：
##   ① 所有炮弹必须从**炮管挂点**（ProjectileOrigin / MuzzleL/MuzzleR）出膛，
##      不允许从车体/塔身中心冒出来；
##   ② 双管炮塔（AntiGroundTurret / MachineGunTurret）必须**左右交替**出膛；
##   ③ 重坦视野 = 10m（多兵种配合），射程 20m（比防御塔远）。
## 直接走 ProjectileRuntime.LaunchEntity（与各攻击 Action 同一权威入口），
## 弹体 _ready 把自己放在 launch_transform.origin 上 → 出膛点可精确断言。

const MatchSettings = preload("res://source/data-model/MatchSettings.gd")

## 武装单位：unitTypeId → 场景
const ARMED_UNITS := {
	"tank": "res://source/match/units/Tank.tscn",
	"heavy_tank": "res://source/match/units/HeavyTank.tscn",
	"soldier": "res://source/match/units/Infantry.tscn",
	"sniper": "res://source/match/units/Sniper.tscn",
	"rocketeer": "res://source/match/units/Rocketeer.tscn",
	"apc": "res://source/match/units/APC.tscn",
	"helicopter": "res://source/match/units/Helicopter.tscn",
	"anti_ground_turret": "res://source/match/units/AntiGroundTurret.tscn",
	"anti_air_turret": "res://source/match/units/AntiAirTurret.tscn",
	"machine_gun_turret": "res://source/match/units/MachineGunTurret.tscn",
}

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

	var players: Node = a_match.get_node("Players")
	var human_player = players.get_child(0)
	var catalog = a_match.get_node("BalanceConfigRuntime")
	var runtime = a_match.get_node("ProjectileRuntime")
	var projectiles: Node = a_match.get_node("Projectiles")

	# 远离 AI 基地的空地，避免自动交火干扰
	var base_pos := Vector3(40.0, 0.0, 40.0)
	var dummy_target := Node3D.new()
	a_match.add_child(dummy_target)
	dummy_target.global_position = base_pos + Vector3(6.0, 0.6, 0.0)

	# ---- ① 重坦视野 10 / 射程 20 ----
	var heavy = (load(ARMED_UNITS["heavy_tank"]) as PackedScene).instantiate()
	catalog.ConfigureUnit(heavy)
	var heavy_sight := float(heavy.get("sight_range"))
	var heavy_range := float(heavy.get("attack_range"))
	heavy.free()
	print("[INFO] heavy sight=", heavy_sight, " range=", heavy_range)
	_check(heavy_sight == 10.0, "重坦视野应为 10m（多兵种配合；实际 %s）" % heavy_sight)
	_check(heavy_range == 20.0, "重坦射程应保持 20m（实际 %s）" % heavy_range)

	# ---- ② 全兵种：出膛点必须落在炮管挂点上 ----
	for type_id in ARMED_UNITS:
		var scene: PackedScene = load(ARMED_UNITS[type_id])
		var unit: Node3D = scene.instantiate()
		catalog.ConfigureUnit(unit)
		a_match._setup_and_spawn_unit(
			unit, Transform3D(Basis.IDENTITY, base_pos), human_player, false)
		await get_tree().physics_frame
		var muzzles := _muzzle_nodes(unit)
		_check(muzzles.size() > 0, "%s 应有炮管挂点（ProjectileOrigin 或 MuzzleL/R）" % type_id)
		# 记录发射前 Projectiles 子节点，发射后按 attack_id 精确找出本发弹体
		# （容器里可能同时有前几发的爆炸/仍在飞的弹，数增量会认错节点）
		var attack_id: String = runtime.LaunchEntity(unit, dummy_target, false)
		_check(not attack_id.is_empty(), "%s 应能发射" % type_id)
		# 不等帧：AddChild 时 _ready 已同步把弹体放到出膛点；
		# 等 1 帧弹体就飞出 ~0.3m（12m/s × 帧时长），双管间距才 0.3-0.5m，会判反
		var shell: Node3D = _shell_by_attack_id(projectiles, attack_id)
		_check(shell != null, "%s 应有可见弹体" % type_id)
		if shell != null and muzzles.size() > 0:
			var rocket_path := shell.find_child("Path3D", true, false) as Path3D
			var exit_pos: Vector3
			if rocket_path != null:
				# 火箭根节点钉在原点、弹体沿世界坐标 Path3D 走——轨迹起点即出膛点
				exit_pos = rocket_path.curve.get_point_position(0)
			else:
				exit_pos = shell.global_position
			var best := 1.0e9
			var best_name := ""
			for m in muzzles:
				var d: float = exit_pos.distance_to((m as Node3D).global_position)
				if d < best:
					best = d
					best_name = (m as Node).name
			print("[INFO] %s exit=%s nearest_muzzle=%s dist=%.3f" % [
				type_id, exit_pos, best_name, best])
			_check(best <= 0.35,
				"%s 炮弹应从炮管挂点出膛（距最近挂点 %.3fm）" % [type_id, best])
		if is_instance_valid(unit) and not unit.is_queued_for_deletion():
			unit.queue_free()
		await get_tree().process_frame

	# ---- ③ 双管交替：AntiGroundTurret 连开三发，L→R→L ----
	for turret_type in ["anti_ground_turret", "machine_gun_turret"]:
		var turret: Node3D = (load(ARMED_UNITS[turret_type]) as PackedScene).instantiate()
		catalog.ConfigureUnit(turret)
		a_match._setup_and_spawn_unit(
			turret, Transform3D(Basis.IDENTITY, base_pos + Vector3(0, 0, 6.0)),
			human_player, false)
		await get_tree().physics_frame
		var muzzles := _muzzle_nodes(turret)
		var left: Node3D = null
		var right: Node3D = null
		for m in muzzles:
			if String((m as Node).name).begins_with("MuzzleL"):
				left = m
			elif String((m as Node).name).begins_with("MuzzleR"):
				right = m
		_check(left != null and right != null,
			"%s 应有 MuzzleL 与 MuzzleR 两根炮管" % turret_type)
		if left == null or right == null:
			continue
		var sequence: Array = []
		for shot in range(3):
			var id: String = runtime.LaunchEntity(turret, dummy_target, false)
			# 同上：立即采样，别等帧（等 1 帧弹体位移会盖过管间距）
			var shell := _shell_by_attack_id(projectiles, id)
			if shell != null:
				var p: Vector3 = shell.global_position
				var dl: float = p.distance_to(left.global_position)
				var dr: float = p.distance_to(right.global_position)
				sequence.append("L" if dl < dr else "R")
				_check(minf(dl, dr) <= 0.35,
					"%s 第 %d 发应从某根炮管出膛（最近 %.3fm）" % [
						turret_type, shot + 1, minf(dl, dr)])
		var expected := ["L", "R", "L"]
		print("[INFO] %s 交替序列 = %s" % [turret_type, sequence])
		_check(sequence == expected,
			"%s 应左右交替 L→R→L（实际 %s）" % [turret_type, sequence])
		turret.queue_free()
		await get_tree().process_frame

	_finish()


## 单位的全部炮管挂点：MuzzleL/MuzzleR（双管）优先，否则 ProjectileOrigin。
func _muzzle_nodes(unit: Node) -> Array:
	var out: Array = []
	var left: Node = unit.find_child("MuzzleL", true, false)
	var right: Node = unit.find_child("MuzzleR", true, false)
	if left != null and right != null:
		out.append(left)
		out.append(right)
		return out
	var origin: Node = unit.find_child("ProjectileOrigin", true, false)
	if origin != null:
		out.append(origin)
	return out


## 按 attack_id 在 Projectiles 容器里精确找本发弹体
## （CannonShell/Rocket 的脚本都在 _ready 读 attack_id 属性）。
func _shell_by_attack_id(projectiles: Node, attack_id: String) -> Node3D:
	for child in projectiles.get_children():
		if child is Node3D and str((child as Node).get("attack_id")) == attack_id:
			return child
	return null


func _finish() -> void:
	if _failures == 0:
		print("Muzzle discipline: 0 failure(s)")
		get_tree().quit(0)
	else:
		print("Muzzle discipline: %d failure(s)" % _failures)
		get_tree().quit(1)
