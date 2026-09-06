extends "res://source/match/units/actions/Action.gd"

const RANGE_CHECK_INTERVAL = 1.0 / 60.0 * 10.0
## 炮口与目标方向的最大允许偏差（度）：超出则继续转向、禁止开火（2026-09-06 战斗手感）。
const AIM_THRESHOLD_DEG = 10.0
## 炮口未对准时的重试间隔（秒）；重试不占用武器冷却。
const AIM_RETRY_INTERVAL_S = 1.0 / 15.0
## 无 Movement（炮塔类）的战斗转向速度（度/秒）：明显慢于车体，避免瞬时锁死。
const STATIONARY_TURN_SPEED_DEG_PER_SEC = 90.0
## 朝向容差对应的弧度阈值（约 0.6°），低于此视为已对准。
const AIM_ALIGNED_EPSILON_RAD = 0.01

var _target_unit = null
var _one_shot_timer = null
var _range_check_timer = null
var _stationary_aim_node: Node3D = null

@onready var _unit = Utils.NodeEx.find_parent_with_group(self, "units")
@onready var _unit_movement_trait = _unit.find_child("Movement")
@onready var _projectile_runtime = _unit.find_parent("Match").get_node("ProjectileRuntime")


func _init(target_unit):
	_target_unit = target_unit


func _ready():
	if _teardown_if_out_of_range():
		return
	_target_unit.tree_exited.connect(_on_target_unit_removed)
	if _unit_movement_trait != null:
		# non-stationary units must hold shooting as long as passive movement is active
		_unit_movement_trait.passive_movement_started.connect(_on_passive_movement_started)
		_unit_movement_trait.passive_movement_finished.connect(_on_passive_movement_finished)
	else:
		_stationary_aim_node = _find_stationary_aim_node()
	_setup_one_shot_timer()
	_setup_range_check_timer()
	_schedule_hit()


func _physics_process(delta):
	if not is_instance_valid(_target_unit):
		return
	if _unit_movement_trait != null and _unit_movement_trait._is_moving_actively():
		# 行进中车体朝向由 Movement 按速度方向控制，交战动作不抢转向权
		return
	_rotate_unit_towards_target(delta)


func _setup_one_shot_timer():
	_one_shot_timer = Timer.new()
	_one_shot_timer.one_shot = true
	_one_shot_timer.timeout.connect(_hit_target)
	add_child(_one_shot_timer)


func _setup_range_check_timer():
	_range_check_timer = Timer.new()
	_range_check_timer.timeout.connect(_teardown_if_out_of_range)
	add_child(_range_check_timer)
	_range_check_timer.start(RANGE_CHECK_INTERVAL)


## 炮塔类（无 Movement）的瞄准节点：与待机扫描（RotateRandomlyWhenLookingForTargets）
## 同一个炮管节点。战斗瞄准直接转炮管而非根节点——待机扫描会把炮管留在任意角度，
## 若只看根节点朝向，会出现"炮管指向侧面却已开火"的发射方向错误。
func _find_stationary_aim_node() -> Node3D:
	var idle_trait = _unit.find_child("RotateRandomlyWhenLookingForTargets", false, false)
	if idle_trait == null:
		return null
	var node_path: NodePath = idle_trait.get("node_to_rotate")
	if node_path.is_empty():
		return null
	# node_to_rotate 相对于 trait 节点（"../DetachTransform/..."），必须由 trait 解析；
	# 用单位根节点解析会越界拿不到节点，导致炮塔退回根节点旋转（炮管不瞄准）
	var aim_node = idle_trait.get_node_or_null(node_path)
	return aim_node if aim_node is Node3D else null


## 按限速平滑转向目标——按单位类型分派：
## 机动单位（坦克/步兵/飞机）：完全保持 3d7d0e43（战斗手感优化）时的车体转向实现，
## 用全局变换直写 + get_euler，行为与该版本逐字节一致，不做任何"优化"。
## 炮塔（无 Movement）：仅炮塔走 +Z 炮管节点旋转（修复发射方向问题的独立路径）。
func _rotate_unit_towards_target(delta: float):
	if _unit_movement_trait != null:
		_rotate_mobile_unit_towards_target(delta)
	else:
		_rotate_stationary_turret_towards_target(delta)


## 机动单位车体转向（3d7d0e43 原版实现，勿改动约定）。
func _rotate_mobile_unit_towards_target(delta: float):
	# 显式类型：经未类型化节点链取值返回 Variant，:= 无法推断（项目将推断警告当错误）
	var to_target: Vector3 = (
		(
			Vector3(_target_unit.global_position.x, _unit.global_position.y, _target_unit.global_position.z)
			- _unit.global_position
		)
		* Vector3(1, 0, 1)
	)
	if to_target.length() < 0.05:
		return
	var turn_speed := STATIONARY_TURN_SPEED_DEG_PER_SEC
	if _unit_movement_trait != null:
		turn_speed = maxf(_unit_movement_trait.max_turn_speed_deg_per_sec, 1.0)
	var target_yaw: float = atan2(-to_target.x, -to_target.z)
	var current_yaw: float = _unit.global_transform.basis.get_euler().y
	var yaw_diff: float = angle_difference(current_yaw, target_yaw)
	if absf(yaw_diff) < AIM_ALIGNED_EPSILON_RAD:
		return
	var max_step: float = deg_to_rad(turn_speed) * delta
	var new_yaw: float = current_yaw + clampf(yaw_diff, -max_step, max_step)
	_unit.global_transform = Transform3D(Basis(Vector3.UP, new_yaw), _unit.global_transform.origin)


