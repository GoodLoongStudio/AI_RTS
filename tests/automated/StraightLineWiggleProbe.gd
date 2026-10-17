extends Node

## 直线行进偏摆探针（只读，不改游戏行为）。
##
## 用户报：重型坦克接到移动命令后"扭来扭去"，不能直直地走。
## 本探针在无障碍开阔地上给单个单位下一条长距离命令，逐物理帧采样轨迹，
## 量化三个指标：
##   1. tortuosity = 实际路程 / 净位移（1.0 = 完美直线）
##   2. max_lateral = 相对起点→终点连线的最大横向偏离（米）
##   3. reversals = 横向速度符号翻转次数（蛇形的直接证据）
## 同时打印脱困状态机时间线，判断偏摆是否由"停滞→侧移脱困"造成。

const SmokeTestWarmup = preload("res://tests/automated/SmokeTestWarmup.gd")
const MovementScript = preload("res://source/match/units/traits/Movement.gd")
const MatchScene = preload("res://tests/manual/TestOneUnit.tscn")
const HeavyTankScene = preload("res://source/match/units/HeavyTank.tscn")
const TankScene = preload("res://source/match/units/Tank.tscn")
const APCScene = preload("res://source/match/units/APC.tscn")
const TruckScene = preload("res://source/match/units/TransportTruck.tscn")
const InfantryScene = preload("res://source/match/units/Infantry.tscn")

const RUN_M := 40.0
const SAMPLE_FRAMES := 600
## 开阔地直线行进的验收口径：横向偏离与横速翻转的容忍上限。
const MAX_LATERAL_M := 0.5
const MAX_REVERSALS := 1

var _failures := 0


func _ready():
	var match_instance = MatchScene.instantiate()
	add_child(match_instance)
	await SmokeTestWarmup.wait_for_units(get_tree(), 1)

	var human = match_instance.get_node("Players/Human")
	var preset: Node3D = human.get_node("Tank")
	var movement = preset.find_child("Movement")
	await SmokeTestWarmup.wait_for_navigation(get_tree(), movement, preset.global_position)

	# 预置单位先清场，避免 RVO 把它当邻居。
	preset.global_position = Vector3(-200.0, 0.0, -200.0)

	for case in [
		[HeavyTankScene, "heavy_tank"],
		[APCScene, "apc"],
		[TruckScene, "transport_truck"],
		[TankScene, "tank"],
		[InfantryScene, "infantry"],
	]:
		await _run_case(match_instance, human, case[0], case[1])

	print("WIGGLEPROBE completed: %d failure(s)" % _failures)
	match_instance.queue_free()
	await get_tree().process_frame
	SmokeTestExit.request(get_tree(), 0 if _failures == 0 else 1)


func _run_case(match_instance, human, scene, label: String) -> void:
	var origin := Vector3(60.0, 0.0, 104.0)
	var unit: Node3D = _spawn_unit(match_instance, human, scene, origin)
	var movement = unit.find_child("Movement")
	await _wait_frames(30)
	var target := origin + Vector3(RUN_M, 0.0, 0.0)

	var stats_before: Dictionary = MovementScript.recovery_stats.duplicate(true)
	movement.call("move", target)
	await _wait_frames(10)

	var samples: Array = []
	for _frame in range(SAMPLE_FRAMES):
		await get_tree().physics_frame
		samples.append(
			{
				"pos": unit.global_position,
				"mode": String(movement.get("_recovery_mode")),
				"agent_target": movement.get("target_position"),
				"path_index": int(movement.call("get_current_navigation_path_index")),
			}
		)
		if Vector2(unit.global_position.x, unit.global_position.z).distance_to(
			Vector2(target.x, target.z)
		) <= maxf(float(movement.get("radius")), 0.35) + 0.2:
			break

	var metrics := _metrics(samples, origin, target)
	var stats_after: Dictionary = MovementScript.recovery_stats
	var escapes := int(stats_after["escapes"]) - int(stats_before["escapes"])
	print(
		"WIGGLEPROBE case=%s radius=%.2f speed=%.2f frames=%d final_err=%.2fm"
		% [
			label, float(movement.get("radius")), float(movement.get("speed")),
			samples.size(), metrics["final_err"]
		]
	)
	print(
		"WIGGLEPROBE   tortuosity=%.3f max_lateral=%.2fm reversals=%d path_len=%.2fm net=%.2fm"
		% [metrics["tortuosity"], metrics["max_lateral"], metrics["reversals"], metrics["path_len"], metrics["net"]]
	)
	print(
		"WIGGLEPROBE   recovery: stall=%d repath=%d escape=%d unreachable=%d"
		% [
			int(stats_after["stall_detections"]) - int(stats_before["stall_detections"]),
			int(stats_after["repaths"]) - int(stats_before["repaths"]),
			escapes,
			int(stats_after["unreachable"]) - int(stats_before["unreachable"])
		]
	)
	print("WIGGLEPROBE   mode_timeline=%s" % str(_mode_timeline(samples)))
	print(
		"WIGGLEPROBE   threshold=%.3fm/0.5s  actual_progress=%.3fm/0.5s"
		% [
			movement.call("_stall_min_progress_m"),
			float(movement.get("speed")) * 0.5
		]
	)
	# 开阔地直线命令：不得出现可察觉的蛇形偏摆，也不得触发任何脱困侧移。
	_check(
		metrics["max_lateral"] <= MAX_LATERAL_M,
		"%s 开阔地直线行进的横向偏离应 ≤%.2fm（实际 %.2fm）"
		% [label, MAX_LATERAL_M, metrics["max_lateral"]]
	)
	_check(escapes == 0, "%s 开阔地直线行进不得触发脱困侧移（实际 %d 次）" % [label, escapes])
	_check(
		metrics["reversals"] <= MAX_REVERSALS,
		"%s 横向速度符号翻转应 ≤%d 次（实际 %d 次）" % [label, MAX_REVERSALS, metrics["reversals"]]
	)
	_remove_unit(unit)


