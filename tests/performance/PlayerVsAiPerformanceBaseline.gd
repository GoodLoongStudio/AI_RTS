extends Node

const MATCH_SCENE := preload("res://tests/manual/TestPlayerVsAI.tscn")
const WARMUP_FRAMES := 300
const MEASURED_FRAMES := 1800
const FIXED_SIMULATION_FPS := 60.0
const COMPLETION_MARKER := "Performance baseline smoke test completed: 0 failure(s)"

var _frame_wall_ms: Array[float] = []
var _process_ms: Array[float] = []
var _physics_ms: Array[float] = []
var _navigation_ms: Array[float] = []
var _peak_static_memory_bytes := 0.0
var _peak_object_count := 0.0
var _peak_node_count := 0.0
var _peak_orphan_node_count := 0.0
var _peak_unit_count := 0


func _ready() -> void:
	# 基线测试不能因一方提前获胜而暂停 SceneTree，否则测量帧数将不完整。
	FeatureFlags.handle_match_end = false
	var match_instance := MATCH_SCENE.instantiate()
	add_child(match_instance)

	for _frame in range(WARMUP_FRAMES):
		await get_tree().process_frame

	var initial_unit_count := get_tree().get_nodes_in_group("units").size()
	_peak_unit_count = initial_unit_count
	var measurement_started_usec := Time.get_ticks_usec()
	var previous_frame_usec := measurement_started_usec
	for _frame in range(MEASURED_FRAMES):
		await get_tree().process_frame
		var current_frame_usec := Time.get_ticks_usec()
		_frame_wall_ms.append(float(current_frame_usec - previous_frame_usec) / 1000.0)
		previous_frame_usec = current_frame_usec
		_sample_engine_monitors()
	var measurement_finished_usec := Time.get_ticks_usec()

	var final_unit_count := get_tree().get_nodes_in_group("units").size()
	var wall_seconds := float(measurement_finished_usec - measurement_started_usec) / 1_000_000.0
	var simulated_seconds := float(MEASURED_FRAMES) / FIXED_SIMULATION_FPS
	var result := {
		"schema_version": 1,
		"fixture": "TestPlayerVsAI",
		"mode": "headless_fixed_fps",
		"fixed_simulation_fps": FIXED_SIMULATION_FPS,
		"warmup_frames": WARMUP_FRAMES,
		"measured_frames": MEASURED_FRAMES,
		"simulated_seconds": simulated_seconds,
		"wall_seconds": wall_seconds,
		"simulation_to_wall_ratio": _safe_divide(simulated_seconds, wall_seconds),
		"wall_frame_ms": _summarize(_frame_wall_ms),
		"engine_process_ms": _summarize(_process_ms),
		"engine_physics_ms": _summarize(_physics_ms),
		"engine_navigation_ms": _summarize(_navigation_ms),
		"peak_static_memory_bytes": int(_peak_static_memory_bytes),
		"peak_object_count": int(_peak_object_count),
		"peak_node_count": int(_peak_node_count),
		"peak_orphan_node_count": int(_peak_orphan_node_count),
		"initial_unit_count": initial_unit_count,
		"final_unit_count": final_unit_count,
		"peak_unit_count": _peak_unit_count,
	}
	print("PERFORMANCE_BASELINE_JSON: %s" % JSON.stringify(result))
	print(COMPLETION_MARKER)

	match_instance.queue_free()
	await get_tree().process_frame
	FeatureFlags.handle_match_end = true
	get_tree().quit(0)


## 采集 Godot 提供的引擎阶段耗时、对象数量与静态内存监视器。
func _sample_engine_monitors() -> void:
	_process_ms.append(Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0)
	_physics_ms.append(Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0)
	_navigation_ms.append(Performance.get_monitor(Performance.TIME_NAVIGATION_PROCESS) * 1000.0)
	_peak_static_memory_bytes = maxf(
		_peak_static_memory_bytes,
		Performance.get_monitor(Performance.MEMORY_STATIC)
	)
	_peak_object_count = maxf(_peak_object_count, Performance.get_monitor(Performance.OBJECT_COUNT))
	_peak_node_count = maxf(_peak_node_count, Performance.get_monitor(Performance.OBJECT_NODE_COUNT))
	_peak_orphan_node_count = maxf(
		_peak_orphan_node_count,
		Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT)
	)
	_peak_unit_count = maxi(_peak_unit_count, get_tree().get_nodes_in_group("units").size())


## 生成一组样本的平均值、分位数与最大值；空样本返回显式零值。
func _summarize(values: Array[float]) -> Dictionary:
	if values.is_empty():
		return {"average": 0.0, "p50": 0.0, "p95": 0.0, "p99": 0.0, "maximum": 0.0}
	var sorted_values := values.duplicate()
	sorted_values.sort()
	var total := 0.0
	for value in values:
		total += value
	return {
		"average": total / float(values.size()),
		"p50": _percentile(sorted_values, 0.50),
		"p95": _percentile(sorted_values, 0.95),
		"p99": _percentile(sorted_values, 0.99),
		"maximum": sorted_values[sorted_values.size() - 1],
	}


## 从已排序样本中返回向上取整的最近秩分位数。
func _percentile(sorted_values: Array[float], fraction: float) -> float:
	var index := int(ceil(float(sorted_values.size() - 1) * fraction))
	return sorted_values[index]


func _safe_divide(numerator: float, denominator: float) -> float:
	if is_zero_approx(denominator):
		return 0.0
	return numerator / denominator
