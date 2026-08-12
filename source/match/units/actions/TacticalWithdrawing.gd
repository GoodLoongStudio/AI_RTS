extends "res://source/match/units/actions/Action.gd"

const AttackingWhileInRange = preload(
	"res://source/match/units/actions/AttackingWhileInRange.gd"
)

const TARGET_REFRESH_INTERVAL := 1.0 / 6.0

var _target_position: Vector3
var _attack_action = null
var _target_timer: Timer = null

@onready var _unit = Utils.NodeEx.find_parent_with_group(self, "units")
@onready var _movement_trait = _unit.find_child("Movement")
@onready var _command_runtime = _unit.find_parent("Match").get_node("CommandRuntime")


func _init(target_position: Vector3):
	_target_position = target_position


func _ready():
	_movement_trait.tactical_withdraw(_target_position)
	_movement_trait.movement_finished.connect(_on_movement_finished)
	_target_timer = Timer.new()
	_target_timer.timeout.connect(_refresh_weapon_target)
	add_child(_target_timer)
	_target_timer.start(TARGET_REFRESH_INTERVAL)
	_refresh_weapon_target()


func _exit_tree():
	if is_inside_tree():
		_movement_trait.stop()


## 在撤退期间重新读取停火策略；停火会立即终止当前移动射击子行为。
func refresh_combat_policy():
	_refresh_weapon_target()


func _refresh_weapon_target():
	if not _unit.can_fire_while_moving or _command_runtime.GetFirePolicy(_unit) == "HoldFire":
		_clear_attack_action()
		return
	if _is_valid_target(_get_current_attack_target()):
		return
	_clear_attack_action()
	var targets = get_tree().get_nodes_in_group("units").filter(_is_valid_target)
	if targets.is_empty():
		return
	targets.sort_custom(
		func(a, b):
			return _unit.global_position_yless.distance_squared_to(a.global_position_yless) < (
				_unit.global_position_yless.distance_squared_to(b.global_position_yless)
			)
	)
	_attack_action = AttackingWhileInRange.new(targets[0])
	_attack_action.tree_exited.connect(_on_attack_action_exited)
	add_child(_attack_action)


func _is_valid_target(target) -> bool:
	if target == null or not is_instance_valid(target) or not target.is_inside_tree():
		return false
	if target.player == _unit.player or target.movement_domain not in _unit.attack_domains:
		return false
	var offset: Vector3 = (target.global_position_yless - _unit.global_position_yless)
	if offset.length() > _unit.attack_range or offset.is_zero_approx():
		return false
	var chassis_forward: Vector3 = -_unit.global_transform.basis.z * Vector3(1, 0, 1)
	var half_arc_radians: float = deg_to_rad(_unit.moving_weapon_arc_degrees * 0.5)
	return chassis_forward.normalized().angle_to(offset.normalized()) <= half_arc_radians


func _get_current_attack_target():
	if _attack_action == null or not is_instance_valid(_attack_action):
		return null
	return _attack_action.get("_target_unit")


func _clear_attack_action():
	if _attack_action != null and is_instance_valid(_attack_action):
		_attack_action.queue_free()
	_attack_action = null


func _on_attack_action_exited():
	_attack_action = null


func _on_movement_finished():
	queue_free()
