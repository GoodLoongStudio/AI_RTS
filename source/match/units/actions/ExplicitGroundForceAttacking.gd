extends "res://source/match/units/actions/Action.gd"

const RANGE_MARGIN := 0.1

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


## 按全局武器冷却安排下一发，防止切换命令重置射速。
func _schedule_next_shot():
	var now := Time.get_ticks_msec()
	var available_at: int = _unit.get_meta("next_attack_availability_time", now)
	_shot_timer.start(max(0, available_at - now) / 1000.0)


## 发射一发地面命中，并继续维持该订单。
func _fire_and_reschedule():
	if not is_inside_tree():
		return
	_rotate_towards_target()
	_unit.set_meta(
		"next_attack_availability_time",
		Time.get_ticks_msec() + int(_unit.attack_interval * 1000.0)
	)
	_spawn_shot_visual()
	_shot_timer.start(_unit.attack_interval)


## 令单位面向落点，避免炮口表现与攻击方向相反。
func _rotate_towards_target():
	var look_target := Vector3(_target_position.x, _unit.global_position.y, _target_position.z)
	if not look_target.is_equal_approx(_unit.global_position):
		_unit.global_transform = _unit.global_transform.looking_at(look_target, Vector3.UP)


## 通过 Match 级运行时生成独立投射物，伤害延后到视觉命中时刻结算。
func _spawn_shot_visual():
	_projectile_runtime.LaunchGround(_unit, _target_position)
