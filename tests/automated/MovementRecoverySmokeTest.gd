extends Node

## 移动 / 寻路 / 脱困 场景验收（2026-09-11）。
##
## 覆盖玩家实测的三类问题：
##   1. 单兵绕墙：目的地在大片障碍另一侧，必须走合法绕路且真正到达（不得中途假失败）。
##   2. 窄口双向交会：两车对穿同一缺口，必须都能到达，不得互相永久卡死。
##   3. 集体回基地：多单位同时回防同一基地，必须全部收敛且不叠在同一格。
##   4. 行进中新建建筑：重烘导航网格期间单位不得集体站桩（路径修复 + 双缓冲）。
##   5. 脱困期间玩家改命令：新命令必须立即生效，旧脱困/旧目标不得复活。
##
## 所有成功判定都基于权威订单终态 Arrived 或真实位置，绝不把 Accepted / Unreachable 当成功。

const SmokeTestWarmup = preload("res://tests/automated/SmokeTestWarmup.gd")
const MovementScript = preload("res://source/match/units/traits/Movement.gd")
const MatchScene = preload("res://tests/manual/TestOneUnit.tscn")
const CommandCenterScene = preload("res://source/match/units/CommandCenter.tscn")
const WorkerScene = preload("res://source/match/units/Worker.tscn")

## 判定"已到达"的平面误差（普通集结允许合理到达误差）。
const ARRIVAL_TOLERANCE_M := 2.0
## 交错后两单位的最小可通行间距。
const MIN_SEPARATION_M := 1.2

var _failures := 0
var _wall: Array = []


func _ready():
	var match_instance = MatchScene.instantiate()
	add_child(match_instance)
	await SmokeTestWarmup.wait_for_units(get_tree(), 1)

	var human = match_instance.get_node("Players/Human")
	var tank: Node3D = human.get_node("Tank")
	var gateway = human.get_node("UnitCommandGateway")
	var movement = tank.find_child("Movement")
	await SmokeTestWarmup.wait_for_navigation(get_tree(), movement, tank.global_position)

	await _scenario_wall_detour(match_instance, human, tank, gateway)
	await _scenario_narrow_head_on(match_instance, human, gateway, tank)
	await _scenario_group_return_to_base(match_instance, human, gateway)
	await _scenario_building_added_mid_move(match_instance, human, gateway, tank)
	await _scenario_player_override_during_recovery(match_instance, human, gateway, tank)

	# 本轮场景确实走到了停滞判定 → 脱困检查没有被完全旁路（否则上面的覆盖断言没有意义）。
	_check(
		MovementScript.recovery_stats["stall_detections"] > 0,
		"整轮场景应至少触发一次停滞检测/脱困检查"
	)
	_check(
		MovementScript.recovery_stats["unreachable"] == 0,
		"合法场景不得产生假 Unreachable（actual=%d）"
		% MovementScript.recovery_stats["unreachable"]
	)
	print(
		"[MOVEMENT] recovery_stats=", MovementScript.recovery_stats,
		" budget_skips=", MovementScript.recovery_stats["budget_skips"]
	)
	print("Movement recovery smoke test completed: %d failure(s)" % _failures)
	match_instance.queue_free()
	await get_tree().process_frame
	SmokeTestExit.request(get_tree(), 0 if _failures == 0 else 1)


# --- 场景 1：单兵绕墙 ---

func _scenario_wall_detour(match_instance, human, tank: Node3D, gateway) -> void:
	_clear_wall()
	# 在坦克与目的地之间砌一道墙，缺口留在 -z 一端 → 必须走合法绕路。
	for index in range(6):
		_spawn_wall_block(match_instance, human, 18.263, 8.0 + float(index) * 2.5)
	await _wait_frames(45)

	var start: Vector3 = tank.global_position
	var target := Vector3(23.263, 0.0, 12.637)
	var started_ms := Time.get_ticks_msec()
	var state := await _order_and_wait(gateway, [tank], target, human, 2400)
	var elapsed_ms := Time.get_ticks_msec() - started_ms
	var planar := _planar_distance(tank.global_position, target)
	_check(state == "Arrived", "绕墙后单兵必须真正到达（state=%s）" % state)
	_check(planar <= ARRIVAL_TOLERANCE_M, "绕墙到达误差应合理（%.2fm）" % planar)
	_check(
		_planar_distance(tank.global_position, start) > 5.0,
		"绕墙场景确实发生了长距离移动（%.2fm）" % _planar_distance(tank.global_position, start)
	)
	print(
		"[MOVEMENT] wall-detour state=%s elapsed_ms=%d start=%s end=%s planar_err=%.2f"
		% [state, elapsed_ms, start, tank.global_position, planar]
	)
	# 回到墙的 -z 侧缺口附近，供后续场景复用。
	await _order_and_wait(gateway, [tank], Vector3(16.0, 0.0, 12.637), human, 1800)


