extends "res://source/match/units/actions/Action.gd"

const RANGE_MARGIN := 0.1
## 炮口与落点方向的最大允许偏差（度）与未对准重试间隔（2026-09-06 战斗手感）。
const AIM_THRESHOLD_DEG = 10.0
const AIM_RETRY_INTERVAL_S = 1.0 / 15.0
const STATIONARY_TURN_SPEED_DEG_PER_SEC = 90.0

var _target_position: Vector3
var _shot_timer: Timer

@onready var _unit = Utils.NodeEx.find_parent_with_group(self, "units")
@onready var _movement = _unit.find_child("Movement")
@onready var _projectile_runtime = _unit.find_parent("Match").get_node("ProjectileRuntime")


## 创建持续攻击纯地面坐标的显式订单 Action。
func _init(target_position: Vector3):
	_target_position = target_position


## 根据距离先进入射程，再按单位攻击间隔持续开火。
func _ready():
	_shot_timer = Timer.new()
	_shot_timer.one_shot = true
	_shot_timer.timeout.connect(_fire_and_reschedule)
	add_child(_shot_timer)
	_begin_or_resume_attack()


## 无论因 Stop、替换命令还是单位销毁退出，都必须撤销接近射程阶段留下的导航目标。
func _exit_tree():
	if _movement != null:
		_movement.stop()


## 若目标超出射程则移动到射程边缘，否则立即安排开火。
func _begin_or_resume_attack():
	var planar_target := _target_position * Vector3(1.0, 0.0, 1.0)
	var offset: Vector3 = _unit.global_position_yless - planar_target
	if offset.length() > _unit.attack_range:
		var approach_direction: Vector3 = offset.normalized()
		var approach_position: Vector3 = _target_position + approach_direction * (
			_unit.attack_range - RANGE_MARGIN
		)
		approach_position.y = _unit.global_position.y
		_movement.movement_finished.connect(_on_approach_finished, CONNECT_ONE_SHOT)
		_movement.move(approach_position)
		return
	_schedule_next_shot()


## 到达射程边缘后开始持续开火。
func _on_approach_finished():
	if is_inside_tree():
		_schedule_next_shot()


## 行进阶段朝向由 Movement 控制；进入射程站定后限速转向落点。
func _physics_process(delta):
	if _movement != null and _movement._is_moving_actively():
		return
	var to_target: Vector3 = (_target_position - _unit.global_position) * Vector3(1, 0, 1)
	if to_target.length() < 0.05:
		return
	var turn_speed := STATIONARY_TURN_SPEED_DEG_PER_SEC
	if _movement != null:
		turn_speed = maxf(_movement.max_turn_speed_deg_per_sec, 1.0)
	var target_yaw: float = atan2(-to_target.x, -to_target.z)
	var current_yaw: float = _unit.global_transform.basis.get_euler().y
	var yaw_diff: float = angle_difference(current_yaw, target_yaw)
	if absf(yaw_diff) < 0.01:
		return
	var max_step: float = deg_to_rad(turn_speed) * delta
	var new_yaw: float = current_yaw + clampf(yaw_diff, -max_step, max_step)
	_unit.global_transform = Transform3D(Basis(Vector3.UP, new_yaw), _unit.global_transform.origin)


## 按全局武器冷却安排下一发，防止切换命令重置射速。
func _schedule_next_shot():
	var now := _simulation_msec()
	var available_at: int = _unit.get_meta("next_attack_availability_time", now)
	_shot_timer.start(max(0, available_at - now) / 1000.0)


## 炮口对准落点才发射；未对准则短间隔重试，不重置武器冷却。
func _fire_and_reschedule():
	if not is_inside_tree():
		return
	if _aim_error_degrees() > AIM_THRESHOLD_DEG:
		_shot_timer.start(AIM_RETRY_INTERVAL_S)
		return
	_unit.set_meta(
		"next_attack_availability_time",
		_simulation_msec() + int(_unit.attack_interval * 1000.0)
	)
	_spawn_shot_visual()
	_shot_timer.start(_unit.attack_interval)


## 车体正前方（-Z）与落点方向的水平夹角（度）。
func _aim_error_degrees() -> float:
	var to_target: Vector3 = (_target_position - _unit.global_position) * Vector3(1, 0, 1)
	if to_target.length() < 0.05:
		return 0.0
	var forward: Vector3 = (-_unit.global_transform.basis.z) * Vector3(1, 0, 1)
	return rad_to_deg(forward.normalized().angle_to(to_target.normalized()))


## 通过 Match 级运行时生成独立投射物，伤害延后到视觉命中时刻结算。
func _spawn_shot_visual():
	_projectile_runtime.LaunchGround(_unit, _target_position)


func _simulation_msec() -> int:
	return _unit.find_parent("Match").get_simulation_msec()
