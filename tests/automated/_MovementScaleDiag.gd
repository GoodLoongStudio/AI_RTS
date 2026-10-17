extends Node

## 诊断探针（2026-09-30 第 2 轮）：movement-scale n=200 为什么会卡 47 个？
## 不改任何判定阈值，只做两件事：
##   1. 把预算从 5400 帧延长到 18000 帧，看"最终能否收敛"（区分"慢"与"死锁"）；
##   2. 每 1200 帧打印进度曲线；结束时 dump 每个未收敛单位的现场（位置/目标/剩余距离/当前 action）。
## 依据：计划第 4 条"每轮只改一个根因，记录假设、证据"。
##
## 【2026-09-30 问题A 取证轮追加】只加**观测**与**探针侧单因素控制**，不动任何游戏判定：
##   - 每窗口流速统计：平均速度 / 停车比例 / 慢速比例 / 平均剩余距离，
##     ⇒ 区分"排队等速前进（速度>0 但小）"与"互相顶死（速度≈0）"；
##   - MS_HALF 控制：只让一股流（Δx>0 或 Δx<0）移动、另一股原地站桩
##     ⇒ 把"静态占位拥堵"从"对向互避"里分离出来（两股流都是**单向**流）；
##   - MS_SPEED_MUL 控制：整体改速度，看耗时是否 ∝1/v
##     ⇒ 容量受限（∝1/v）还是死锁受限（对 v 不敏感）；
##   - MS_BUDGET：覆盖帧预算，便于快速档位对比。
## 这些开关全部只在探针里生效（探针直接改单位节点属性），不改源码。

const SmokeTestWarmup = preload("res://tests/automated/SmokeTestWarmup.gd")
const MovementScript = preload("res://source/match/units/traits/Movement.gd")
const MatchScene = preload("res://tests/manual/TestOneUnit.tscn")
const WorkerScene = preload("res://source/match/units/Worker.tscn")

var scale_units := 200
const COLUMNS := 14
const SPACING_M := 6.0
var max_frames := 18000
## 单因素实验：关掉 RVO 看吞吐是否由避让决定。
const DISABLE_AVOIDANCE := false
## 单因素实验：把"对向交叉"换成"同向平移"（目的地不再镜像，改为整体 +x 平移 70m）。
## 用来区分"交叉拥堵造成的排队"与"整体行进速度就慢"。
const SAME_DIRECTION := false
## 单因素实验：错峰下令。把 200 条移动令拆成 STAGGER_GROUPS 批，每批之间等
## STAGGER_INTERVAL_S 秒（1 = 一次性全部下令，即基线）。
## 目的：量化"对向交叉"的代价里有多少来自"全员同一帧起步造成的瞬时拥堵"——
## 这是**只改探针、不改游戏**的实验，用于给设计决策提供数据。
const STAGGER_GROUPS_DEFAULT := 1
const STAGGER_INTERVAL_S := 0.5
## 允许用环境变量 MS_STAGGER / MS_STAGGER_INTERVAL 覆盖，便于一次作业里跑多个档位。
var stagger_groups := STAGGER_GROUPS_DEFAULT
var stagger_interval_s := STAGGER_INTERVAL_S
const REPORT_EVERY := 1200

## 探针侧单因素控制（默认全部为"不干预"）。
var half_flow := "none"        # none / right / left / both-split
var speed_mul := 1.0
## MS_RADIUS：覆盖单位避让半径（诊断"接触直径 vs 编队间隙"是不是根因）。
## 编队间距 6m 固定、半径 2.0 ⇒ 净间隙 2m（比单位自身还窄）；半径减半 ⇒ 间隙 4m。
var radius_override := -1.0
## MS_NO_AVOIDANCE=1：关掉 RVO（诊断用；注意 velocity_computed 不再触发）。
var no_avoidance := false

## 流速采样累加器。
var _flow_prev: Array = []
var _flow_sum_speed := 0.0
var _flow_samples := 0
var _flow_stopped := 0
var _flow_slow := 0
var _flow_active := 0