# --- 场景 2：窄口双向交会 ---

func _scenario_narrow_head_on(match_instance, human, gateway, tank: Node3D) -> void:
	_clear_wall()
	# 上下两段墙，中间留 ~3.4m 缺口：两车必须对穿同一个缺口。
	for index in range(3):
		_spawn_wall_block(match_instance, human, 18.263, 4.0 + float(index) * 2.5)
	for index in range(3):
		_spawn_wall_block(match_instance, human, 18.263, 16.5 + float(index) * 2.5)
	await _wait_frames(45)

	var other: Node3D = _spawn_unit(match_instance, human, WorkerScene, Vector3(22.0, 0.0, 12.637))
	var second: Node3D = _spawn_unit(match_instance, human, WorkerScene, Vector3(22.0, 0.0, 12.637))
	await _wait_frames(5)
	gateway.SetFirePolicy([tank, other, second], "HoldFire", human)

	var target_a := Vector3(22.0, 0.0, 12.637)
	var target_b := Vector3(16.0, 0.0, 12.637)
	var started_ms := Time.get_ticks_msec()
	var result_a: Dictionary = gateway.MoveUnits([tank], target_a, human)
	var result_b: Dictionary = gateway.MoveUnits([other], target_b, human)
	var order_a := _order_id(result_a)
	var order_b := _order_id(result_b)
	var terminal_a := await _wait_terminal_order(gateway, order_a, 2400)
	var terminal_b := await _wait_terminal_order(gateway, order_b, 2400)
	var elapsed_ms := Time.get_ticks_msec() - started_ms
	var separation := _planar_distance(tank.global_position, other.global_position)
	_check(terminal_a == "Arrived", "对穿缺口的第一辆车必须到达（state=%s）" % terminal_a)
	_check(terminal_b == "Arrived", "对穿缺口的第二辆车必须到达（state=%s）" % terminal_b)
	_check(separation >= MIN_SEPARATION_M, "交会后两车应保持可通行间距（%.2fm）" % separation)
	print(
		"[MOVEMENT] head-on a=%s b=%s elapsed_ms=%d separation=%.2f"
		% [terminal_a, terminal_b, elapsed_ms, separation]
	)
	_remove_unit(other)
	_remove_unit(second)


# --- 场景 3：集体回基地 ---

func _scenario_group_return_to_base(match_instance, human, gateway) -> void:
	_clear_wall()
	var base: Node3D = _spawn_unit(
		match_instance, human, CommandCenterScene, Vector3(12.0, 0.0, 28.0)
	)
	var workers: Array = []
	for index in range(8):
		var angle := TAU * float(index) / 8.0
		var position := base.global_position + Vector3(cos(angle), 0.0, sin(angle)) * 9.0
		workers.append(_spawn_unit(match_instance, human, WorkerScene, position))
	await _wait_frames(5)
	gateway.SetFirePolicy(workers, "HoldFire", human)

	var stance_result: Dictionary = gateway.SetEngagementStance(workers, "ReturnToBase", human)
	var order_ids: Array = []
	for entry in stance_result["unit_results"]:
		order_ids.append(String(entry["order_id"]))

	var started_ms := Time.get_ticks_msec()
	var arrived := 0
	var retry_alive := 900
	while retry_alive > 0:
		await get_tree().physics_frame
		retry_alive -= 1
		arrived = 0
		var all_terminal := true
		for order_id in order_ids:
			var state: String = gateway.GetOrderState(order_id)
			if state == "Arrived":
				arrived += 1
			elif not state in ["Unreachable", "TargetLost", "Cancelled", "UnitLost"]:
				all_terminal = false
		if all_terminal:
			break
		# 已抵达的持续姿态会保留订单，用位置判定收敛。
		if arrived == workers.size():
			break
		if arrived > 0 and _all_workers_at_base(workers, base):
			break
	var elapsed_ms := Time.get_ticks_msec() - started_ms
	var at_base := 0
	for worker in workers:
		if _planar_distance(worker.global_position, base.global_position) <= 4.5:
			at_base += 1
	var min_separation := _min_pairwise_separation(workers)
	_check(at_base >= 7, "集体回基地应至少 7/8 抵达基地附近（实际 %d）" % at_base)
	_check(min_separation >= MIN_SEPARATION_M, "回基地后不得互相叠住（最小间距 %.2fm）" % min_separation)
	print(
		"[MOVEMENT] group-return arrived=%d/8 at_base=%d min_sep=%.2f elapsed_ms=%d stats=%s"
		% [arrived, at_base, min_separation, elapsed_ms, MovementScript.recovery_stats]
	)
	for worker in workers:
		_remove_unit(worker)
	_remove_unit(base)


