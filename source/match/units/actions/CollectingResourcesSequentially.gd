extends "res://source/match/units/actions/Action.gd"

signal task_ended(reason)

enum State { NULL, MOVING_TO_RESOURCE, COLLECTING, MOVING_TO_CC }

const CommandCenter = preload("res://source/match/units/CommandCenter.gd")
const CollectingResourcesWhileInRange = preload(
	"res://source/match/units/actions/CollectingResourcesWhileInRange.gd"
)
const MovingToUnit = preload("res://source/match/units/actions/MovingToUnit.gd")
const Worker = preload("res://source/match/units/Worker.gd")
const ResourceUnit = preload("res://source/match/units/non-player/ResourceUnit.gd")

var _state := State.NULL
var _state_locked = false
var _resource_unit = null
var _cc_unit = null
var _sub_action = null
var _is_suspended := false
var _terminal_reason_after_delivery := ""

@onready var _unit = Utils.NodeEx.find_parent_with_group(self, "units")


static func is_applicable(source_unit, target_unit):
	return (
		(source_unit is Worker and target_unit is ResourceUnit)
		or (source_unit is Worker and target_unit is CommandCenter and target_unit.is_constructed())
	)


func _init(unit):
	if unit is ResourceUnit:
		_set_resource_unit(unit)
	elif unit is CommandCenter:
		_set_cc_unit(unit)


func _ready():
	if _resource_unit != null:
		_change_state_to(State.MOVING_TO_RESOURCE)
	elif _cc_unit != null:
		_change_state_to(State.MOVING_TO_CC)


func _to_string():
	return "{0}({1})".format([super(), str(_sub_action) if _sub_action != null else ""])


func get_resource_unit():
	return _resource_unit


func _change_state_to(new_state):
	assert(not _state_locked, "changing state during transition is not implemented")
	_state_locked = true
	_exit_state(_state)
	_enter_state(new_state)
	_state = new_state
	_state_locked = false


func _exit_state(_a_state):
	pass


func _enter_state(state):
	match state:
		State.MOVING_TO_RESOURCE:
			if _resource_unit == null:
				_finish_task(
					_terminal_reason_after_delivery
					if not _terminal_reason_after_delivery.is_empty()
					else "TargetLost"
				)
				return
			_sub_action = MovingToUnit.new(_resource_unit)
			_sub_action.tree_exited.connect(_on_sub_action_finished, CONNECT_DEFERRED)
			add_child(_sub_action)
			_unit.action_updated.emit()
		State.COLLECTING:
			assert(
				CollectingResourcesWhileInRange.is_applicable(_unit, _resource_unit),
				"the action should apply at this point"
			)
			_sub_action = CollectingResourcesWhileInRange.new(_resource_unit)
			_sub_action.tree_exited.connect(_on_sub_action_finished, CONNECT_DEFERRED)
			add_child(_sub_action)
			_unit.action_updated.emit()
		State.MOVING_TO_CC:
			if not _set_cc_unit(_find_cc_closest_to_unit(_unit)):
				return
			_sub_action = MovingToUnit.new(_cc_unit)
			_sub_action.tree_exited.connect(_on_sub_action_finished, CONNECT_DEFERRED)
			add_child(_sub_action)
			_unit.action_updated.emit()


func _set_resource_unit(resource_unit):
	if resource_unit == null:
		queue_free()
		return false
	assert(resource_unit != _resource_unit, "it's not possible to set the same unit")
	_resource_unit = resource_unit
	_resource_unit.tree_exited.connect(_on_resource_unit_removed)
	return true


func _set_cc_unit(cc_unit):
	if cc_unit == null:
		queue_free()
		return false
	if cc_unit != _cc_unit:
		cc_unit.tree_exited.connect(_on_cc_unit_removed)
	_cc_unit = cc_unit
	return true


func _transfer_collected_resources_to_player():
	var delivery = {
		"resource_a": _unit.resource_a,
		"resource_b": _unit.resource_b,
	}
	print("[GATHER] 交付 resource_a=%s resource_b=%s player=%s" % [str(_unit.resource_a), str(_unit.resource_b), _unit.player.name])
	var accepted = _unit.player.add_resources(delivery, "WorkerDelivery", _unit)
	assert(accepted, "a valid Worker delivery must reach its authoritative resource account")
	if not accepted:
		return
	_unit.resource_a = 0
	_unit.resource_b = 0