## 炮塔炮管转向：Synty 炮塔模型炮管朝 **+Z**，直接旋转炮管节点，
## 正前方取炮管节点的 +Z——否则会出现"炮管背对目标却判已对准"的发射方向错误。
func _rotate_stationary_turret_towards_target(delta: float):
	var aim_node := _stationary_aim_node
	if aim_node == null:
		# 无待机扫描节点的建筑武器：退回车体 -Z 约定（保守默认）
		_rotate_mobile_unit_towards_target(delta)
		return
	# 显式类型：经未类型化节点链取值返回 Variant，:= 无法推断（项目将推断警告当错误）
	var to_target: Vector3 = (
		(
			Vector3(_target_unit.global_position.x, aim_node.global_position.y, _target_unit.global_position.z)
			- aim_node.global_position
		)
		* Vector3(1, 0, 1)
	)
	if to_target.length() < 0.05:
		return
	var target_yaw: float = atan2(to_target.x, to_target.z)
	var current_yaw: float = atan2(
		aim_node.global_transform.basis.z.x, aim_node.global_transform.basis.z.z
	)
	var yaw_diff: float = angle_difference(current_yaw, target_yaw)
	if absf(yaw_diff) < AIM_ALIGNED_EPSILON_RAD:
		return
	var max_step := deg_to_rad(STATIONARY_TURN_SPEED_DEG_PER_SEC) * delta
	var new_yaw: float = current_yaw + clampf(yaw_diff, -max_step, max_step)
	aim_node.global_rotation_degrees.y = rad_to_deg(new_yaw)


## 车体/炮管正前方与目标方向的水平夹角（度）；正前方约定同上（机动 -Z，炮塔炮管 +Z）。
func _aim_error_degrees() -> float:
	if _unit_movement_trait != null or _stationary_aim_node == null:
		return _mobile_aim_error_degrees()
	return _turret_aim_error_degrees()


## 机动单位：车体 -Z 与目标方向的水平夹角（度）。
func _mobile_aim_error_degrees() -> float:
	var to_target: Vector3 = (_target_unit.global_position - _unit.global_position) * Vector3(1, 0, 1)
	if to_target.length() < 0.05:
		return 0.0  # 目标在正上/下方，水平面无方向可对
	var forward: Vector3 = (-_unit.global_transform.basis.z) * Vector3(1, 0, 1)
	return rad_to_deg(forward.normalized().angle_to(to_target.normalized()))


## 炮塔：炮管节点 +Z 与目标方向的水平夹角（度）。
func _turret_aim_error_degrees() -> float:
	var aim_node := _stationary_aim_node
	var to_target: Vector3 = (
		(_target_unit.global_position - aim_node.global_position) * Vector3(1, 0, 1)
	)
	if to_target.length() < 0.05:
		return 0.0  # 目标在正上/下方（如防空对顶空），水平面无方向可对
	var forward: Vector3 = (aim_node.global_transform.basis.z) * Vector3(1, 0, 1)
	return rad_to_deg(forward.normalized().angle_to(to_target.normalized()))


func _schedule_hit():
	var now = _simulation_msec()
	var next_attack_availability_time = _unit.get_meta("next_attack_availability_time", now)
	if next_attack_availability_time > now:
		var delay_millis = next_attack_availability_time - now
		_one_shot_timer.start(delay_millis / 1000.0)
	else:
		_hit_target()


func _hit_target():
	if _teardown_if_out_of_range():
		return
	if _aim_error_degrees() > AIM_THRESHOLD_DEG:
		# 炮口尚未对准目标：不开火、不重置武器冷却，短间隔后重查
		_one_shot_timer.start(AIM_RETRY_INTERVAL_S)
		return
	_unit.set_meta(
		"next_attack_availability_time", _simulation_msec() + int(_unit.attack_interval * 1000.0)
	)
	_projectile_runtime.LaunchEntity(_unit, _target_unit)
	_schedule_hit()


func _teardown_if_out_of_range():
	if (
		_unit.global_position_yless.distance_to(_target_unit.global_position_yless)
		> _unit.attack_range
	):
		queue_free()
		return true
	return false


func _on_target_unit_removed():
	queue_free()


func _on_passive_movement_started():
	_one_shot_timer.stop()


func _on_passive_movement_finished():
	# 转向交给 _physics_process 的限速逐帧逼近（原先的瞬时 looking_at 已移除）
	_schedule_hit()


func _simulation_msec() -> int:
	return _unit.find_parent("Match").get_simulation_msec()