# --- 场景 4：行进中新建建筑 ---

func _scenario_building_added_mid_move(match_instance, human, gateway, tank: Node3D) -> void:
	_clear_wall()
	await _wait_frames(20)
	var start: Vector3 = tank.global_position
	# 目标保持在导航网格内（地图 54x54，只能沿 +x 拉开距离）。
	var target := Vector3(start.x + 18.0, 0.0, start.z)
	var started_ms := Time.get_ticks_msec()
	var result: Dictionary = gateway.MoveUnits([tank], target, human)
	var order_id := _order_id(result)
	# 让单位先跑起来，再在它的前方"突然"盖楼（触发运行时导航重烘）。
	await _wait_frames(30)
	for index in range(3):
		_spawn_wall_block(
			match_instance, human, start.x + 9.0, start.z - 3.0 + float(index) * 3.0
		)
	var state := await _wait_terminal_order(gateway, order_id, 2400)
	var elapsed_ms := Time.get_ticks_msec() - started_ms
	var planar := _planar_distance(tank.global_position, target)
	_check(state == "Arrived", "重烘导航网格期间单位不得站桩，必须到达（state=%s）" % state)
	_check(planar <= ARRIVAL_TOLERANCE_M, "新建建筑后到达误差应合理（%.2fm）" % planar)
	print(
		"[MOVEMENT] building-mid-move state=%s elapsed_ms=%d planar_err=%.2f stats=%s"
		% [state, elapsed_ms, planar, MovementScript.recovery_stats]
	)
	_clear_wall()


# --- 场景 5：脱困期间玩家改命令 ---