## 轨迹指标：路程/净位移、相对理想连线的最大横向偏离、横向速度符号翻转次数。
func _metrics(samples: Array, origin: Vector3, target: Vector3) -> Dictionary:
	if samples.is_empty():
		return {"tortuosity": 1.0, "max_lateral": 0.0, "reversals": 0, "path_len": 0.0, "net": 0.0, "final_err": 0.0}
	var axis := Vector2(target.x - origin.x, target.z - origin.z)
	var axis_len := axis.length()
	var forward := axis / axis_len if axis_len > 0.0001 else Vector2.RIGHT
	var lateral_dir := Vector2(-forward.y, forward.x)

	var path_len := 0.0
	var max_lateral := 0.0
	var reversals := 0
	var last_lateral_step_sign := 0
	var previous: Vector3 = samples[0]["pos"]
	for sample in samples:
		var pos: Vector3 = sample["pos"]
		path_len += Vector2(pos.x - previous.x, pos.z - previous.z).length()
		var offset := Vector2(pos.x - origin.x, pos.z - origin.z)
		max_lateral = maxf(max_lateral, absf(offset.dot(lateral_dir)))
		var step := Vector2(pos.x - previous.x, pos.z - previous.z)
		var lateral_step := step.dot(lateral_dir)
		var sign_now := 0
		if absf(lateral_step) > 0.0015:
			sign_now = 1 if lateral_step > 0.0 else -1
		if sign_now != 0 and last_lateral_step_sign != 0 and sign_now != last_lateral_step_sign:
			reversals += 1
		if sign_now != 0:
			last_lateral_step_sign = sign_now
		previous = pos

	var last: Vector3 = samples[samples.size() - 1]["pos"]
	var net := Vector2(last.x - origin.x, last.z - origin.z).length()
	return {
		"tortuosity": path_len / maxf(net, 0.001),
		"max_lateral": max_lateral,
		"reversals": reversals,
		"path_len": path_len,
		"net": net,
		"final_err": Vector2(last.x - target.x, last.z - target.z).length(),
	}


func _mode_timeline(samples: Array) -> Array:
	var out: Array = []
	var last := "~"
	for index in range(samples.size()):
		var entry: Dictionary = samples[index]
		var key := "%s|%s" % [String(entry["mode"]), str(Vector2(entry["agent_target"].x, entry["agent_target"].z).round())]
		if key != last:
			out.append("f%d:%s" % [index, key])
			last = key
	return out


func _spawn_unit(match_instance, player, scene, position: Vector3) -> Node3D:
	var unit: Node3D = scene.instantiate()
	match_instance.call(
		"_setup_and_spawn_unit", unit, Transform3D(Basis.IDENTITY, position), player, false
	)
	return unit


func _remove_unit(unit) -> void:
	if unit != null and is_instance_valid(unit):
		unit.queue_free()


func _wait_frames(count: int) -> void:
	for _frame in range(count):
		await get_tree().physics_frame


func _check(condition: bool, message: String) -> void:
	if condition:
		return
	_failures += 1
	push_error("StraightLineWiggleProbe assertion failed: %s" % message)
