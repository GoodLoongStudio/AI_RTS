extends Node

## 运输货舱（红警3 式运输单位，2026-09-11）：
## 空闲时自动装载 1.4 米内已停稳的己方地面步兵（装满为止）；
## 运输单位抵达目的地回到空闲态后自动卸载；运输单位被毁则乘客同毁。
## 装载期间乘客隐藏/无敌/锁动作；卸载恢复并散开落位。

const LOAD_RADIUS := 2.0
const UNLOAD_SPREAD := 1.2
const WAITING_FOR_TARGETS_SCRIPT := "res://source/match/units/actions/WaitingForTargets.gd"

@export var capacity := 4

var _transport: Node3D = null
var _passengers: Array = []


func _ready():
	_transport = get_parent()


func _process(_delta):
	if _transport == null or not is_instance_valid(_transport):
		return
	if OS.has_environment("CARGO_DEBUG") and Engine.get_process_frames() % 60 == 0:
		print("[CARGO] t=%s idle=%s pax=%d in_tree=%s tree=%s" % [
			_transport.name, _transport_is_idle(), _passengers.size(),
			_transport.is_inside_tree(), get_tree() != null])
	if _transport_is_idle():
		if not _passengers.is_empty():
			unload_all()
			return
		if _passengers.size() < capacity:
			for unit in get_tree().get_nodes_in_group("controlled_units"):
				if _passengers.size() >= capacity:
					break
				if not is_instance_valid(unit) or unit in _passengers:
					continue
				if _is_loadable_infantry(unit) and _transport.global_position.distance_to(
					unit.global_position
				) <= LOAD_RADIUS:
					load_unit(unit)


func load_unit(unit):
	if unit in _passengers or _passengers.size() >= capacity:
		return
	if unit.action != null and is_instance_valid(unit.action):
		unit.action.queue_free()
	unit.action = null
	unit._action_locked = true
	unit.visible = false
	for area in _collect_areas(unit):
		area.set_deferred("collision_layer", 0)
	var selection = unit.find_child("Selection", true, false)
	if selection != null and selection.has_method("deselect"):
		selection.deselect()
	_passengers.append(unit)


func unload_all():
	var passengers := _passengers.duplicate()
	_passengers.clear()
	for i in range(passengers.size()):
		var unit = passengers[i]
		if not is_instance_valid(unit):
			continue
		var offset = Vector3(sin(i * 1.3) * UNLOAD_SPREAD, 0, cos(i * 1.3) * UNLOAD_SPREAD)
		# 空中运输机卸载时保持乘客原地面高度，避免把步兵空投到飞行高度
		var ground_point = Vector3(_transport.global_position.x, unit.global_position.y, _transport.global_position.z)
		unit.global_position = ground_point + offset
		unit.visible = true
		for area in _collect_areas(unit):
			area.set_deferred("collision_layer", 2)
		unit._action_locked = false


func get_passenger_count() -> int:
	return _passengers.size()


func _transport_is_idle() -> bool:
	var action = _transport.action
	return action == null or not is_instance_valid(action) or _is_waiting_action(action)


func _is_loadable_infantry(unit) -> bool:
	if unit == _transport or unit.get_parent() != _transport.get_parent():
		return false
	if unit.get("movement_domain") != Constants.Match.Navigation.Domain.TERRAIN:
		return false
	if unit.hp == null or unit.hp <= 0:
		return false
	if unit.has_method("is_under_construction") and unit.is_under_construction():
		return false
	if unit.get("_action_locked") == true:
		return false
	var action = unit.action
	if action != null and is_instance_valid(action) and not _is_waiting_action(action):
		return false  # 行进/攻击中的单位不装载，等它停下
	return true


func _is_waiting_action(action) -> bool:
	var script = action.get_script()
	return script != null and str(script.resource_path) == WAITING_FOR_TARGETS_SCRIPT


func _collect_areas(unit: Node) -> Array:
	var areas: Array = []
	if unit is Area3D:
		areas.append(unit)
	for child in unit.get_children():
		if child is Area3D:
			areas.append(child)
	return areas


func _exit_tree():
	# 运输单位被毁：乘客随车殉职（先恢复可见以播放死亡表现）
	for unit in _passengers:
		if is_instance_valid(unit):
			unit.visible = true
			for area in _collect_areas(unit):
				area.set_deferred("collision_layer", 2)
			unit._action_locked = false
			unit.hp = 0
	_passengers.clear()
