extends "res://source/match/units/actions/Moving.gd"

signal ended(reason)

var _target_unit = null
var _finished := false


func _init(target_unit):
	_target_unit = target_unit


func _process(_delta):
	if Utils.Match.Unit.Movement.units_adhere(_unit, _target_unit):
		_finish("Arrived")


func _ready():
	_target_unit.tree_exited.connect(_on_target_exited, CONNECT_ONE_SHOT)
	_target_position = (
		_target_unit.global_position_yless
		+ (
			(_unit.global_position_yless - _target_unit.global_position_yless).normalized()
			* _target_unit.radius
		)
	)
	super()


func _on_movement_finished():
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
		_target_position = _target_unit.global_position
		_movement_trait.move(_target_position)


## 目标退出时以明确原因结束，供权威订单转换为 TargetLost。
func _on_target_exited():
	_finish("TargetLost")


## 只广播一次实体靠近终态，并释放当前 Action。
func _finish(reason: String):
	if _finished:
		return
	_finished = true
	ended.emit(reason)
	queue_free()
