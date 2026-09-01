extends "res://source/match/units/actions/Action.gd"

const AttackingWhileInRange = preload("res://source/match/units/actions/AttackingWhileInRange.gd")
const AutoAttacking = preload("res://source/match/units/actions/AutoAttacking.gd")
const Moving = preload("res://source/match/units/actions/Moving.gd")

const REFRESH_INTERVAL = 1.0 / 60.0 * 10.0

var _timer = null
var _sub_action = null

@onready var _unit = Utils.NodeEx.find_parent_with_group(self, "units")
@onready var _command_runtime = _unit.find_parent("Match").get_node("CommandRuntime")


func _ready():
	_timer = Timer.new()
	_timer.timeout.connect(_on_timer_timeout)
	add_child(_timer)
	_timer.start(REFRESH_INTERVAL)


func _to_string():
	return "{0}({1})".format([super(), str(_sub_action) if _sub_action != null else ""])


func is_idle():
	return _sub_action == null


## 在权威战斗策略变化时立即撤销旧自主行为，避免轮询间隔内继续追击或开火。
func refresh_combat_policy():
	var movement = _unit.find_child("Movement")
	if movement != null:
		movement.stop()
	if _sub_action != null:
		_sub_action.free()
		return
	_on_timer_timeout()


func _get_units_to_attack():
	# 单人测试局：AI 单位保持待机，不因视野内目标自动开火；
	# 人类单位及明确下达的攻击命令仍走正常路径。
	if _unit.player != null and _unit.player.has_method("is_passive_test_ai"):
		if _unit.player.is_passive_test_ai():
			return []
	if _command_runtime.GetFirePolicy(_unit) == "HoldFire":
		return []
	var stance: String = _command_runtime.GetEngagementStance(_unit)
	var guard_anchor: Vector3 = _command_runtime.GetGuardAnchor(_unit)
	return get_tree().get_nodes_in_group("units").filter(
		func(unit):
			var detection_origin: Vector3 = _unit.global_position_yless
			var detection_range: float = _unit.sight_range
			if stance == "HoldGround":
				detection_range = _unit.attack_range
			elif stance == "Guard" and guard_anchor.is_finite():
				detection_origin = guard_anchor * Vector3(1, 0, 1)
			return (
				unit.player != _unit.player
				and unit.movement_domain in _unit.attack_domains
				and detection_origin.distance_to(unit.global_position_yless) <= detection_range
			)
	)


func _attack_unit(unit):
	_timer.timeout.disconnect(_on_timer_timeout)
	_sub_action = (
		AutoAttacking.new(unit) if _unit.movement_speed > 0.0 else AttackingWhileInRange.new(unit)
	)
	_sub_action.tree_exited.connect(_on_attack_finished)
	add_child(_sub_action)
	_unit.action_updated.emit()


func _on_timer_timeout():
	if _sub_action != null:
		return
	if _command_runtime == null:
		# 单位创建早于 Match 就绪时 @onready 解析为 Nil（基线既有问题），
		# 每个计时周期静默跳过，避免对 Nil 调 C# 方法刷屏。
		return
	if _try_returning_to_guard_anchor():
		return
	var units_to_attack = _get_units_to_attack()
	if not units_to_attack.is_empty():
		_attack_unit(_pick_closest_unit(units_to_attack, _unit))


func _on_attack_finished():
	if not is_inside_tree():
		return
	_sub_action = null
	_unit.action_updated.emit()
	_timer.timeout.connect(_on_timer_timeout)


func _try_returning_to_guard_anchor() -> bool:
	if _command_runtime.GetEngagementStance(_unit) != "Guard":
		return false
	var guard_anchor: Vector3 = _command_runtime.GetGuardAnchor(_unit)
	if not guard_anchor.is_finite() or _unit.global_position.distance_to(guard_anchor) <= 0.5:
		return false
	_timer.timeout.disconnect(_on_timer_timeout)
	_sub_action = Moving.new(guard_anchor)
	_sub_action.tree_exited.connect(_on_attack_finished)
	add_child(_sub_action)
	_unit.action_updated.emit()
	return true


static func _pick_closest_unit(units, unit):
	assert(not units.is_empty())
	var distance_to_closest_unit = unit.global_position_yless.distance_to(
		units[0].global_position_yless
	)
	var closest_unit = units[0]
	for unit_to_check in units:
		var distance = unit.global_position_yless.distance_to(unit_to_check.global_position_yless)
		if distance < distance_to_closest_unit:
			distance_to_closest_unit = distance
			closest_unit = unit_to_check
	return closest_unit
