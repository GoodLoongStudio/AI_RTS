extends "res://source/match/units/actions/Action.gd"

const RANGE_CHECK_INTERVAL = 1.0 / 60.0 * 10.0

var _target_unit = null
var _one_shot_timer = null
var _range_check_timer = null

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
	_setup_one_shot_timer()
	_setup_range_check_timer()
	_schedule_hit()


func _physics_process(_delta):
	if _unit_movement_trait == null:
		_rotate_unit_towards_target()  # stationary units can rotate every frame


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


func _rotate_unit_towards_target():
	var look_target := Vector3(
		_target_unit.global_position.x, _unit.global_position.y, _target_unit.global_position.z
	)
	if look_target.is_equal_approx(_unit.global_position):
		return
	_unit.global_transform = _unit.global_transform.looking_at(look_target, Vector3(0, 1, 0))


func _schedule_hit():
	var now = Time.get_ticks_msec()
	var next_attack_availability_time = _unit.get_meta("next_attack_availability_time", now)
	if next_attack_availability_time > now:
		var delay_millis = next_attack_availability_time - now
		_one_shot_timer.start(delay_millis / 1000.0)
	else:
		_hit_target()


func _hit_target():
	if _teardown_if_out_of_range():
		return
	_unit.set_meta(
		"next_attack_availability_time", Time.get_ticks_msec() + int(_unit.attack_interval * 1000.0)
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
	_rotate_unit_towards_target()
	_schedule_hit()
