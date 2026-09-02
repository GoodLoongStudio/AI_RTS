extends "res://source/match/units/actions/Action.gd"

## 持续回防姿态的表现层动作。
##
## 目标基地由服务器命令入口首次选择；动作仍会在服务器上周期性复核基地
## 是否存活，并在基地被摧毁或出现更近基地时重新选点。客户端傀儡不会运行
## Unit.action，因此不会产生第二份移动权威。
signal ended(reason)
signal return_to_base_ended(reason)

const CommandCenter = preload("res://source/match/units/CommandCenter.gd")

const TARGET_REFRESH_INTERVAL := 0.25
const ARRIVAL_EPSILON := 0.35
const RETRY_INTERVAL := 0.5
const MAX_REACHABILITY_RETRIES := 3

var _requested_base = null
var _base = null
var _movement = null
var _refresh_timer: Timer = null
var _moving := false
var _arrival_reported := false
var _retry_remaining := 0.0
var _reachability_retries := 0
var _ended := false
var _last_destination := Vector3.INF

@onready var _unit = Utils.NodeEx.find_parent_with_group(self, "units")


func _init(requested_base = null):
	_requested_base = requested_base


func _ready():
	if _unit == null and get_parent() != null:
		_unit = get_parent()
	_movement = _unit.find_child("Movement") if _unit != null else null
	if _movement == null:
		_emit_ended("NavigationUnavailable")
		queue_free()
		return

	if _movement.has_signal("movement_finished"):
		_movement.movement_finished.connect(_on_movement_finished)
	if _movement.has_signal("movement_ended"):
		_movement.movement_ended.connect(_on_movement_ended)

	_refresh_timer = Timer.new()
	_refresh_timer.one_shot = false
	_refresh_timer.timeout.connect(_on_refresh_timer_timeout)
	add_child(_refresh_timer)
	_refresh_timer.start(TARGET_REFRESH_INTERVAL)

	_set_base(_requested_base if _is_valid_base(_requested_base) else _find_nearest_base())
	# 延后一帧再开始移动/报告 Arrived；命令运行时需要先创建订单并连接
	# return_to_base_ended，避免单位已经在基地旁时丢失同步回调。
	call_deferred("_deferred_start")


func _exit_tree():
	if _movement != null and is_instance_valid(_movement) and is_inside_tree():
		_movement.stop()


## 交战姿态改变时由 UnitCommandRuntime 调用；离开回防姿态立即释放动作。
func refresh_combat_policy():
	if _unit == null:
		return
	var runtime = _unit.find_parent("Match").get_node_or_null("CommandRuntime")
	if runtime != null and runtime.GetEngagementStance(_unit) != "ReturnToBase":
		queue_free()


## 返回是否已经停在当前基地附近，供诊断和自动化测试使用。
func is_at_base() -> bool:
	return _base != null and is_instance_valid(_base) and _is_at_base(_base)


func _physics_process(delta):
	if _ended or _unit == null or not is_instance_valid(_unit) or _movement == null:
		return
	if _retry_remaining > 0.0:
		_retry_remaining = maxf(0.0, _retry_remaining - delta)
		return
	if not _is_valid_base(_base):
		_set_base(_find_nearest_base())
		_moving = false
		_arrival_reported = false
		if _base == null:
			_emit_ended("TargetLost")
			return
		_refresh_destination(true)
		return
	if _is_at_base(_base):
		if _moving:
			_movement.stop()
			_moving = false
		if not _arrival_reported:
			_emit_ended("Arrived")
	elif not _moving:
		_refresh_destination(false)


func _on_refresh_timer_timeout():
	if _ended or _unit == null or not is_instance_valid(_unit):
		return
	# 重新计算最近基地，保证扩建后也不会继续跑向旧基地。
	var nearest = _find_nearest_base()
	if nearest != null and (
		_base == null
		or not is_instance_valid(_base)
		or nearest != _base
		and nearest.global_position.distance_squared_to(_unit.global_position)
			< _base.global_position.distance_squared_to(_unit.global_position) - 0.01
	):
		_set_base(nearest)
		_moving = false
		_arrival_reported = false
		_refresh_destination(true)
		return
	if not _is_valid_base(_base):
		_set_base(nearest)
		_moving = false
		_arrival_reported = false
		if _base == null:
			_emit_ended("TargetLost")
			return
	_refresh_destination(false)


func _deferred_start():
	if _ended or not is_inside_tree() or _unit == null or not is_instance_valid(_unit):
		return
	_refresh_destination(true)


