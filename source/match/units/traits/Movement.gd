extends NavigationAgent3D

signal movement_finished
## 主动移动结束原因：Arrived 或 Unreachable，供命令订单终态回传。
signal movement_ended(reason)
signal passive_movement_started
signal passive_movement_finished

const INITIAL_DISPERSION_FACTOR = 0.1

const STUCK_PREVENTION_ENABLED = true
const STUCK_PREVENTION_WINDOW_SIZE = 10  # number of frames for accumulating distance traveled
const STUCK_PREVENTION_THRESHOLD = 0.3  # fraction of expected distance traveled at full speed
const STUCK_PREVENTION_SIDE_MOVES = 15  # number of forced moves to the side if stuck
const STUCK_RECOVERY_MAX_CYCLES = 3
const NO_PROGRESS_FRAMES_BEFORE_UNREACHABLE = 180
const OSCILLATION_FLIPS_BEFORE_UNREACHABLE = 6

const ROTATION_LOW_PASS_FILTER_ENABLED = true
const ROTATION_LOW_PASS_FILTER_WINDOW_SIZE = 10  # number of frames for accumulating directions
const ROTATION_LOW_PASS_FILTER_VELOCITY_THRESHOLD = 0.01  # velocities below will be dropped

const PASSIVE_MOVEMENT_TRACKING_ENABLED = true
const NAVIGATION_ALIGNMENT_MAX_FRAMES = 180
## clamp 允许的最大吸附距离：只用于"把障碍内目标贴到边缘"级别的小修正。
const CLAMP_MAX_SNAP_DISTANCE_M = 5.0

@export var domain = Constants.Match.Navigation.Domain.TERRAIN
@export var speed: float = 4.0
## 平滑转向的最大角速度（度/秒）；0 以下视为无效并回退默认。由平衡配置按单位类型注入。
@export var max_turn_speed_deg_per_sec: float = 360.0
@export_range(0.05, 1.0) var reverse_speed_multiplier: float = 0.65

var _interim_speed: float = 0.0
var _last_physics_delta: float = 1.0 / 60.0
var _face_target := Vector3.INF
var _is_tactical_withdrawal := false

var _stuck_prevention_window = []
var _total_velocity_in_stuck_prevention_window = 0.0
var _number_of_forced_side_moves_left = 0
var _stuck_recovery_cycles := 0
var _best_distance_to_target := INF
var _frames_without_progress := 0
var _last_planar_direction := Vector3.ZERO
var _direction_flips := 0
var _movement_end_emitted := false

var _rotation_low_pass_filter_window = []
var _total_direction_in_the_low_pass_filter_window = Vector3.ZERO
var _previously_set_global_transform_of_unit = null

var _passive_movement_detected = false
var _navigation_initialized := false
var _pending_target = null
var _skip_initial_dispersion := false

@onready var _match = find_parent("Match")
@onready var _unit = get_parent()


func _physics_process(delta):
	_last_physics_delta = delta
	if NetSession.is_client_puppet():
		return
	var speed_multiplier := reverse_speed_multiplier if _is_tactical_withdrawal else 1.0
	_interim_speed = speed * speed_multiplier * delta
	var fake_direction = _get_fake_direction_due_to_stuck_prevention()
	if fake_direction != null:
		set_velocity(fake_direction * _interim_speed)
		return
	var next_path_position: Vector3 = get_next_path_position()
	var current_agent_position: Vector3 = _unit.global_transform.origin
	var new_velocity: Vector3 = (
		(next_path_position - current_agent_position).normalized() * _interim_speed
	)
	set_velocity(new_velocity)


func _ready():
	if _match.navigation == null or not _match.is_node_ready():
		await _match.ready
	velocity_computed.connect(_on_velocity_computed)
	navigation_finished.connect(_on_navigation_finished)
	_apply_crowd_avoidance_defaults()
	set_navigation_map(_match.navigation.get_navigation_map_rid_by_domain(domain))
	target_position = Vector3.INF
	set_velocity(Vector3.ZERO)
	_finish_navigation_initialization()


func move(movement_target: Vector3):
	movement_target = _clamp_to_reachable(movement_target)
	_is_tactical_withdrawal = false
	_reset_stability_state()
	if not _navigation_initialized:
		_pending_target = movement_target
		_skip_initial_dispersion = true
	target_position = movement_target


