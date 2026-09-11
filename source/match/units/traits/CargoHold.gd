extends Node

## 运输货舱（红警3 式，2026-09-11 用户指定交互）：
## 选中士兵右键运输车 → 步兵标记"登车"并走向运输车，进入 3 米内自动上车；
## 只有侧栏"卸货"按钮能卸载（到达目的地不自动卸，由玩家手动控制）。
## 运输车被毁则乘客殉职。不做自动装载：未标记登车的步兵靠近也不会上车。

const LOAD_RADIUS := 3.0
const UNLOAD_SPREAD := 1.2
const BOARDING_META := "boarding_transport"

@export var capacity := 10

var _transport: Node3D = null
var _passengers: Array = []


func _ready():
	_transport = get_parent()


func _process(_delta):
	if _transport == null or not is_instance_valid(_transport):
		return
	# 接应已标记登车的步兵：进入 3 米内即装载
	if _passengers.size() >= capacity:
		return
	for unit in get_tree().get_nodes_in_group("controlled_units"):
		if _passengers.size() >= capacity:
			break
		if not is_instance_valid(unit) or unit.get_meta(BOARDING_META, null) != _transport:
			continue
		if not _is_loadable_infantry(unit):
			continue
		if _transport.global_position.distance_to(unit.global_position) <= LOAD_RADIUS:
			load_unit(unit)


## 右键下登车令：标记士兵"正在前往该车登车"（由 UnitActionsController 调用）。
func mark_boarding(unit):
	unit.set_meta(BOARDING_META, _transport)


func load_unit(unit):
	if unit in _passengers or _passengers.size() >= capacity:
		return
	if unit.action != null and is_instance_valid(unit.action):
		unit.action.queue_free()
	unit.action = null
	unit._action_locked = true
	# 不能用 unit.visible 隐藏：迷雾的 UnitVisibilityHandler 每帧会改写 visible。
	# 改为把乘客沉到地图下方并停用其处理，彻底脱离画面与战斗。
	unit.global_position = _transport.global_position + Vector3(0, -30, 0)
	unit.process_mode = Node.PROCESS_MODE_DISABLED
	if unit.has_meta(BOARDING_META):
		unit.remove_meta(BOARDING_META)
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
		# 保持乘客原地面高度（避免空中运输卸载时把步兵放到飞行高度）
		var ground_point = Vector3(_transport.global_position.x, 0.0, _transport.global_position.z)
		unit.global_position = ground_point + offset
		unit.process_mode = Node.PROCESS_MODE_INHERIT
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
	return true


func _is_waiting_action(action) -> bool:
	var script = action.get_script()
	return script != null and str(script.resource_path).ends_with("WaitingForTargets.gd")


func _collect_areas(unit: Node) -> Array:
	var areas: Array = []
	if unit is Area3D:
		areas.append(unit)
	for child in unit.get_children():
		if child is Area3D:
			areas.append(child)
	return areas


func _exit_tree():
	# 运输车被毁：乘客随车殉职（先恢复可见以播放死亡表现）
	for unit in _passengers:
		if is_instance_valid(unit):
			unit.process_mode = Node.PROCESS_MODE_INHERIT
			unit.global_position = _transport.global_position + Vector3(0, -30, 0)
			for area in _collect_areas(unit):
				area.set_deferred("collision_layer", 2)
			unit._action_locked = false
			unit.hp = 0
	_passengers.clear()