func _refresh_destination(force: bool):
	if _ended or _movement == null or not is_instance_valid(_movement):
		return
	if _base == null or not _is_valid_base(_base):
		_movement.stop()
		_moving = false
		_emit_ended("TargetLost")
		return
	if _is_at_base(_base):
		_movement.stop()
		_moving = false
		if not _arrival_reported:
			_emit_ended("Arrived")
		return

	var destination: Vector3 = _base.global_position
	if not force and _moving and _last_destination.distance_squared_to(destination) < 0.04:
		return
	# move() 明确清除 Movement 的战术倒车标志，因此回基地始终使用正常最高速度。
	if force or _last_destination == Vector3.INF or _last_destination.distance_squared_to(destination) >= 0.04:
		_reachability_retries = 0
	_movement.move(destination)
	_last_destination = destination
	_moving = true
	_arrival_reported = false


func _on_movement_finished():
	if _ended:
		return
	_moving = false
	if _base != null and _is_at_base(_base):
		if not _arrival_reported:
			_emit_ended("Arrived")
		return
	_reachability_retries += 1
	if _reachability_retries >= MAX_REACHABILITY_RETRIES:
		_emit_ended("Unreachable")
		return
	_retry_remaining = RETRY_INTERVAL


func _on_movement_ended(reason: String):
	if _ended:
		return
	if reason == "Unreachable":
		_moving = false
		_emit_ended("Unreachable")


func _emit_ended(reason: String):
	if reason == "Arrived":
		# Arrived is an observable waypoint, not the end of the persistent stance.
		# Keep this Action alive so a destroyed/overridden base can be reselected.
		if _ended or _arrival_reported:
			return
		_arrival_reported = true
		_moving = false
		_retry_remaining = 0.0
		if _movement != null and is_instance_valid(_movement):
			_movement.stop()
		if _unit != null and _unit.has_method("request_legacy_deliver_resources_to_base"):
			_unit.request_legacy_deliver_resources_to_base()
		ended.emit(reason)
		return_to_base_ended.emit(reason)
		return

	if _ended:
		return
	_ended = true
	_moving = false
	_retry_remaining = 0.0
	if _movement != null and is_instance_valid(_movement):
		_movement.stop()
	# Unit.gd bridges the generic ended signal to its stable public signal;
	# emitting the latter too keeps the action independently observable in tests.
	ended.emit(reason)
	return_to_base_ended.emit(reason)
	# Let listeners consume the terminal state before releasing the action node.
	call_deferred("queue_free")


func _set_base(candidate):
	if _base == candidate:
		return
	if _base != null and is_instance_valid(_base):
		if _base.tree_exiting.is_connected(_on_base_exiting):
			_base.tree_exiting.disconnect(_on_base_exiting)
	_base = candidate if _is_valid_base(candidate) else null
	if _base != null:
		_base.tree_exiting.connect(_on_base_exiting, CONNECT_ONE_SHOT)


func _on_base_exiting():
	_base = null
	_moving = false
	_arrival_reported = false
	_retry_remaining = 0.0


func _find_nearest_base():
	if _unit == null or not is_instance_valid(_unit):
		return null
	# CommandRuntime 在权威端使用同一份已完成 CommandCenter 仓库；
	# 保留本地回退扫描以便旧场景和纯 GDScript smoke test 仍可运行。
	var match_node = _unit.find_parent("Match")
	var runtime = match_node.get_node_or_null("CommandRuntime") if match_node != null else null
	if runtime != null and runtime.has_method("FindNearestCompletedCommandCenter"):
		var authoritative_base = runtime.FindNearestCompletedCommandCenter(_unit)
		if authoritative_base != null and _is_valid_base(authoritative_base):
			return authoritative_base
	var candidates: Array = []
	var player = _unit.get_parent()
	if player != null:
		for child in player.get_children():
			if child not in candidates:
				candidates.append(child)
	for candidate in get_tree().get_nodes_in_group("units"):
		if candidate not in candidates:
			candidates.append(candidate)

	var nearest = null
	var nearest_distance := INF
	for candidate in candidates:
		if not _is_valid_base(candidate):
			continue
		var distance: float = candidate.global_position.distance_squared_to(_unit.global_position)
		if distance < nearest_distance:
			nearest_distance = distance
			nearest = candidate
	return nearest


func _is_valid_base(candidate) -> bool:
	return (
		candidate != null
		and is_instance_valid(candidate)
		and candidate.is_inside_tree()
		and not candidate.is_queued_for_deletion()
		and candidate is CommandCenter
		and _unit != null
		and candidate.get_parent() == _unit.get_parent()
		and (not candidate.has_method("is_constructed") or candidate.is_constructed())
		and (not "hp" in candidate or candidate.hp == null or candidate.hp > 0)
	)


func _is_at_base(base) -> bool:
	if base == null or not is_instance_valid(base):
		return false
	var base_radius := 1.8
	if "radius" in base and base.radius != null:
		base_radius = maxf(0.5, float(base.radius))
	var unit_radius := 0.5
	if _unit != null and "radius" in _unit and _unit.radius != null:
		unit_radius = maxf(0.1, float(_unit.radius))
	var stand_off := base_radius + unit_radius + 0.35
	return _unit.global_position_yless.distance_to(base.global_position_yless) <= stand_off + ARRIVAL_EPSILON