func _ready():
	var env_groups := OS.get_environment("MS_STAGGER")
	if env_groups != "":
		stagger_groups = int(env_groups)
	var env_interval := OS.get_environment("MS_STAGGER_INTERVAL")
	if env_interval != "":
		stagger_interval_s = float(env_interval)
	var env_scale := OS.get_environment("MS_SCALE")
	if env_scale != "":
		scale_units = int(env_scale)
	var env_budget := OS.get_environment("MS_BUDGET")
	if env_budget != "":
		max_frames = int(env_budget)
	var env_half := OS.get_environment("MS_HALF")
	if env_half != "":
		half_flow = env_half
	var env_speed := OS.get_environment("MS_SPEED_MUL")
	if env_speed != "":
		speed_mul = float(env_speed)
	var env_radius := OS.get_environment("MS_RADIUS")
	if env_radius != "":
		radius_override = float(env_radius)
	var env_noavoid := OS.get_environment("MS_NO_AVOIDANCE")
	if env_noavoid != "":
		no_avoidance = env_noavoid == "1"
	print("[DIAG] 配置：单位=%d 同向=%s 分批=%d 批间隔=%.2fs 半流=%s 速度×%.2f 预算=%d帧" % [
		scale_units, str(SAME_DIRECTION), stagger_groups, stagger_interval_s,
		half_flow, speed_mul, max_frames])
	var match_instance = MatchScene.instantiate()
	add_child(match_instance)
	await SmokeTestWarmup.wait_for_units(get_tree(), 1)
	var human = match_instance.get_node("Players/Human")
	var gateway = human.get_node("UnitCommandGateway")
	var reference_movement = human.get_node("Tank").find_child("Movement")
	await SmokeTestWarmup.wait_for_navigation(
		get_tree(), reference_movement, human.get_node("Tank").global_position
	)

	var units: Array = []
	var dests: Array = []
	for index in range(scale_units):
		var slot := Vector3(
			58.0 + float(index % COLUMNS) * SPACING_M, 0.0,
			58.0 + float(index / COLUMNS) * SPACING_M
		)
		units.append(_spawn_unit(match_instance, human, slot))
	await _wait_frames(6)
	gateway.SetFirePolicy(units, "HoldFire", human)
	# 单因素实验开关：关掉 RVO 避让（只做诊断，不用于修复）。
	if DISABLE_AVOIDANCE or no_avoidance:
		var disabled := 0
		for unit in units:
			var mv = unit.find_child("Movement", true, false)
			if mv != null:
				mv.set("avoidance_enabled", false)
				disabled += 1
		print("[DIAG] 已关闭 %d 个单位的 RVO 避让（单因素实验）" % disabled)

	var order_ids: Array = []
	var moving_flags: Array = []
	for index in range(scale_units):
		var destination := Vector3(
			(58.0 + float(index % COLUMNS) * SPACING_M + 70.0) if SAME_DIRECTION else (168.0 - float(index % COLUMNS) * SPACING_M),
			0.0,
			(58.0 + float(index / COLUMNS) * SPACING_M) if SAME_DIRECTION else (120.0 + float(index / COLUMNS) * SPACING_M)
		)
		dests.append(destination)
		var should_move := true
		if half_flow == "right":
			should_move = destination.x > units[index].global_position.x
		elif half_flow == "left":
			should_move = destination.x < units[index].global_position.x
		moving_flags.append(should_move)
		if speed_mul != 1.0:
			var mv = units[index].find_child("Movement", true, false)
			if mv != null:
				mv.set("speed", float(mv.get("speed")) * speed_mul)
		if radius_override > 0.0:
			var mv_r = units[index].find_child("Movement", true, false)
			if mv_r != null:
				mv_r.set("radius", radius_override)
		if not should_move:
			order_ids.append("")
			continue
		var result: Dictionary = gateway.MoveUnits([units[index]], destination, human)
		# 错峰：每批之间等一会儿再下下一批（STAGGER_GROUPS = 1 时完全不等待）。
		if stagger_groups > 1 and (index + 1) % int(ceil(float(scale_units) / float(stagger_groups))) == 0 \
				and index + 1 < scale_units:
			await get_tree().create_timer(stagger_interval_s).timeout
		order_ids.append(_order_id(result))
	var ordered := 0
	for flag in moving_flags:
		if flag:
			ordered += 1
	print("[DIAG] n=%d 已下令（实际下令 %d 个），开始计时（预算 %d 帧）" % [scale_units, ordered, max_frames])

	_flow_prev.resize(scale_units)
	for index in range(scale_units):
		_flow_prev[index] = units[index].global_position

	var started_ms := Time.get_ticks_msec()
	var before: Dictionary = _stats_snapshot()
	var frames := 0
	var stuck := ordered
	var last_report := 0
	var prev: Dictionary = _stats_snapshot()
	while frames < max_frames:
		await get_tree().physics_frame
		frames += 1
		if not SAME_DIRECTION:
			_sample_flow(units, dests, moving_flags, gateway, order_ids)
		# 收敛检测精度 = 1s（原来只在 1200 帧窗口边界检测 ⇒ 精度 20s，A/B 分不出 <20s 的差异）。
		if frames % 60 == 0:
			stuck = _count_non_terminal(gateway, order_ids)
			if stuck == 0:
				break
		if frames - last_report >= REPORT_EVERY:
			last_report = frames
			stuck = _count_non_terminal(gateway, order_ids)
			var snap: Dictionary = _stats_snapshot()
			var delta := {}
			for key in snap:
				delta[key] = int(snap[key]) - int(prev.get(key, 0))
			prev = snap
			print("[DIAG] t=%.0fs frames=%d 未收敛=%d（%.1f%%） | repath+%d escape+%d stall+%d 软穿行进入+%d 退出+%d 拒绝+%d 预算跳+%d" % [
				float(Time.get_ticks_msec() - started_ms) / 1000.0, frames, stuck,
				100.0 * float(stuck) / float(maxi(ordered, 1)),
				int(delta.get("repaths", 0)), int(delta.get("escapes", 0)),
				int(delta.get("stall_detections", 0)),
				int(delta.get("soft_phase_enters", 0)), int(delta.get("soft_phase_exits", 0)),
				int(delta.get("soft_phase_rejects", 0)), int(delta.get("budget_skips", 0))])
			if not SAME_DIRECTION:
				_report_flow(frames, units, dests, moving_flags, gateway, order_ids)
	stuck = _count_non_terminal(gateway, order_ids)
	var after: Dictionary = _stats_snapshot()
	var arrived := 0
	for order_id in order_ids:
		if order_id != "" and gateway.GetOrderState(order_id) == "Arrived":
			arrived += 1
	print("[DIAG] 结束：elapsed=%.1fs frames=%d arrived=%d 未收敛=%d 到达率=%.3f" % [
		float(Time.get_ticks_msec() - started_ms) / 1000.0, frames, arrived, stuck,
		float(arrived) / float(maxi(ordered, 1))])
	# 只读探针：RVO 回传速度相对期望步长的幅值比/方向余弦（AIRTS_FLOW_PROBE=1 时才有样本）。
	var flow_probe_stats: Dictionary = _flow_stats_snapshot()
	if int(flow_probe_stats.get("vel_samples", 0)) > 0:
		var samples := int(flow_probe_stats["vel_samples"])
		print("[DIAG][VEL] RVO样本=%d 幅值比均值=%.3f 幅值比<0.5占比=%.1f%% <0.1占比=%.1f%% 方向余弦均值=%.3f 余弦<0.5占比=%.1f%%" % [
			samples, float(flow_probe_stats["vel_ratio_sum"]) / float(samples),
			100.0 * float(flow_probe_stats["vel_lt50"]) / float(samples),
			100.0 * float(flow_probe_stats["vel_lt10"]) / float(samples),
			float(flow_probe_stats["vel_dir_sum"]) / float(samples),
			100.0 * float(flow_probe_stats["vel_dir_lt05"]) / float(samples)])
	print("[DIAG][FLOWSTAT] scans=%d conflicts=%d yields=%d lane_steers=%d soft_shrinks=%d soft_restores=%d" % [
		int(flow_probe_stats.get("scans", 0)), int(flow_probe_stats.get("conflicts", 0)),
		int(flow_probe_stats.get("yields", 0)), int(flow_probe_stats.get("lane_steers", 0)),
		int(flow_probe_stats.get("soft_shrinks", 0)), int(flow_probe_stats.get("soft_restores", 0))])
	print("[DIAG][CFG] %s" % _agent_config_line(units))
	print("[DIAG] 脱困统计 repaths=%d escapes=%d stalls=%d budget_skips=%d" % [
		int(after.get("repaths", 0)) - int(before.get("repaths", 0)),
		int(after.get("escapes", 0)) - int(before.get("escapes", 0)),
		int(after.get("stall_detections", 0)) - int(before.get("stall_detections", 0)),
		int(after.get("budget_skips", 0)) - int(before.get("budget_skips", 0))])

	# 未收敛单位现场
	var dumped := 0
	for index in range(scale_units):
		if not moving_flags[index]:
			continue
		var state: String = gateway.GetOrderState(order_ids[index])
		if state in ["Arrived", "Unreachable", "Cancelled", "TargetLost", "UnitLost"]:
			continue
		var unit = units[index]
		if not is_instance_valid(unit):
			print("[DIAG] #%d state=%s 单位已失效" % [index, state])
			continue
		var action = unit.get("action")
		var action_name := "<null>"
		if action != null and action.get_script() != null:
			action_name = str(action.get_script().resource_path).get_file()
		var remain: float = unit.global_position.distance_to(dests[index])
		print("[DIAG] #%d state=%s pos=%s dest=%s remain=%.2f action=%s" % [
			index, state, str(unit.global_position.snapped(Vector3(0.1, 0.1, 0.1))),
			str(dests[index]), remain, action_name])
		dumped += 1
		if dumped >= 25:
			print("[DIAG] …（其余省略）")
			break

	match_instance.queue_free()
	await get_tree().process_frame
	SmokeTestExit.request(get_tree(), 0)


