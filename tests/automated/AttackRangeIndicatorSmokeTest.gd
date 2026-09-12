extends Node

## 攻击范围圈冒烟测试（2026-09-12 用户要求："点击炮塔和单位要显示其攻击范围"）。
##
## 覆盖：
## - 选中炮塔/坦克 → 出现**半径等于 attack_range** 的范围圈；
## - 取消选中、以及 deselect_all_units → 圈消失；
## - 无武器单位（Worker，C# 侧把 attack_range 写成 Nil）→ 选中也不出现圈。

const MatchScene = preload("res://tests/manual/TestAllUnits.tscn")
const SmokeTestWarmup = preload("res://tests/automated/SmokeTestWarmup.gd")
const AntiGroundTurretScene = preload("res://source/match/units/AntiGroundTurret.tscn")
const TankScene = preload("res://source/match/units/Tank.tscn")
const WorkerScene = preload("res://source/match/units/Worker.tscn")

var _failures := 0
var _finished := false


func _ready():
	# 看门狗：任何 await 卡死都在 90 秒后以失败收尾，避免 CI 永久挂起。
	get_tree().create_timer(90.0).timeout.connect(_on_failsafe)
	var match_instance = MatchScene.instantiate()
	add_child(match_instance)
	await get_tree().process_frame
	# 开局阶段 `units` 组与导航都还在异步就绪，必须等（见 SmokeTestWarmup 的说明）。
	await SmokeTestWarmup.wait_for_units(get_tree(), 1, 2)

	var human = match_instance.get_node("Players/Human")
	_check(human != null, "应能取到本地 Human 玩家")
	if human == null:
		_finish()
		return

	# 即时（mark_structure_under_construction=false）生成，避免炮塔处于施工中。
	var turret = _spawn(human, AntiGroundTurretScene, Vector3(6, 0, 12))
	var tank = _spawn(human, TankScene, Vector3(9, 0, 12))
	var worker = _spawn(human, WorkerScene, Vector3(12, 0, 12))
	# 等 BalanceConfigRuntime 把武器射程写进节点：它没到位的话下面所有断言都失去意义。
	await _wait_for_attack_range(turret)
	await _wait_for_attack_range(tank)

	_check(turret.get("attack_range") != null, "炮塔应拿到 attack_range（来自武器射程）")
	_check(tank.get("attack_range") != null, "坦克应拿到 attack_range（来自武器射程）")
	_check(worker.get("attack_range") == null, "Worker 没有武器，attack_range 应为空")

	var turret_selection = turret.find_child("Selection")
	var turret_indicator = _indicator(turret)
	_check(turret_selection != null, "炮塔应有 Selection 子节点")
	_check(turret_indicator != null, "炮塔的 Selection 应带 AttackRangeIndicator 子节点")
	if turret_selection == null or turret_indicator == null:
		_finish()
		return

	# 1) 选中炮塔 → 显示范围圈，半径等于 attack_range。
	turret_selection.select()
	await get_tree().process_frame
	_check(turret_indicator.is_range_visible(), "选中炮塔后应显示攻击范围圈")
	_check(
		is_equal_approx(turret_indicator.get_range_radius(), float(turret.get("attack_range"))),
		"炮塔范围圈半径应等于 attack_range（实际 %s vs %s）"
		% [turret_indicator.get_range_radius(), turret.get("attack_range")]
	)

	# 2) 取消选中 → 圈消失。
	turret_selection.deselect()
	await get_tree().process_frame
	_check(not turret_indicator.is_range_visible(), "取消选中后炮塔范围圈应消失")

	# 3) 坦克：选中同样显示（说明不是只对建筑生效）。
	var tank_selection = tank.find_child("Selection")
	var tank_indicator = _indicator(tank)
	tank_selection.select()
	await get_tree().process_frame
	_check(tank_indicator != null and tank_indicator.is_range_visible(), "选中坦克后应显示攻击范围圈")
	_check(
		tank_indicator != null and is_equal_approx(
			tank_indicator.get_range_radius(), float(tank.get("attack_range"))
		),
		"坦克范围圈半径应等于 attack_range"
	)

	# 4) Worker：无武器 → 选中也不显示。
	var worker_selection = worker.find_child("Selection")
	var worker_indicator = _indicator(worker)
	_check(worker_indicator != null, "Worker 也带 AttackRangeIndicator（只是永不显示）")
	worker_selection.select()
	await get_tree().process_frame
	_check(
		worker_indicator != null and not worker_indicator.is_range_visible(),
		"Worker 没有武器，选中不应显示范围圈"
	)

	# 5) 全选取消信号（框选清空、ESC 等都会走它）→ 圈消失。
	MatchSignals.deselect_all_units.emit()
	await get_tree().process_frame
	_check(tank_indicator != null and not tank_indicator.is_range_visible(), "deselect_all_units 后坦克范围圈应消失")

	_finish()


## 生成一个归属指定玩家、且**已完工**的单位。
func _spawn(player, scene, position):
	var unit = scene.instantiate()
	MatchSignals.setup_and_spawn_unit.emit(
		unit, Transform3D(Basis.IDENTITY, position), player, false
	)
	return unit


## 等单位的 attack_range 被 C# 写入（最多 8 秒），返回是否等到。
func _wait_for_attack_range(unit) -> bool:
	var waited := 0.0
	while waited < 8.0:
		if unit == null or not is_instance_valid(unit):
			return false
		if unit.get("attack_range") != null:
			return true
		await get_tree().create_timer(0.1).timeout
		waited += 0.1
	return false


## 取单位身上的攻击范围圈节点（Selection → AttackRangeIndicator）。
func _indicator(unit):
	if unit == null or not is_instance_valid(unit):
		return null
	var selection = unit.find_child("Selection")
	return null if selection == null else selection.find_child("AttackRangeIndicator")


func _on_failsafe():
	if _finished:
		return
	_finished = true
	_failures += 1
	print("FAIL: 看门狗超时——测试协程中断未收尾")
	print("Attack range indicator smoke test completed: %d failure(s)" % _failures)
	SmokeTestExit.request(get_tree(), 1)


func _finish():
	if _finished:
		return
	_finished = true
	print("Attack range indicator smoke test completed: %d failure(s)" % _failures)
	SmokeTestExit.request(get_tree(), 0 if _failures == 0 else 1)


func _check(condition: bool, message: String):
	if condition:
		return
	_failures += 1
	print("FAIL: %s" % message)
	push_error("Attack range indicator smoke test assertion failed: %s" % message)
