extends "res://source/match/units/actions/Action.gd"

const AttackingWhileInRange = preload("res://source/match/units/actions/AttackingWhileInRange.gd")
const FollowingToReachDistance = preload(
	"res://source/match/units/actions/FollowingToReachDistance.gd"
)

const POLICY_REFRESH_INTERVAL := 1.0 / 6.0
const AGGRESSIVE_MAX_CHASE_DISTANCE_FACTOR := 2.0

var _target_unit = null
var _sub_action = null
var _engagement_origin := Vector3.ZERO
var _policy_timer: Timer = null
@onready var _unit = Utils.NodeEx.find_parent_with_group(self, "units")
@onready var _command_runtime = _unit.find_parent("Match").get_node("CommandRuntime")


static func is_applicable(source_unit, target_unit):
	return (
		source_unit.attack_range != null
		and "player" in target_unit
		and source_unit.player != target_unit.player
		and target_unit.movement_domain in source_unit.attack_domains
	)


func _init(target_unit):
	_target_unit = target_unit


func _ready():
	_engagement_origin = _unit.global_position
	_target_unit.tree_exited.connect(_on_target_unit_removed)
	_policy_timer = Timer.new()
	_policy_timer.timeout.connect(_enforce_combat_policy)
	add_child(_policy_timer)
	_policy_timer.start(POLICY_REFRESH_INTERVAL)
	_attack_or_move_closer()


func _to_string():
	return "{0}({1})".format([super(), str(_sub_action) if _sub_action != null else ""])


func _target_in_range():
	return (
		_unit.global_position_yless.distance_to(_target_unit.global_position_yless)
		<= _unit.attack_range
	)


func _attack_or_move_closer():
	_sub_action = (
		AttackingWhileInRange.new(_target_unit)
		if _target_in_range()
		else FollowingToReachDistance.new(_target_unit, _unit.attack_range)
	)
	_sub_action.tree_exited.connect(_on_sub_action_finished)
	add_child(_sub_action)
	_unit.action_updated.emit()


func _on_target_unit_removed():
	queue_free()


func _on_sub_action_finished():
	if (
		not is_inside_tree()
		or is_queued_for_deletion()
		or _unit == null
		or not is_instance_valid(_unit)
		or _unit.action != self
	):
		return
	if not is_instance_valid(_target_unit) or not _target_unit.is_inside_tree():
		return
	_attack_or_move_closer()


func _enforce_combat_policy():
	if _command_runtime.GetFirePolicy(_unit) == "HoldFire":
		queue_free()
		return
	var stance: String = _command_runtime.GetEngagementStance(_unit)
	# 回基地姿态不允许自主追击；权威姿态切换时立即释放旧追击，
	# 由命令桥接创建的 ReturningToBase 动作接管移动。
	if stance == "ReturnToBase":
		queue_free()
		return
	if stance == "HoldGround" and not _target_in_range():
		queue_free()
		return
	if stance == "Guard":
		var guard_anchor: Vector3 = _command_runtime.GetGuardAnchor(_unit)
		if guard_anchor.is_finite() and (
			_target_unit.global_position_yless.distance_to(guard_anchor * Vector3(1, 0, 1))
			> _unit.sight_range
		):
			queue_free()
		return
	if (
		stance == "Aggressive"
		and _unit.global_position_yless.distance_to(_engagement_origin * Vector3(1, 0, 1))
		> _unit.sight_range * AGGRESSIVE_MAX_CHASE_DISTANCE_FACTOR
	):
		queue_free()
