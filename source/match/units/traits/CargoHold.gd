extends Node

## 运输货舱（红警3 式，2026-09-11 用户指定交互）：
## 选中士兵右键运输车（或车旁沙地）→ 步兵标记"登车"并走向运输车，平面 4.5 米内自动上车；
## 只有侧栏"卸货"按钮能卸载（到达目的地不自动卸，由玩家手动控制）。
## 运输车被毁则乘客殉职。不做自动装载：未标记登车的步兵靠近也不会上车。

const LOAD_RADIUS := 4.5
const UNLOAD_SPREAD := 1.2
const BOARDING_META := "boarding_transport"

@export var capacity := 10

var _transport: Node3D = null
var _passengers: Array = []
const BOARDING_SCAN_INTERVAL := 0.10
var _boarding_scan_elapsed := BOARDING_SCAN_INTERVAL


func _ready():
	_transport = get_parent()


func _process(_delta):
	if _transport == null or not is_instance_valid(_transport):
		return
	_boarding_scan_elapsed += _delta
	if _boarding_scan_elapsed < BOARDING_SCAN_INTERVAL:
		return
	_boarding_scan_elapsed = fmod(_boarding_scan_elapsed, BOARDING_SCAN_INTERVAL)
	# 接应已标记登车的步兵：平面距离进入装载半径即上车
	if _passengers.size() >= capacity:
		return
	for unit in get_tree().get_nodes_in_group("controlled_units"):
		if _passengers.size() >= capacity:
			break
		# ⚠️ 不要写成 `unit.get_meta(BOARDING_META, null)`：Godot 4.7 把显式 null 默认值
		# 当作"未提供 default"，于是**每个没有该 meta 的单位每帧都报一次错**并附加堆栈——
		# 运输车是全游戏唯一带 CargoHold 的单位，实测客户端日志 40 秒涨到 10.8MB
		# （42604 条 `ERROR: ... does not have any 'meta' values with the key 'boarding_transport'`），
		# 帧率从 120 掉到 7~11。必须先 has_meta 再取（同 BuildingOcclusionFade.gd 的已知坑）。
		if not is_instance_valid(unit) or not unit.has_meta(BOARDING_META):
			continue
		if unit.get_meta(BOARDING_META) != _transport:
			continue
		if not _is_loadable_infantry(unit):
			continue
		# ⚠ 显式类型：`unit` 来自分组遍历（Variant），`:=` 推不出 → 整个脚本解析失败、
		# 运输车功能静默消失（2026-09-15 与 InfantryAnimationDriver 同类的实测故障）。
		var dx: float = _transport.global_position.x - unit.global_position.x
		var dz: float = _transport.global_position.z - unit.global_position.z
		if dx * dx + dz * dz <= LOAD_RADIUS * LOAD_RADIUS:
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
		# 同上：`offset` 是弱类型局部变量，Vector3 + Variant 推不出类型。
		var drop: Vector3 = _transport.global_position + offset
		var match_node = _transport.find_parent("Match")
		if match_node != null and match_node.has_method("ground_height_at"):
			drop.y = float(match_node.ground_height_at(drop))
		unit.global_position = drop
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
	if unit == _transport or not _same_owner(unit):
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


func _same_owner(unit) -> bool:
	if unit.get_parent() == _transport.get_parent():
		return true
	var unit_player = unit.get("player")
	var transport_player = _transport.get("player")
	if unit_player != null and transport_player != null:
		return unit_player == transport_player
	return false


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