## 沿导航路径倒车；车尾对齐每一帧的安全速度方向，因此路径转弯会更新朝向。
func tactical_withdraw(movement_target: Vector3):
	movement_target = _clamp_to_reachable(movement_target)
	_is_tactical_withdrawal = true
	_reset_stability_state()
	if not _navigation_initialized:
		_pending_target = movement_target
		_skip_initial_dispersion = true
	target_position = movement_target


## 把目标点限制到导航网格最近可达点（2026-09-02）：
## 点击建筑/障碍内部时，阵位散布或手点目标可能落在占位内，导航查询会判
## Unreachable 让单位半路停（"点中间不贴近就停了"）。clamp 后单位走到
## 障碍边缘贴住，等价于从自己一侧贴近点击点。
func _clamp_to_reachable(target: Vector3) -> Vector3:
	var nav_map := get_navigation_map()
	if not nav_map.is_valid():
		return target
	var closest_owner := NavigationServer3D.map_get_closest_point_owner(nav_map, target)
	if not closest_owner.is_valid():
		# 开局竞态防护(2026-09-03): 导航网格尚未烘焙同步时 closest 点可能退化为
		# 原点附近, 把目标钳到 (0,0) 会让 AI 工人开局横穿地图绕到地图角。
		# 网格为空时保持原目标, 导航代理会直线走向目标(平坦地图等价正确)。
		return target
	var closest := NavigationServer3D.map_get_closest_point(nav_map, target)
	if not closest.is_finite():
		return target
	# clamp 的语义是"把目标从障碍内贴到边缘"，只应产生小距离修正；
	# 部分烘焙网格会给出远距离的错误吸附点，此时保持原目标更安全。
	if closest.distance_to(target) > CLAMP_MAX_SNAP_DISTANCE_M:
		return target
	return closest


func stop():
	target_position = Vector3.INF
	_is_tactical_withdrawal = false
	_reset_stability_state()
	if not _navigation_initialized:
		_pending_target = null
		_skip_initial_dispersion = true
	set_velocity(Vector3.ZERO)


## 暂停所有主动与避障位移，用于必须保持接敌点的固守交战。
func suspend_motion():
	stop()
	set_velocity(Vector3.ZERO)
	avoidance_enabled = false
	set_physics_process(false)


## 恢复导航与避障更新；调用方随后应重新提交明确导航目标。
func resume_motion():
	avoidance_enabled = true
	set_physics_process(true)


## 温柔避障：只躲近处邻居并提前让行，避免大部队互相顶牛打转（2026-09-02 调参）。
func _apply_crowd_avoidance_defaults():
	avoidance_enabled = true
	if neighbor_distance < 1.0:
		neighbor_distance = 3.0
	if max_neighbors < 8:
		max_neighbors = 16
	if time_horizon_agents < 1.0:
		time_horizon_agents = 4.5


## 等待运行时 NavMesh 出现可用 Region 后再对齐单位，避免空中地图异步烘焙竞态。
func _align_unit_position_to_navigation() -> bool:
	var navigation_map := get_navigation_map()
	var source_position: Vector3 = get_parent().global_transform.origin
	for _frame in range(NAVIGATION_ALIGNMENT_MAX_FRAMES):
		await get_tree().process_frame
		var closest_point_owner := NavigationServer3D.map_get_closest_point_owner(
			navigation_map, source_position
		)
		if not closest_point_owner.is_valid():
			continue
		_unit.global_transform.origin = (
			NavigationServer3D.map_get_closest_point(navigation_map, source_position)
			- Vector3(0, path_height_offset, 0)
		)
		return true
	push_warning("Navigation alignment timed out for %s; preserving authored position" % _unit.name)
	return false


## 非阻塞完成导航对齐，并恢复初始化期间收到的最后一个显式移动目标。
func _finish_navigation_initialization():
	await _align_unit_position_to_navigation()
	_navigation_initialized = true
	if _pending_target != null:
		target_position = _pending_target
		_pending_target = null
		return
	if _skip_initial_dispersion:
		return
	move(
		(
			_unit.global_position
			+ Vector3(randf(), 0, randf()).normalized() * INITIAL_DISPERSION_FACTOR
		)
	)


func _is_moving_actively():
	return get_next_path_position() != _unit.global_position


