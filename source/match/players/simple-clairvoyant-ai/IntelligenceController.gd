extends Node

const FIELD_TYPE := 1 << 1
const FIELD_RELATION := 1 << 2
const FIELD_ORDER := 1 << 6
const REFRESH_INTERVAL_S := 0.5
const PATROL_MARGIN_M := 5.0
const PATROL_SPACING_M := 15.0
const DRONE_TYPE_ID := "drone"
const GLOBAL_DEMO_SCAN_RADIUS_M := 100000.0

## 决策节奏倍率：由 SimpleClairvoyantAI 按"本局电脑玩家人数"注入（唯一实现见 AiCadence）。
## 默认 1.0 = 原始节奏；3 个电脑时为 2.0（0.5s → 1.0s）。
var refresh_scale := 1.0

var _world_query_runtime = null
var _query_session_id := ""
var _command_gateway = null
var _patrol_waypoints: Array[Vector3] = []
var _next_waypoint_index_by_drone := {}
var _enemy_type_counts := {}
## 每个侦察单位"本次巡逻 Move 下达时刻"（模拟毫秒）。用于**卡住检测**：
## 方案 3.C 要求"订单非空不等于正常移动。卡路可改点，阵亡补位"。
var _patrol_order_issued_sim_ms := {}
## 判为"订单卡住"的超时（模拟毫秒）：超过它仍未换点就强制推进到下一格。
const PATROL_STUCK_TIMEOUT_MS := 15000


## 绑定公共查询和固定身份命令，并从公开战场边界建立巡逻网格。
func setup(world_query_runtime, query_session_id: String, command_gateway):
	_world_query_runtime = world_query_runtime
	_query_session_id = query_session_id
	_command_gateway = command_gateway
	var bounds_result: Dictionary = _world_query_runtime.GetBattlefieldBounds(
		_query_session_id
	)
	if bounds_result.get("status", "") != "Accepted":
		push_warning("rule AI battlefield bounds query was rejected: %s" % bounds_result)
		return
	_patrol_waypoints = _build_patrol_waypoints(bounds_result["bounds"])
	_setup_refresh_timer()
	_refresh_patrols()


## 定时发现新 Drone、清理损失 Drone，并只向空闲 Drone 提交下一个巡逻点。
func _refresh_patrols():
	if _patrol_waypoints.is_empty():
		return
	var result: Dictionary = _world_query_runtime.GetOwnForces(
		_query_session_id,
		FIELD_TYPE | FIELD_ORDER
	)
	if result.get("status", "") != "Accepted":
		push_warning("rule AI intelligence query was rejected: %s" % result)
		return
	var drones: Array = result.get("entities", []).filter(
		func(entity): return entity.get("type_id", "") == DRONE_TYPE_ID
	)
	drones.sort_custom(
		func(left, right): return left.get("id", "") < right.get("id", "")
	)
	var current_ids: Array[String] = []
	for drone in drones:
		current_ids.append(drone.get("id", ""))
	for drone_id in _next_waypoint_index_by_drone.keys():
		if drone_id not in current_ids:
			_next_waypoint_index_by_drone.erase(drone_id)
			_patrol_order_issued_sim_ms.erase(drone_id)

	for drone_index in range(drones.size()):
		var drone: Dictionary = drones[drone_index]
		var drone_id: String = drone.get("id", "")
		if not _next_waypoint_index_by_drone.has(drone_id):
			_next_waypoint_index_by_drone[drone_id] = int(
				floor(float(drone_index * _patrol_waypoints.size()) / float(drones.size()))
			)
		var order = drone.get("order", null)
		if order != null:
			# 【2026-09-19 修确定缺陷】原先"有订单就跳过" ⇒ 被地形挡住 / 卡在障碍上
			# 的侦察单位会**永远停在同一格**，巡逻悄悄停摆而没有任何日志（方案 3.C：
			# "订单非空不等于正常移动。卡路可改点，阵亡补位"）。
			# 现在记录本次 Move 的下达时刻，超时即强制推进到下一格（新的 Move 会替换旧订单）。
			var issued := int(_patrol_order_issued_sim_ms.get(drone_id, 0))
			if issued > 0 and _now_sim_ms() - issued < PATROL_STUCK_TIMEOUT_MS:
				continue
		_issue_next_patrol_move(drone_id)


