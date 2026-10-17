extends "res://source/match/units/actions/Moving.gd"

signal ended(reason)

var _target_unit = null
var _finished := false
var _end_reason := ""


func _init(target_unit):
	_target_unit = target_unit


func _process(_delta):
	if _finished:
		return
	if not is_instance_valid(_target_unit) or not _target_unit.is_inside_tree():
		_finish("TargetLost")
		return
	if not _applied or not is_instance_valid(_unit):
		return
	if Utils.Match.Unit.Movement.units_adhere(_unit, _target_unit):
		_finish("Arrived")


func _ready():
	if not is_instance_valid(_target_unit) or not _target_unit.is_inside_tree():
		_finish("TargetLost")
		return
	_target_unit.tree_exited.connect(_on_target_exited, CONNECT_ONE_SHOT)
	super()


## Moving resolves its owner lazily while Match registers newly spawned units.
## Prepare the goal only after that owner exists; never dispatch a null goal.
func _try_apply_move():
	if _finished or _applied:
		return
	if not is_instance_valid(_target_unit) or not _target_unit.is_inside_tree():
		_finish("TargetLost")
		return
	if not is_instance_valid(_unit):
		_unit = Utils.NodeEx.find_parent_with_group(self, "units")
	if not is_instance_valid(_unit):
		return
	if not is_instance_valid(_movement_trait):
		_movement_trait = _unit.find_child("Movement")
	if not is_instance_valid(_movement_trait):
		return
	var approach: Variant = Utils.Match.Unit.Movement.structure_approach_point(_unit, _target_unit)
	if approach != null:
		_target_position = approach
	elif _target_unit.is_in_group("resource_units"):
		# 同一矿点同时来多辆车时，按各自槽位站到四个方向，避免挤在同一个落点上贴不上、也不采集。
		_target_position = _resource_stand_position()
	else:
		_target_position = (
			_target_unit.global_position_yless
			+ (
				(_unit.global_position_yless - _target_unit.global_position_yless).normalized()
				* _target_unit.radius
			)
		)
	if _movement_trait != null and _movement_trait.has_signal("movement_ended") \
			and not _movement_trait.movement_ended.is_connected(_on_movement_ended):
		_movement_trait.movement_ended.connect(_on_movement_ended)
	super()


func _on_movement_ended(reason: String) -> void:
	_end_reason = reason


func _on_movement_finished():
	if _finished:
		return
	if not is_instance_valid(_target_unit) or not _target_unit.is_inside_tree():
		_finish("TargetLost")
		return
	if not is_instance_valid(_unit):
		return
	if _end_reason == "Unreachable":
		_finish("Unreachable")
		return
	if Utils.Match.Unit.Movement.units_adhere(_unit, _target_unit):
		_finish("Arrived")
	elif Utils.Match.Unit.Movement._unit_in_range_of_other(
			_unit, _target_unit, Constants.Match.Units.ADHERENCE_MARGIN_M * 2.0
	):
		# 宽限到达（与 `CollectingResourcesWhileInRange` 采集同口径）：导航停点与
		# 贴合阈值相差几十厘米时，严格判死会造成"到达→贴不上→重走"死循环。
		# 2026-09-23 矿场交付实测：工人被避让圈挡在 3.2m、阈值 3.1m，恰好差
		# 10cm，满载工人永远交不出去。
		_finish("Arrived")
	else:
		var approach: Variant = Utils.Match.Unit.Movement.structure_approach_point(_unit, _target_unit)
		if approach != null:
			_target_position = approach
		elif _target_unit.is_in_group("resource_units"):
			_target_position = _resource_stand_position()
		else:
			_target_position = _target_unit.global_position
		_movement_trait.move(_target_position)


