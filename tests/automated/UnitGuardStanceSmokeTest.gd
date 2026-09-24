extends Node

const SmokeTestWarmup = preload("res://tests/automated/SmokeTestWarmup.gd")

const MatchScene = preload("res://tests/manual/TestOneUnit.tscn")
const CommandCenterScene = preload("res://source/match/units/CommandCenter.tscn")
const Player = preload("res://source/match/players/Player.gd")
const WaitingForTargets = preload("res://source/match/units/actions/WaitingForTargets.gd")

## 归途判定阈值，与 `WaitingForTargets._try_returning_to_guard_anchor()` 同口径。
const GUARD_ARRIVED_RADIUS_M := 0.5
## 场景 3 的"追出上限"距离：3× 视野，回走到 1.5× 视野要 1.5× 视野的路程，
## 足够长的窗口验证"超上限期间不接新战"。
const BEYOND_CAP_FACTOR := 3.0
## 场景 3 的观察窗口：必须短于"走回 1.5× 视野"所需时间，否则单位回到可接战
## 半径后接战是正确行为，会误判。
const NO_NEW_FIGHT_WINDOW_S := 2.0

var _failures := 0


func _ready():
	var match_instance = MatchScene.instantiate()
	add_child(match_instance)
	await SmokeTestWarmup.wait_for_units(get_tree(), 1)

	var human = match_instance.get_node("Players/Human")
	var tank = human.get_node("Tank")
	var gateway = human.get_node("UnitCommandGateway")
	var enemy_player = _add_enemy_player(match_instance)

	gateway.SetEngagementStance([tank], "Guard", human)
	await get_tree().create_timer(0.3).timeout
	var guard_anchor: Vector3 = gateway.GetGuardAnchor(tank)
	_check(guard_anchor.is_finite(), "警戒姿态应记录岗位点")
	var sight: float = tank.sight_range

	# ---- 场景 1：敌人进入本单位视野 → 主动跑过去攻击 ----
	# 敌方指挥中心带武器会还击，每幕之间回满血，避免测试单位中途阵亡。
	var intruder = _add_enemy_unit(enemy_player, guard_anchor + Vector3(0.0, 0.0, -2.0))
	var intruder_hit: bool = await _wait_for_hp_below(intruder, intruder.hp, 5.0)
	_check(intruder_hit, "警戒：敌人进入本单位视野应主动接战并开火")
	_check(not _is_idle(tank), "警戒：接战中单位不应处于空闲待命")
	intruder.queue_free()
	await _settle(tank)

	# ---- 场景 2：归途中敌人进视野 → 打断归途接战 ----
	# 旧代码在启程回家时摘掉了轮询计时器，单位整段归途对贴着它的敌人毫无反应，
	# 一路走回岗位点白挨打（用户 2026-09-22 报的"警戒模式 BUG 冲突"）。
	var displaced: Vector3 = guard_anchor + Vector3(0.0, 0.0, sight * 1.2)
	tank.global_position = displaced
	var returning: bool = await _wait_for(5.0, func(): return not _is_idle(tank))
	_check(returning, "警戒：离开岗位且无敌情时应启程回岗位点")
	_check(
		_distance_to_anchor(tank, guard_anchor) > GUARD_ARRIVED_RADIUS_M,
		"警戒：启程回岗位点时单位应仍在岗位外"
	)
	var ambusher = _add_enemy_unit(enemy_player, tank.global_position + Vector3(0.0, 0.0, -2.0))
	var ambusher_hit: bool = await _wait_for_hp_below(ambusher, ambusher.hp, 5.0)
	_check(ambusher_hit, "警戒：归途中敌人进视野应打断归途并接战开火")
	ambusher.queue_free()
	await _settle(tank)

	# ---- 场景 3：追出岗位上限 → 不接新战，先回岗位点 ----
	# 收手与"不再接新战"必须同源（同一个 GUARD_MAX_CHASE_FACTOR）：只收手不禁接，
	# 单位会在上限边界上"收手→眼前又有人→再追"反复抽搐，永远回不了岗位点。
	tank.global_position = guard_anchor + Vector3(0.0, 0.0, sight * BEYOND_CAP_FACTOR)
	var returning_again: bool = await _wait_for(5.0, func(): return not _is_idle(tank))
	_check(returning_again, "警戒：追出岗位上限后应返回岗位点")
	var beyond_cap_enemy = _add_enemy_unit(
		enemy_player, tank.global_position + Vector3(0.0, 0.0, -2.0)
	)
	var no_new_fight: bool = not await _wait_for_hp_below(
		beyond_cap_enemy, beyond_cap_enemy.hp, NO_NEW_FIGHT_WINDOW_S
	)
	_check(no_new_fight, "警戒：追出岗位上限期间不应接视野内的新目标")
	var closing_in: bool = await _wait_for(
		2.0,
		func():
			return _distance_to_anchor(tank, guard_anchor) < sight * BEYOND_CAP_FACTOR - 1.0
	)
	_check(closing_in, "警戒：追出上限后应持续向岗位点移动")
	beyond_cap_enemy.queue_free()

	print("Unit guard stance smoke test completed: %d failure(s)" % _failures)
	match_instance.queue_free()
	await get_tree().process_frame
	SmokeTestExit.request(get_tree(), 0 if _failures == 0 else 1)


func _add_enemy_player(match_instance):
	var enemy_player := Node3D.new()
	enemy_player.name = "GuardStanceEnemy"
	enemy_player.set_script(Player)
	enemy_player.color = Color.RED
	enemy_player.add_to_group("players")
	match_instance.get_node("Players").add_child(enemy_player)
	return enemy_player


func _add_enemy_unit(enemy_player, position: Vector3):
	var enemy = CommandCenterScene.instantiate()
	enemy.name = "GuardStanceTarget"
	enemy.position = position
	enemy.add_to_group("units")
	enemy.add_to_group("adversary_units")
	enemy_player.add_child(enemy)
	return enemy


## 单位到岗位点的平面距离（与 `WaitingForTargets` 归途判据同口径：忽略高度）。
func _distance_to_anchor(unit, anchor: Vector3) -> float:
	return unit.global_position_yless.distance_to(anchor * Vector3(1.0, 0.0, 1.0))


func _is_idle(unit) -> bool:
	var action = unit.action
	return action == null or (action is WaitingForTargets and action.is_idle())


## 等当前交火收尾（回到空闲待命）并回满血：敌方指挥中心带武器会还击，
## 不补血的话测试单位撑不完三幕。
func _settle(unit):
	var elapsed_seconds := 0.0
	while elapsed_seconds < 10.0:
		if _is_idle(unit):
			break
		await get_tree().create_timer(0.1).timeout
		elapsed_seconds += 0.1
	if is_instance_valid(unit) and unit.hp != null and unit.hp_max != null:
		unit.hp = unit.hp_max


func _check(condition: bool, message: String):
	if condition:
		return
	_failures += 1
	push_error("Unit guard stance assertion failed: %s" % message)


func _wait_for(timeout_seconds: float, predicate: Callable) -> bool:
	var elapsed_seconds := 0.0
	while elapsed_seconds < timeout_seconds:
		if predicate.call():
			return true
		await get_tree().create_timer(0.1).timeout
		elapsed_seconds += 0.1
	return predicate.call()


func _wait_for_hp_below(unit, previous_hp: float, timeout_seconds: float) -> bool:
	return await _wait_for(
		timeout_seconds, func(): return not is_instance_valid(unit) or unit.hp < previous_hp
	)