func _get_fake_direction_due_to_stuck_prevention():
	if (
		not STUCK_PREVENTION_ENABLED
		or not _is_moving_actively()
		or _number_of_forced_side_moves_left == 0
	):
		return null
	_number_of_forced_side_moves_left -= 1
	var next_path_position: Vector3 = get_next_path_position()
	var direction_to_target = (next_path_position - _unit.global_position).normalized()
	var current_navigation_path = get_current_navigation_path()
	var current_navigation_path_index = get_current_navigation_path_index()
	if current_navigation_path.size() <= 1 or current_navigation_path_index == 0:
		return direction_to_target.rotated(Vector3.UP, PI / 2.0)
	# rotate +90*/-90* and choose the one that goes further from path
	var option_a = direction_to_target.rotated(Vector3.UP, PI / 2.0)
	var option_b = direction_to_target.rotated(Vector3.UP, -PI / 2.0)
	var previous_path_position = current_navigation_path[current_navigation_path_index - 1]
	if (
		(_unit.global_position + option_a).distance_to(previous_path_position)
		> (_unit.global_position + option_b).distance_to(previous_path_position)
	):
		return option_a
	return option_b


func _update_stuck_prevention(safe_velocity: Vector3):
	if not _is_moving_actively():
		return
	_stuck_prevention_window.append(safe_velocity.length())
	_total_velocity_in_stuck_prevention_window += safe_velocity.length()
	if _stuck_prevention_window.size() > STUCK_PREVENTION_WINDOW_SIZE:
		_total_velocity_in_stuck_prevention_window -= _stuck_prevention_window.pop_front()
	var stuck_prevention_threshold = (
		_interim_speed * STUCK_PREVENTION_WINDOW_SIZE * STUCK_PREVENTION_THRESHOLD
	)
	if (
		_stuck_prevention_window.size() == STUCK_PREVENTION_WINDOW_SIZE
		and _total_velocity_in_stuck_prevention_window < stuck_prevention_threshold
	):
		_stuck_recovery_cycles += 1
		if _stuck_recovery_cycles > STUCK_RECOVERY_MAX_CYCLES:
			_fail_as_unreachable()
			return
		_number_of_forced_side_moves_left = STUCK_PREVENTION_SIDE_MOVES
		_stuck_prevention_window.clear()
		_total_velocity_in_stuck_prevention_window = 0.0


func _get_filtered_rotation_direction(safe_velocity: Vector3):
	var direction = safe_velocity.normalized()
	if (
		_previously_set_global_transform_of_unit != null
		and not _previously_set_global_transform_of_unit.is_equal_approx(_unit.global_transform)
	):
		# reset filter if a global_transform of unit was altered from the outside
		_rotation_low_pass_filter_window = []
		_total_direction_in_the_low_pass_filter_window = Vector3.ZERO
	if safe_velocity.length() >= ROTATION_LOW_PASS_FILTER_VELOCITY_THRESHOLD:
		_rotation_low_pass_filter_window.append(direction)
		_total_direction_in_the_low_pass_filter_window += direction
	if _rotation_low_pass_filter_window.size() > ROTATION_LOW_PASS_FILTER_WINDOW_SIZE:
		_total_direction_in_the_low_pass_filter_window -= (
			_rotation_low_pass_filter_window.pop_front()
		)
	if _rotation_low_pass_filter_window.size() == ROTATION_LOW_PASS_FILTER_WINDOW_SIZE:
		return (
			_total_direction_in_the_low_pass_filter_window
			/ float(ROTATION_LOW_PASS_FILTER_WINDOW_SIZE)
		)
	return direction


func _rotate_in_direction(direction: Vector3):
	if ROTATION_LOW_PASS_FILTER_ENABLED:
		direction = _get_filtered_rotation_direction(direction)
	if is_zero_approx(direction.length()):
		return
	# 平滑转向：按单位类型注入的最大角速度逐步逼近目标朝向，
	# 消除 looking_at 瞬时掉头（含 180° 调头/倒车切换）造成的视觉跳变。
	# 显式 float：经未类型化节点链取值在此上下文返回 Variant，:= 无法推断类型。
	var turn_speed: float = maxf(max_turn_speed_deg_per_sec, 1.0)
	var target_yaw: float = atan2(-direction.x, -direction.z)
	var current_yaw: float = _unit.global_transform.basis.get_euler().y
	var yaw_diff: float = angle_difference(current_yaw, target_yaw)
	if absf(yaw_diff) < 0.01:
		return
	var max_step: float = deg_to_rad(turn_speed) * _last_physics_delta
	var new_yaw: float = current_yaw + clampf(yaw_diff, -max_step, max_step)
	_unit.global_transform = Transform3D(
		Basis(Vector3.UP, new_yaw), _unit.global_transform.origin
	)


