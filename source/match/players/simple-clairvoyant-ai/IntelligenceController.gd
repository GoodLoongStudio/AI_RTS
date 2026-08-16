extends Node

const FIELD_TYPE := 1 << 1
const FIELD_ORDER := 1 << 6
const REFRESH_INTERVAL_S := 0.5
const PATROL_MARGIN_M := 5.0
const PATROL_SPACING_M := 15.0
const DRONE_TYPE_ID := "drone"

var _world_query_runtime = null
var _query_session_id := ""
var _command_gateway = null
var _patrol_waypoints: Array[Vector3] = []
var _next_waypoint_index_by_drone := {}


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

	for drone_index in range(drones.size()):
		var drone: Dictionary = drones[drone_index]
		var drone_id: String = drone.get("id", "")
		if not _next_waypoint_index_by_drone.has(drone_id):
			_next_waypoint_index_by_drone[drone_id] = int(
				floor(float(drone_index * _patrol_waypoints.size()) / float(drones.size()))
			)
		var order = drone.get("order", null)
		if order != null:
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
	else:
		push_warning("rule AI drone patrol Move was rejected: %s" % result)


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
	timer.timeout.connect(_refresh_patrols)
	timer.start(REFRESH_INTERVAL_S)
