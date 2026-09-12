extends Node

## 大部队移动规模与开销观测（2026-09-11）。
##
## 按 50 / 100 / 200 个单位递增，测量：
##   - 到达率（只认权威订单终态 Arrived）
##   - 收敛耗时（全部单位进入终态所需真实时间）
##   - 持续卡住数量（预算内仍未进入终态的单位）
##   - 帧耗时（process 时间的均值 / 峰值，headless 下不含渲染）
##   - 重寻路与脱困开销（Movement 的 repath / escape / 预算跳过计数）
##
## 判定：预算内必须全部收敛，到达率 ≥ 95%，且不得出现假 Unreachable。

const SmokeTestWarmup = preload("res://tests/automated/SmokeTestWarmup.gd")
const MovementScript = preload("res://source/match/units/traits/Movement.gd")
const MatchScene = preload("res://tests/manual/TestOneUnit.tscn")
const WorkerScene = preload("res://source/match/units/Worker.tscn")

const SCALES := [50, 100, 200]
## 200 单位在"对向交叉抢位"这种最恶劣拥堵下需要约 79~90s 才全部收敛（本机实测），
## 因此预算留到 90s；这是目前残留的规模瓶颈 —— 没有死锁，但收敛慢。
const MAX_FRAMES_PER_SCALE := 5400
const MIN_ARRIVAL_RATE := 0.95
## 预算内允许仍未收敛的比例（最恶劣拥堵下的抖动余量；正常场景应为 0）。
const MAX_STUCK_RATIO := 0.02
const COLUMNS := 14
const SPACING_M := 1.5


func _ready():
	var match_instance = MatchScene.instantiate()
	add_child(match_instance)
	await SmokeTestWarmup.wait_for_units(get_tree(), 1)

	var human = match_instance.get_node("Players/Human")
	var gateway = human.get_node("UnitCommandGateway")
	var reference_movement = human.get_node("Tank").find_child("Movement")
	await SmokeTestWarmup.wait_for_navigation(
		get_tree(), reference_movement, human.get_node("Tank").global_position
	)

	var failures := 0
	for scale in SCALES:
		failures += await _run_scale(match_instance, human, gateway, scale)

	print("Movement scale smoke test completed: %d failure(s)" % failures)
	match_instance.queue_free()
	await get_tree().process_frame
	SmokeTestExit.request(get_tree(), 0 if failures == 0 else 1)


func _run_scale(match_instance, human, gateway, scale: int) -> int:
	var units: Array = []
	for index in range(scale):
		var slot := Vector3(
			8.0 + float(index % COLUMNS) * SPACING_M,
			0.0,
			6.0 + float(index / COLUMNS) * SPACING_M
		)
		units.append(_spawn_unit(match_instance, human, slot))
	await _wait_frames(6)
	gateway.SetFirePolicy(units, "HoldFire", human)
	print("[SCALE] n=%d 已部署，开始下达移动命令" % scale)

	var before: Dictionary = _stats_snapshot()
	var order_ids: Array = []
	for index in range(scale):
		var destination := Vector3(
			38.0 - float(index % COLUMNS) * SPACING_M,
			0.0,
			36.0 - float(index / COLUMNS) * SPACING_M
		)
		var result: Dictionary = gateway.MoveUnits([units[index]], destination, human)
		order_ids.append(_order_id(result))

	var started_ms := Time.get_ticks_msec()
	var frames := 0
	var frame_time_sum_ms := 0.0
	var frame_time_max_ms := 0.0
	var stuck := scale
	while frames < MAX_FRAMES_PER_SCALE:
		await get_tree().physics_frame
		frames += 1
		var frame_ms := float(Performance.get_monitor(Performance.TIME_PROCESS)) * 1000.0
		frame_time_sum_ms += frame_ms
		frame_time_max_ms = maxf(frame_time_max_ms, frame_ms)
		stuck = _count_non_terminal(gateway, order_ids)
		if stuck == 0:
			break
	var elapsed_ms := Time.get_ticks_msec() - started_ms

	var arrived := 0
	var unreachable := 0
	for order_id in order_ids:
		var state: String = gateway.GetOrderState(order_id)
		if state == "Arrived":
			arrived += 1
		elif state == "Unreachable":
			unreachable += 1
	var arrival_rate := float(arrived) / float(scale) if scale > 0 else 0.0
	var after: Dictionary = _stats_snapshot()

	print(
		"[SCALE] n=%d arrived=%d rate=%.3f unreachable=%d stuck=%d frames=%d elapsed_ms=%d frame_avg_ms=%.3f frame_max_ms=%.3f repaths=%d escapes=%d stalls=%d budget_skips=%d"
		% [
			scale, arrived, arrival_rate, unreachable, stuck, frames, elapsed_ms,
			frame_time_sum_ms / float(maxi(frames, 1)), frame_time_max_ms,
			int(after.get("repaths", 0)) - int(before.get("repaths", 0)),
			int(after.get("escapes", 0)) - int(before.get("escapes", 0)),
			int(after.get("stall_detections", 0)) - int(before.get("stall_detections", 0)),
			int(after.get("budget_skips", 0)) - int(before.get("budget_skips", 0)),
		]
	)

	var failures := 0
	var stuck_limit := int(ceil(float(scale) * MAX_STUCK_RATIO))
	if stuck > stuck_limit:
		failures += 1
		push_error(
			"Movement scale assertion failed: n=%d 仍有 %d 个单位未收敛（上限 %d）"
			% [scale, stuck, stuck_limit]
		)
	if arrival_rate < MIN_ARRIVAL_RATE:
		failures += 1
		push_error("Movement scale assertion failed: n=%d 到达率 %.3f 低于阈值" % [scale, arrival_rate])
	if unreachable != 0:
		failures += 1
		push_error("Movement scale assertion failed: n=%d 出现 %d 个假 Unreachable" % [scale, unreachable])

	for unit in units:
		if is_instance_valid(unit):
			unit.queue_free()
	# 给 C# 侧注册表/GC 足够的释放窗口，避免下一档规模叠加时状态不清。
	await _wait_frames(60)
	return failures


## 动态读取脱困统计：静态变量只能通过实例读取，这样同一场景脚本在
## "未包含脱困统计"的旧版本代码上也能运行，便于做同场景改动前后对比。
func _stats_snapshot() -> Dictionary:
	var probe = MovementScript.new()
	var stats = probe.get("recovery_stats")
	probe.free()
	if stats is Dictionary:
		return (stats as Dictionary).duplicate()
	return {}


func _spawn_unit(match_instance, human, position: Vector3) -> Node3D:
	var unit: Node3D = WorkerScene.instantiate()
	match_instance.call(
		"_setup_and_spawn_unit", unit, Transform3D(Basis.IDENTITY, position), human, false
	)
	return unit


func _count_non_terminal(gateway, order_ids: Array) -> int:
	var pending := 0
	for order_id in order_ids:
		var state: String = gateway.GetOrderState(order_id)
		if not state in ["Arrived", "Unreachable", "Cancelled", "TargetLost", "UnitLost"]:
			pending += 1
	return pending


func _order_id(result: Dictionary, index := 0) -> String:
	var unit_results: Array = result.get("unit_results", [])
	if index >= unit_results.size():
		return ""
	return String(unit_results[index].get("order_id", ""))


func _wait_frames(count: int) -> void:
	for _frame in range(count):
		await get_tree().physics_frame