func _update_passive_movement_tracking(safe_velocity):
	if not PASSIVE_MOVEMENT_TRACKING_ENABLED:
		return
	if _is_moving_actively() or safe_velocity.is_zero_approx():
		if _passive_movement_detected:
			_passive_movement_detected = false
			passive_movement_finished.emit()
		return
	if not _passive_movement_detected:
		_passive_movement_detected = true
		passive_movement_started.emit()


func _on_velocity_computed(safe_velocity: Vector3):
	_update_stuck_prevention(safe_velocity)
	_update_progress_and_oscillation(safe_velocity)
	var chassis_direction := -safe_velocity if _is_tactical_withdrawal else safe_velocity
	var planar_direction := chassis_direction * Vector3(1, 0, 1)
	if not planar_direction.is_zero_approx():
		_face_target = Vector3.INF
		_rotate_in_direction(planar_direction)
	elif _face_target != Vector3.INF:
		_apply_pending_face_rotation()
	_unit.global_transform.origin = _unit.global_transform.origin.move_toward(
		_unit.global_transform.origin + safe_velocity, _interim_speed
	)
	_previously_set_global_transform_of_unit = _unit.global_transform
	_update_passive_movement_tracking(safe_velocity)


## 请求单位平滑转向面向指定位置（采集/交战对齐用）；移动开始后自动失效。
func face_towards(target_position: Vector3) -> void:
	_face_target = target_position


## 站定（速度为零）时按转速上限平滑逼近 face_towards 目标朝向。
func _apply_pending_face_rotation():
	var face_direction: Vector3 = (
		_face_target - _unit.global_transform.origin
	) * Vector3(1, 0, 1)
	if face_direction.length() < 0.2:
		_face_target = Vector3.INF
		return
	_rotate_in_direction(face_direction)


func _on_navigation_finished():
	var reason := _classify_navigation_end()
	target_position = Vector3.INF
	_emit_movement_end(reason)


## 导航结束时区分真正到达与最近可达点停下。
func _classify_navigation_end() -> String:
	if target_position == Vector3.INF:
		return "Arrived"
	if is_target_reachable():
		return "Arrived"
	return "Unreachable"


func _reset_stability_state():
	_stuck_prevention_window.clear()
	_total_velocity_in_stuck_prevention_window = 0.0
	_number_of_forced_side_moves_left = 0
	_stuck_recovery_cycles = 0
	_best_distance_to_target = INF
	_frames_without_progress = 0
	_last_planar_direction = Vector3.ZERO
	_direction_flips = 0
	_movement_end_emitted = false


func _planar_distance_to_target() -> float:
	if target_position == Vector3.INF:
		return 0.0
	return Vector2(_unit.global_position.x, _unit.global_position.z).distance_to(
		Vector2(target_position.x, target_position.z)
	)


func _update_progress_and_oscillation(safe_velocity: Vector3):
	if target_position == Vector3.INF or _movement_end_emitted:
		return
	var distance := _planar_distance_to_target()
	if distance < _best_distance_to_target - 0.05:
		_best_distance_to_target = distance
		_frames_without_progress = 0
	else:
		_frames_without_progress += 1
	var planar := safe_velocity * Vector3(1, 0, 1)
	if planar.length() >= ROTATION_LOW_PASS_FILTER_VELOCITY_THRESHOLD:
		var direction := planar.normalized()
		if (
			not _last_planar_direction.is_zero_approx()
			and direction.dot(_last_planar_direction) < -0.5
		):
			_direction_flips += 1
		_last_planar_direction = direction
	if _direction_flips >= OSCILLATION_FLIPS_BEFORE_UNREACHABLE:
		_fail_as_unreachable()
		return
	if (
		_frames_without_progress >= NO_PROGRESS_FRAMES_BEFORE_UNREACHABLE
		and not is_target_reachable()
	):
		_fail_as_unreachable()


func _fail_as_unreachable():
	if _movement_end_emitted:
		return
	target_position = Vector3.INF
	_is_tactical_withdrawal = false
	_number_of_forced_side_moves_left = 0
	set_velocity(Vector3.ZERO)
	_emit_movement_end("Unreachable")


func _emit_movement_end(reason: String):
	if _movement_end_emitted:
		return
	_movement_end_emitted = true
	movement_ended.emit(reason)
	movement_finished.emit()
