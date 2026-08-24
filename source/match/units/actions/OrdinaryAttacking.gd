extends "res://source/match/units/actions/Action.gd"

signal attack_ended(reason)

const AttackingWhileInRange = preload(
	"res://source/match/units/actions/AttackingWhileInRange.gd"
)
const FollowingToReachDistance = preload(
	"res://source/match/units/actions/FollowingToReachDistance.gd"
)

var _target_unit = null
var _sub_action = null

@onready var _unit = Utils.NodeEx.find_parent_with_group(self, "units")


func _init(target_unit):
	_target_unit = target_unit


func _ready():
	_target_unit.tree_exiting.connect(_on_target_unit_removed)
	_attack_or_move_closer()


func _to_string():
	return "{0}({1})".format([super(), str(_sub_action) if _sub_action != null else ""])


func _target_in_range() -> bool:
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
	attack_ended.emit("TargetLost")
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