## 矿点不挖导航洞，structure_approach_point 用不上。站位必须仍在贴合距离内。
##
## 【回归修复 C（2026-10-10，对齐 923 发布口径）】落点从"固定世界轴四象限"改回
## **以车自己的来向为基准**，同矿多车只在 ±35° 内按车道错开。
## 为什么：原实现 `angle = approach_slot(unit) % 4 * 90°` 用的是**世界轴**（±X/±Z），
## 与车从哪一侧来无关；矿点又不挖洞（affect_navigation_mesh=false）⇒ 必然走这条分支，
## 于是车经常要绕到矿点另一侧再停下（用户实报"第一次采矿都要绕道这里停下来"）。
## 923 发布版是 `矿点 + normalize(车−矿点) × 矿半径`，永远从车自己这一侧贴上去，没有绕行。
##
## ⚠️ 必须**缓存**首次算出的世界落点：本方法在 `_ready()` 与 `_on_movement_finished()`
## （未贴合重下）两处被调用；若每次都按"车当前位置"重算，落点会跟着车转，
## 车一靠近落点就翻到另一侧 ⇒ 目标来回抖、`units_adhere` 永远不成立
## （2026-10-10 实测：矿车卡在离矿心 1.92m 处每帧重建 MOVING_TO_RESOURCE）。
var _stand_cache: Vector3 = Vector3.INF


func _resource_stand_position() -> Vector3:
	if _stand_cache.is_finite():
		return _stand_cache
	var ore_r := 1.2
	var ore_radius = _target_unit.get("radius")
	if ore_radius != null:
		ore_r = float(ore_radius)
	var stand_off := ore_r
	# 【回归修复 C2（2026-10-10）】落点距离改回 923 口径 `矿半径`（**落点在矿体内部**）。
	# 为什么不能用"矿半径 + 车半径×0.85"：移动层的到点容差是 `arrive_radius = max(车半径, 0.35)`
	# （`Movement.gd:782/821`）叠加逻辑路径航点容差 `LOGIC_WAYPOINT_RADIUS_M = 1.6`
	# （`Movement.gd:389/955`）——车**可以在离目标 1.36~1.6m 处就判"到了"**。
	# 当前半径口径（车 1.36 / 矿 1.2 / 贴合阈值 3.06m）下：
	#   落点 2.36m + 容差 1.36m = 3.72m > 3.06m ⇒ 车"合法地"停在贴不上的位置，
	#   `CollectingResourcesSequentially` 反复重下同一个点、永远贴不上（实测 3.58m / 5.35m 卡死）。
	# 把落点压进矿体（1.2m）：碰撞推出层把车顶在 矿半径+车半径 = 2.56m，
	# 最坏情况 1.2+1.36 = 2.56m ≤ 3.06m ⇒ **必然**满足贴合；`MovingToUnit._process`
	# 一到贴合距离就 `Arrived`，完全不依赖移动层的到点精度。923 正是这么做的
	# （`矿点 + normalize(车−矿点) × 矿点半径`），所以同一颗矿它从不失败。
	var from: Vector3 = (_unit.global_position - _target_unit.global_position) * Vector3(1, 0, 1)
	if from.length() < 0.1:
		from = Vector3.FORWARD
	var base_angle := atan2(from.z, from.x)
	var lane := (int(Utils.Match.Unit.Movement.approach_slot(_unit)) % 3) - 1
	var angle := base_angle + float(lane) * deg_to_rad(35.0)
	var origin: Vector3 = _target_unit.global_position
	_stand_cache = Vector3(origin.x + cos(angle) * stand_off, origin.y, origin.z + sin(angle) * stand_off)
	return _stand_cache


## 目标退出时以明确原因结束，供权威订单转换为 TargetLost。
func _on_target_exited():
	_finish("TargetLost")


## 只广播一次实体靠近终态，并释放当前 Action。
func _finish(reason: String):
	if _finished:
		return
	_finished = true
	# 作为子动作（采集/交货）时 `_unit.action` 是父动作，Moving._exit_tree 不会 stop；
	# 必须在 ended 之前停，否则单位继续追旧落点，被推出层顶住原地转向，采集朝向门槛永远不过。
	if reason == "Arrived" and _movement_trait != null and is_instance_valid(_movement_trait):
		_movement_trait.stop()
	ended.emit(reason)
	queue_free()