static func _find_cc_closest_to_unit(unit):
	var ccs_of_the_same_player = unit.get_tree().get_nodes_in_group("units").filter(
		func(a_unit):
			return (
				a_unit is CommandCenter and a_unit.player == unit.player and a_unit.is_constructed()
			)
	)
	if ccs_of_the_same_player.is_empty():
		return null
	var ccs_sorted_by_distance = ccs_of_the_same_player.map(
		func(a_unit):
			return {
				"distance":
				(unit.global_position * Vector3(1, 0, 1)).distance_to(
					a_unit.global_position * Vector3(1, 0, 1)
				),
				"cc": a_unit
			}
	)
	ccs_sorted_by_distance.sort_custom(func(a, b): return a["distance"] < b["distance"])
	return ccs_sorted_by_distance[0]["cc"]


func _handle_sub_action_finished_while_moving_to_resource():
	if _resource_unit == null:
		if _unit.resource_a + _unit.resource_b > 0:
			_change_state_to(State.MOVING_TO_CC)
		else:
			_finish_task(
				_terminal_reason_after_delivery
				if not _terminal_reason_after_delivery.is_empty()
				else "TargetLost"
			)
		return
	# resource reached
	if not _unit.is_full():
		print("[GATHER] 到达资源点, 开始采集 unit=", _unit.name)
		_change_state_to(State.COLLECTING)
	else:
		_change_state_to(State.MOVING_TO_CC)


func _handle_sub_action_finished_while_collecting():
	if _resource_unit == null:
		if _unit.resource_a + _unit.resource_b > 0:
			_change_state_to(State.MOVING_TO_CC)
		else:
			_finish_task(
				_terminal_reason_after_delivery
				if not _terminal_reason_after_delivery.is_empty()
				else "TargetLost"
			)
		return
	# react to resource not being in range anymore
	if not _unit.is_full() and not Utils.Match.Unit.Movement.units_adhere(_unit, _resource_unit):
		_change_state_to(State.MOVING_TO_RESOURCE)
		return
	# finished collecting
	_change_state_to(State.MOVING_TO_CC)


func _handle_sub_action_finished_while_moving_to_cc():
	# react to cc removal
	if _cc_unit == null or not _cc_unit.is_constructed():
		if _set_cc_unit(_find_cc_closest_to_unit(_unit)):
			_change_state_to(State.MOVING_TO_CC)
		return
	_transfer_collected_resources_to_player()
	if not _terminal_reason_after_delivery.is_empty():
		_finish_task(_terminal_reason_after_delivery)
		return
	_change_state_to(State.MOVING_TO_RESOURCE)


func _on_sub_action_finished():
	if not is_inside_tree() or _is_suspended:
		return
	_sub_action = null
	_unit.action_updated.emit()
	match _state:
		State.MOVING_TO_RESOURCE:
			_handle_sub_action_finished_while_moving_to_resource()
		State.COLLECTING:
			_handle_sub_action_finished_while_collecting()
		State.MOVING_TO_CC:
			_handle_sub_action_finished_while_moving_to_cc()


func _on_resource_unit_removed():
	_terminal_reason_after_delivery = "Completed" if _is_resource_depleted() else "TargetLost"
	_resource_unit = null


func _on_cc_unit_removed():
	_cc_unit = null


## 暂停整个采集任务并保留当前阶段、目标与 Worker 已携带资源。
func suspend_task() -> bool:
	if _is_suspended:
		return true
	_is_suspended = true
	if _sub_action != null:
		if _sub_action.tree_exited.is_connected(_on_sub_action_finished):
			_sub_action.tree_exited.disconnect(_on_sub_action_finished)
		remove_child(_sub_action)
		_sub_action.queue_free()
		_sub_action = null
	_unit.find_child("Movement").stop()
	_unit.action_updated.emit()
	return true


## 返回当前采集任务是否已由统一 Stop 暂停，供测试与迁移期诊断读取。
func is_task_suspended() -> bool:
	return _is_suspended


## 判断正在退出的资源节点是否因为存量归零而正常耗尽。
func _is_resource_depleted() -> bool:
	if _resource_unit == null:
		return false
	if "resource_a" in _resource_unit:
		return _resource_unit.resource_a <= 0
	if "resource_b" in _resource_unit:
		return _resource_unit.resource_b <= 0
	return false


## 发布采集任务终态并结束组合 Action；资源入账只允许在返程交付函数中发生。
func _finish_task(reason: String):
	if not is_inside_tree():
		return
	task_ended.emit(reason)
	queue_free()