## 向一个空闲 Drone 提交下一网格点；被拒绝时保留索引供下一周期重试。
func _issue_next_patrol_move(drone_id: String):
	var waypoint_index: int = _next_waypoint_index_by_drone.get(drone_id, 0)
	var result: Dictionary = _command_gateway.Move(
		[drone_id],
		_patrol_waypoints[waypoint_index]
	)
	var accepted: bool = result.get("unit_results", []).any(
		func(item): return item.get("unit_id", "") == drone_id and item.get("accepted", false)
	)
	if accepted:
		_next_waypoint_index_by_drone[drone_id] = (
			(waypoint_index + 1) % _patrol_waypoints.size()
		)
		# 记录下达时刻，供下一拍的"卡住检测"判断（模拟时钟，暂停不累计）。
		_patrol_order_issued_sim_ms[drone_id] = _now_sim_ms()
	else:
		push_warning("rule AI drone patrol Move was rejected: %s" % result)


## 战局模拟毫秒；控制器被单独挂载（单测/探针）时回退实时时钟。
func _now_sim_ms() -> int:
	var ai := get_parent()
	if ai != null and ai.has_method("simulation_msec"):
		return int(ai.simulation_msec())
	return Time.get_ticks_msec()


## 根据公开地图矩形创建蛇形网格，使多个 Drone 可以从不同相位开始覆盖地图。
func _build_patrol_waypoints(bounds: Dictionary) -> Array[Vector3]:
	var minimum_x: float = bounds.get("minimum_x", 0.0)
	var maximum_x: float = bounds.get("maximum_x", 0.0)
	var minimum_z: float = bounds.get("minimum_z", 0.0)
	var maximum_z: float = bounds.get("maximum_z", 0.0)
	var width := maximum_x - minimum_x
	var depth := maximum_z - minimum_z
	if width <= 0.0 or depth <= 0.0:
		return []
	var margin_x := minf(PATROL_MARGIN_M, width * 0.25)
	var margin_z := minf(PATROL_MARGIN_M, depth * 0.25)
	var patrol_minimum_x := minimum_x + margin_x
	var patrol_maximum_x := maximum_x - margin_x
	var patrol_minimum_z := minimum_z + margin_z
	var patrol_maximum_z := maximum_z - margin_z
	var columns: int = maxi(2, int(ceil(
		(patrol_maximum_x - patrol_minimum_x) / PATROL_SPACING_M
	)) + 1)
	var rows: int = maxi(2, int(ceil(
		(patrol_maximum_z - patrol_minimum_z) / PATROL_SPACING_M
	)) + 1)
	var waypoints: Array[Vector3] = []
	for row in range(rows):
		var z := lerpf(
			patrol_minimum_z,
			patrol_maximum_z,
			float(row) / float(rows - 1)
		)
		var row_points: Array[Vector3] = []
		for column in range(columns):
			var x := lerpf(
				patrol_minimum_x,
				patrol_maximum_x,
				float(column) / float(columns - 1)
			)
			row_points.append(Vector3(x, 0.0, z))
		if row % 2 == 1:
			row_points.reverse()
		waypoints.append_array(row_points)
	return waypoints


## 建立固定频率刷新计时器，避免依赖 Unit Action 信号或随机延迟。
func _setup_refresh_timer():
	var timer := Timer.new()
	add_child(timer)
	timer.timeout.connect(_on_refresh_timer_timeout)
	timer.start(REFRESH_INTERVAL_S * refresh_scale)


func _on_refresh_timer_timeout():
	_refresh_patrols()
	_refresh_enemy_composition()


## 敌情汇总（AI-plan Part A Phase 6）：全局扫描 VisibleNow/LastKnown 敌军的
## type_id 直方图，供 OffenseController 做克制参考；这里首次让侦察产出情报。
func _refresh_enemy_composition():
	var result: Dictionary = _world_query_runtime.ScanCircle(
		_query_session_id,
		Vector3.ZERO,
		GLOBAL_DEMO_SCAN_RADIUS_M,
		FIELD_TYPE | FIELD_RELATION
	)
	if result.get("status", "") != "Accepted":
		return
	var counts := {}
	for entity in result.get("entities", []):
		if entity.get("relation", "") != "Enemy":
			continue
		if entity.get("state", "") not in ["VisibleNow", "LastKnown"]:
			continue
		var type_id: String = entity.get("type_id", "")
		if type_id.is_empty() or type_id.begins_with("resource"):
			continue
		counts[type_id] = counts.get(type_id, 0) + 1
	_enemy_type_counts = counts


## 返回最近一轮敌情汇总的副本（type_id → 数量）；未扫描时为空字典。
func get_enemy_composition_summary() -> Dictionary:
	return _enemy_type_counts.duplicate()