## 每帧采样"仍在推进"的单位的平面速度（米/秒），窗口末汇总。
func _sample_flow(units: Array, dests: Array, moving_flags: Array, gateway, order_ids: Array) -> void:
	var dt := 1.0 / float(Engine.physics_ticks_per_second)
	for index in range(units.size()):
		if not moving_flags[index]:
			continue
		var unit = units[index]
		if not is_instance_valid(unit):
			continue
		var state: String = gateway.GetOrderState(order_ids[index])
		if state in ["Arrived", "Unreachable", "Cancelled", "TargetLost", "UnitLost"]:
			continue
		var pos: Vector3 = unit.global_position
		var prev: Vector3 = _flow_prev[index]
		_flow_prev[index] = pos
		var speed := Vector2(pos.x - prev.x, pos.z - prev.z).length() / dt
		_flow_sum_speed += speed
		_flow_samples += 1
		_flow_active += 1
		if speed < 0.2:
			_flow_stopped += 1
		elif speed < 1.5:
			_flow_slow += 1


func _report_flow(frames: int, units: Array, dests: Array, moving_flags: Array, gateway, order_ids: Array) -> void:
	if _flow_active <= 0:
		return
	var mean := _flow_sum_speed / float(_flow_active)
	# 未收敛单位的"平均剩余直线距离"：对"速度满速但净推进慢"的churn 是直接证据。
	var remain_sum := 0.0
	var remain_n := 0
	for index in range(units.size()):
		if not moving_flags[index]:
			continue
		var unit = units[index]
		if not is_instance_valid(unit):
			continue
		var state: String = gateway.GetOrderState(order_ids[index])
		if state in ["Arrived", "Unreachable", "Cancelled", "TargetLost", "UnitLost"]:
			continue
		remain_sum += unit.global_position.distance_to(dests[index])
		remain_n += 1
	print("[DIAG][FLOW] t=%.0fs 均值速度=%.2fm/s 停车(<0.2)=%.1f%% 慢速(0.2~1.5)=%.1f%% 畅通(>1.5)=%.1f%% 在途=%d 平均剩余=%.1fm 样本=%d" % [
		float(frames) / 60.0, mean,
		100.0 * float(_flow_stopped) / float(_flow_active),
		100.0 * float(_flow_slow) / float(_flow_active),
		100.0 * float(_flow_active - _flow_stopped - _flow_slow) / float(_flow_active),
		remain_n, remain_sum / float(maxi(remain_n, 1)), _flow_active])
	_flow_sum_speed = 0.0
	_flow_stopped = 0
	_flow_slow = 0
	_flow_active = 0