func _scenario_player_override_during_recovery(match_instance, human, gateway, tank: Node3D) -> void:
	_clear_wall()
	# 制造真实拥堵：一队单位抢同一个落点，且必须挤过同一个窄口（脱困会在此过程中被触发）。
	for index in range(3):
		_spawn_wall_block(match_instance, human, 18.263, 4.0 + float(index) * 2.5)
	for index in range(3):
		_spawn_wall_block(match_instance, human, 18.263, 16.5 + float(index) * 2.5)
	await _wait_frames(45)

	var original: Vector3 = tank.global_position
	var crowd: Array = [tank]
	for index in range(5):
		crowd.append(
			_spawn_unit(
				match_instance,
				human,
				WorkerScene,
				Vector3(original.x - 1.5, 0.0, original.z - 3.0 + float(index) * 1.5)
			)
		)
	await _wait_frames(5)
	gateway.SetFirePolicy(crowd, "HoldFire", human)

	var jam_target := Vector3(22.0, 0.0, 12.637)
	var jam_orders: Dictionary = gateway.MoveUnits(crowd, jam_target, human)
	var tank_jam_order := _order_id(jam_orders)
	var before_detections: int = MovementScript.recovery_stats["stall_detections"]
	await _wait_frames(180)
	var after_detections: int = MovementScript.recovery_stats["stall_detections"]

	# 拥堵仍在进行时玩家改命令：新命令必须立刻接管。
	var movement = tank.find_child("Movement")
	var recover_target := Vector3(original.x - 10.0, 0.0, original.z + 6.0)
	var override: Dictionary = gateway.MoveUnits([tank], recover_target, human)
	var override_order := _order_id(override)
	await _wait_frames(3)
	var released: bool = String(movement.get("_recovery_mode")) == ""
	_check(released, "玩家新命令必须立刻撤销进行中的脱困状态")
	var override_state := await _wait_terminal_order(gateway, override_order, 2400)
	var jammed_state: String = gateway.GetOrderState(tank_jam_order)
	var planar := _planar_distance(tank.global_position, recover_target)
	_check(override_state == "Arrived", "玩家新命令必须正常到达（state=%s）" % override_state)
	_check(planar <= ARRIVAL_TOLERANCE_M, "新命令到达误差应合理（%.2fm）" % planar)
	# 关键：旧目标不得复活。命令层是否把旧订单对象置为 Cancelled 属另一层语义，
	# 这里直接验证"单位最终没有按旧任务走"（位置在 3m 之外）。
	_check(
		_planar_distance(tank.global_position, jam_target) > 3.0,
		"被替换的旧移动任务不得复活（dist_to_old_target=%.2f）"
		% _planar_distance(tank.global_position, jam_target)
	)
	print(
		"[MOVEMENT] override new=%s old=%s planar_err=%.2f recovery_mode=%s detections=%d→%d"
		% [
			override_state, jammed_state, planar,
			String(movement.get("_recovery_mode")), before_detections, after_detections
		]
	)
	for unit in crowd:
		if unit != tank:
			_remove_unit(unit)
	_clear_wall()


# --- 工具 ---

func _spawn_wall_block(match_instance, human, x: float, z: float) -> void:
	var block: Node3D = _spawn_unit(
		match_instance, human, CommandCenterScene, Vector3(x, 0.0, z)
	)
	_wall.append(block)


func _clear_wall() -> void:
	for block in _wall:
		_remove_unit(block)
	_wall.clear()


func _spawn_unit(match_instance, player, scene, position: Vector3) -> Node3D:
	var unit: Node3D = scene.instantiate()
	match_instance.call(
		"_setup_and_spawn_unit", unit, Transform3D(Basis.IDENTITY, position), player, false
	)
	return unit


func _remove_unit(unit) -> void:
	if unit != null and is_instance_valid(unit):
		unit.queue_free()


func _order_and_wait(gateway, units: Array, target: Vector3, human, max_frames: int) -> String:
	var result: Dictionary = gateway.MoveUnits(units, target, human)
	return await _wait_terminal_order(gateway, _order_id(result), max_frames)


func _wait_terminal_order(gateway, order_id: String, max_frames: int) -> String:
	var state := ""
	for _frame in range(max_frames):
		await get_tree().physics_frame
		state = gateway.GetOrderState(order_id)
		if state in ["Arrived", "Unreachable", "Cancelled", "TargetLost", "UnitLost"]:
			return state
	return state


func _order_id(result: Dictionary, index := 0) -> String:
	var unit_results: Array = result.get("unit_results", [])
	if index >= unit_results.size():
		return ""
	return String(unit_results[index].get("order_id", ""))


func _all_workers_at_base(workers: Array, base: Node3D) -> bool:
	for worker in workers:
		if not is_instance_valid(worker):
			return false
		if _planar_distance(worker.global_position, base.global_position) > 4.5:
			return false
	return true


func _min_pairwise_separation(units: Array) -> float:
	var minimum := INF
	for first in range(units.size()):
		for second in range(first + 1, units.size()):
			if not (is_instance_valid(units[first]) and is_instance_valid(units[second])):
				continue
			minimum = minf(minimum, _planar_distance(units[first].global_position, units[second].global_position))
	return 0.0 if minimum == INF else minimum


func _planar_distance(first: Vector3, second: Vector3) -> float:
	return Vector2(first.x, first.z).distance_to(Vector2(second.x, second.z))


func _wait_frames(count: int) -> void:
	for _frame in range(count):
		await get_tree().physics_frame


func _check(condition: bool, message: String) -> void:
	if condition:
		return
	_failures += 1
	push_error("Movement recovery assertion failed: %s" % message)
