extends "res://source/match/units/actions/Action.gd"

const AttackingWhileInRange = preload(
	"res://source/match/units/actions/AttackingWhileInRange.gd"
)
const AutoAttacking = preload("res://source/match/units/actions/AutoAttacking.gd")

const TARGET_REFRESH_INTERVAL := 1.0 / 6.0
const GUARD_DETECTION_RANGE_FACTOR := 1.25
const GUARD_LEASH_RANGE_FACTOR := 1.0

var _destination: Vector3
var _engagement_action = null
var _engagement_target = null
var _engagement_anchor := Vector3.ZERO
var _refresh_timer: Timer = null
var _is_transitioning := false

@onready var _unit = Utils.NodeEx.find_parent_with_group(self, "units")
@onready var _movement_trait = _unit.find_child("Movement")
@onready var _command_runtime = _unit.find_parent("Match").get_node("CommandRuntime")


func _init(destination: Vector3):
	_destination = destination


func _ready():
	_movement_trait.movement_finished.connect(_on_movement_finished)
	_refresh_timer = Timer.new()
	_refresh_timer.timeout.connect(_refresh)
	add_child(_refresh_timer)
	_refresh_timer.start(TARGET_REFRESH_INTERVAL)
	_resume_advancing()
	_refresh()


func _exit_tree():
	if is_inside_tree():
		_movement_trait.stop()


## 立即应用交战姿态或停火变化；停火会退出临时交战并恢复原推进目标。
func refresh_combat_policy():
	_refresh()


func _refresh():
	if _command_runtime.GetFirePolicy(_unit) == "HoldFire":
		_resume_advancing()
		return
	if _engagement_action != null:
		if not _may_continue_engagement():
			_resume_advancing()
		return
	var target = _pick_target()
	if target != null:
		_begin_engagement(target)


func _pick_target():
	var stance: String = _command_runtime.GetEngagementStance(_unit)
	var detection_range: float = _unit.sight_range
	if stance == "HoldGround":
		detection_range = _unit.attack_range
	elif stance == "Guard":
		detection_range = min(
			_unit.sight_range, _unit.attack_range * GUARD_DETECTION_RANGE_FACTOR
		)
	var targets = get_tree().get_nodes_in_group("units").filter(
		func(target): return _is_legal_target(target, detection_range)
	)
	if targets.is_empty():
		return null
	targets.sort_custom(
		func(a, b):
			return _unit.global_position_yless.distance_squared_to(a.global_position_yless) < (
				_unit.global_position_yless.distance_squared_to(b.global_position_yless)
			)
	)
	return targets[0]


func _is_legal_target(target, maximum_distance: float) -> bool:
	return (
		target != null
		and is_instance_valid(target)
		and target.is_inside_tree()
		and target.player != _unit.player
		and target.movement_domain in _unit.attack_domains
		and _unit.global_position_yless.distance_to(target.global_position_yless)
		<= maximum_distance
	)


func _begin_engagement(target):
	_engagement_target = target
	_engagement_anchor = _unit.global_position
	# 先建立交战状态，再停止导航，避免 navigation_finished 在同一帧把父 Action 误判为已到达。
	var stance: String = _command_runtime.GetEngagementStance(_unit)
	_engagement_action = (
		AttackingWhileInRange.new(target)
		if stance == "HoldGround"
		else AutoAttacking.new(target)
	)
	_engagement_action.tree_exited.connect(_on_engagement_finished)
	_movement_trait.stop()
	# 固守交战必须同时暂停导航和避障速度，保证底盘不离开接敌点。
	if stance == "HoldGround":
		_movement_trait.suspend_motion()
	add_child(_engagement_action)
	_unit.action_updated.emit()


func _may_continue_engagement() -> bool:
	if not _is_legal_target(_engagement_target, INF):
		return false
	var stance: String = _command_runtime.GetEngagementStance(_unit)
	if stance == "HoldGround":
		return _unit.global_position_yless.distance_to(
			_engagement_target.global_position_yless
		) <= _unit.attack_range
	if stance == "Guard":
		return _engagement_target.global_position_yless.distance_to(
			_engagement_anchor * Vector3(1, 0, 1)
		) <= _unit.attack_range * GUARD_LEASH_RANGE_FACTOR
	return true


func _resume_advancing():
	_movement_trait.resume_motion()
	if _engagement_action != null and is_instance_valid(_engagement_action):
		_is_transitioning = true
		if _engagement_action.tree_exited.is_connected(_on_engagement_finished):
			_engagement_action.tree_exited.disconnect(_on_engagement_finished)
		_engagement_action.free()
		_is_transitioning = false
	_engagement_action = null
	_engagement_target = null
	_movement_trait.move(_destination)
	_unit.action_updated.emit()


func _on_engagement_finished():
	if _is_transitioning or not is_inside_tree():
		return
	_engagement_action = null
	_engagement_target = null
	_resume_advancing.call_deferred()


func _on_movement_finished():
	if _engagement_action == null:
		queue_free()