## 采样一个单位的避让参数（写结论用：把"期望速度量纲 vs 感知半径/视野"的口径写清楚）。
func _agent_config_line(units: Array) -> String:
	if units.is_empty() or not is_instance_valid(units[0]):
		return "<no unit>"
	var mv = units[0].find_child("Movement", true, false)
	if mv == null:
		return "<no movement>"
	return "radius=%.2f speed=%.2f neighbor_distance=%.2f max_neighbors=%d time_horizon_agents=%.2f max_speed=%.2f avoidance=%s" % [
		float(mv.get("radius")), float(mv.get("speed")), float(mv.get("neighbor_distance")),
		int(mv.get("max_neighbors")), float(mv.get("time_horizon_agents")),
		float(mv.get("max_speed")), str(mv.get("avoidance_enabled"))]


func _flow_stats_snapshot() -> Dictionary:
	var probe = MovementScript.new()
	var stats = probe.get("flow_stats")
	probe.free()
	return (stats as Dictionary).duplicate() if stats is Dictionary else {}


func _stats_snapshot() -> Dictionary:
	var probe = MovementScript.new()
	var stats = probe.get("recovery_stats")
	probe.free()
	return (stats as Dictionary).duplicate() if stats is Dictionary else {}


func _spawn_unit(match_instance, human, position: Vector3) -> Node3D:
	var unit: Node3D = WorkerScene.instantiate()
	match_instance.call("_setup_and_spawn_unit", unit, Transform3D(Basis.IDENTITY, position), human, false)
	return unit


func _count_non_terminal(gateway, order_ids: Array) -> int:
	var pending := 0
	for order_id in order_ids:
		if order_id == "":
			continue
		if not gateway.GetOrderState(order_id) in ["Arrived", "Unreachable", "Cancelled", "TargetLost", "UnitLost"]:
			pending += 1
	return pending


func _order_id(result: Dictionary, index := 0) -> String:
	var unit_results: Array = result.get("unit_results", [])
	return "" if index >= unit_results.size() else String(unit_results[index].get("order_id", ""))


func _wait_frames(count: int) -> void:
	for _frame in range(count):
		await get_tree().physics_frame
