extends Node

signal command_targeting_changed(command_name)
signal command_feedback(command_name, accepted_count, rejected_count, status)

const Structure = preload("res://source/match/units/Structure.gd")
const ResourceUnit = preload("res://source/match/units/non-player/ResourceUnit.gd")
const Tank = preload("res://source/match/units/Tank.gd")

var _is_force_move_targeting := false
var _is_force_attack_targeting := false
var _is_tactical_withdraw_targeting := false
var _is_ground_attack_move_targeting := false


class Actions:
	const Moving = preload("res://source/match/units/actions/Moving.gd")
	const MovingToUnit = preload("res://source/match/units/actions/MovingToUnit.gd")
	const Following = preload("res://source/match/units/actions/Following.gd")
	const CollectingResourcesSequentially = preload(
		"res://source/match/units/actions/CollectingResourcesSequentially.gd"
	)
	const AutoAttacking = preload("res://source/match/units/actions/AutoAttacking.gd")
	const Constructing = preload("res://source/match/units/actions/Constructing.gd")


func _ready():
	MatchSignals.terrain_targeted.connect(_on_terrain_targeted)
	MatchSignals.unit_targeted.connect(_on_unit_targeted)
	MatchSignals.unit_spawned.connect(_on_unit_spawned)
	MatchSignals.navigate_unit_to_rally_point.connect(_on_navigate_unit_to_rally_point)


func _try_navigating_selected_units_towards_position(target_point):
	var terrain_units_to_move = get_tree().get_nodes_in_group("selected_units").filter(
		func(unit):
			return (
				unit.is_in_group("controlled_units")
				and unit.movement_domain == Constants.Match.Navigation.Domain.TERRAIN
				and Actions.Moving.is_applicable(unit)
			)
	)
	var air_units_to_move = get_tree().get_nodes_in_group("selected_units").filter(
		func(unit):
			return (
				unit.is_in_group("controlled_units")
				and unit.movement_domain == Constants.Match.Navigation.Domain.AIR
				and Actions.Moving.is_applicable(unit)
			)
	)
	var new_unit_targets = Utils.Match.Unit.Movement.crowd_moved_to_new_pivot(
		terrain_units_to_move, target_point
	)
	new_unit_targets += Utils.Match.Unit.Movement.crowd_moved_to_new_pivot(
		air_units_to_move, target_point
	)
	# Crowd formation still computes a per-unit destination. Submit each destination
	# through the reviewed command boundary instead of assigning Unit.action here.
	var command_gateway = get_parent().find_child("UnitCommandGateway")
	assert(command_gateway != null)
	for tuple in new_unit_targets:
		if tuple[0] is Tank:
			command_gateway.MoveUnits([tuple[0]], tuple[1], get_parent())
		else:
			# Non-Tank units remain on the legacy path until their command semantics are reviewed.
			tuple[0].action = Actions.Moving.new(tuple[1])


## 进入一次性的强制移动目标选择状态；下一次地面目标将消费此状态。
func begin_force_move_targeting():
	_is_force_attack_targeting = false
	_is_tactical_withdraw_targeting = false
	_is_ground_attack_move_targeting = false
	_is_force_move_targeting = true
	command_targeting_changed.emit("ForceMove")


## 进入一次性的强制攻击目标选择状态；右键实体或地面将消费此状态。
func begin_force_attack_targeting():
	_is_force_move_targeting = false
	_is_tactical_withdraw_targeting = false
	_is_ground_attack_move_targeting = false
	_is_force_attack_targeting = true
	command_targeting_changed.emit("ForceAttack")


## 进入一次性的战术撤退目标选择状态；单位将令车尾沿局部路径方向移动。
func begin_tactical_withdraw_targeting():
	_is_force_move_targeting = false
	_is_force_attack_targeting = false
	_is_ground_attack_move_targeting = false
	_is_tactical_withdraw_targeting = true
	command_targeting_changed.emit("TacticalWithdraw")


## 进入一次性的地面移动攻击目标选择状态。
func begin_ground_attack_move_targeting():
	_is_force_move_targeting = false
	_is_force_attack_targeting = false
	_is_tactical_withdraw_targeting = false
	_is_ground_attack_move_targeting = true
	command_targeting_changed.emit("GroundAttackMove")


## 取消尚未指定目标的显式命令，不影响单位当前正在执行的命令。
func cancel_command_targeting():
	if (
		not _is_force_move_targeting
		and not _is_force_attack_targeting
		and not _is_tactical_withdraw_targeting
		and not _is_ground_attack_move_targeting
	):
		return
	_is_force_move_targeting = false
	_is_force_attack_targeting = false
	_is_tactical_withdraw_targeting = false
	_is_ground_attack_move_targeting = false
	command_targeting_changed.emit("")


## 对当前 Selection 中已迁移的 Tank 提交停止移动命令，并汇总即时接收结果。
func halt_selected_units():
	var selected_units = _get_selected_controlled_units()
	var tanks = selected_units.filter(func(unit): return unit is Tank)
	var accepted_count := 0
	var rejected_count: int = selected_units.size() - tanks.size()
	if not tanks.is_empty():
		var gateway = _get_command_gateway()
		var halt_result = gateway.HaltMovement(tanks, get_parent())
		var cancel_result = gateway.CancelForceAttack(tanks, get_parent())
		var halt_counts = _count_command_result(halt_result)
		var cancel_counts = _count_command_result(cancel_result)
		accepted_count += min(halt_counts[0], cancel_counts[0])
		rejected_count += max(halt_counts[1], cancel_counts[1])
	_emit_command_feedback("Stop", accepted_count, rejected_count)


## 返回当前 Selection 中已迁移到 C# 命令链路的可控 Tank 数量，供灰盒 HUD 更新可用状态。
func get_selected_command_unit_count() -> int:
	return _get_selected_controlled_units().filter(func(unit): return unit is Tank).size()


## 为当前 Selection 中已迁移的 Tank 设置持续交战姿态，并汇总即时接收结果。
func set_selected_engagement_stance(stance: String):
	_submit_selected_combat_policy("EngagementStance", stance)


## 为当前 Selection 中已迁移的 Tank 设置持续开火策略，并汇总即时接收结果。
func set_selected_fire_policy(policy: String):
	_submit_selected_combat_policy("FirePolicy", policy)


## 返回当前选中 Tank 的统一战斗策略；混合值或无选中时返回空字符串。
func get_selected_combat_policy(policy_name: String) -> String:
	var tanks = _get_selected_controlled_units().filter(func(unit): return unit is Tank)
	if tanks.is_empty():
		return ""
	var gateway = _get_command_gateway()
	var first_value: String = (
		gateway.GetEngagementStance(tanks[0])
		if policy_name == "EngagementStance"
		else gateway.GetFirePolicy(tanks[0])
	)
	for tank in tanks:
		var value: String = (
			gateway.GetEngagementStance(tank)
			if policy_name == "EngagementStance"
			else gateway.GetFirePolicy(tank)
		)
		if value != first_value:
			return ""
	return first_value


func _submit_selected_combat_policy(policy_name: String, value: String):
	var selected_units = _get_selected_controlled_units()
	var tanks = selected_units.filter(func(unit): return unit is Tank)
	var accepted_count := 0
	var rejected_count: int = selected_units.size() - tanks.size()
	if not tanks.is_empty():
		var gateway = _get_command_gateway()
		var result = (
			gateway.SetEngagementStance(tanks, value, get_parent())
			if policy_name == "EngagementStance"
			else gateway.SetFirePolicy(tanks, value, get_parent())
		)
		var counts = _count_command_result(result)
		accepted_count += counts[0]
		rejected_count += counts[1]
	_emit_command_feedback(value, accepted_count, rejected_count)


func _execute_targeted_force_move(target_point: Vector3):
	var selected_units = _get_selected_controlled_units()
	var tanks = selected_units.filter(
		func(unit): return unit is Tank and Actions.Moving.is_applicable(unit)
	)
	var terrain_tanks = tanks.filter(
		func(unit): return unit.movement_domain == Constants.Match.Navigation.Domain.TERRAIN
	)
	var air_tanks = tanks.filter(
		func(unit): return unit.movement_domain == Constants.Match.Navigation.Domain.AIR
	)
	var targets = Utils.Match.Unit.Movement.crowd_moved_to_new_pivot(terrain_tanks, target_point)
	targets += Utils.Match.Unit.Movement.crowd_moved_to_new_pivot(air_tanks, target_point)
	var accepted_count := 0
	var rejected_count: int = selected_units.size() - targets.size()
	for tuple in targets:
		var result = _get_command_gateway().ForceMoveUnits([tuple[0]], tuple[1], get_parent())
		var counts = _count_command_result(result)
		accepted_count += counts[0]
		rejected_count += counts[1]
	_emit_command_feedback("ForceMove", accepted_count, rejected_count)


func _execute_targeted_tactical_withdraw(target_point: Vector3):
	var selected_units = _get_selected_controlled_units()
	var tanks = selected_units.filter(
		func(unit): return unit is Tank and Actions.Moving.is_applicable(unit)
	)
	var terrain_tanks = tanks.filter(
		func(unit): return unit.movement_domain == Constants.Match.Navigation.Domain.TERRAIN
	)
	var targets = Utils.Match.Unit.Movement.crowd_moved_to_new_pivot(terrain_tanks, target_point)
	var accepted_count := 0
	var rejected_count: int = selected_units.size() - targets.size()
	for tuple in targets:
		var result = _get_command_gateway().TacticalWithdrawUnits(
			[tuple[0]], tuple[1], get_parent()
		)
		var counts = _count_command_result(result)
		accepted_count += counts[0]
		rejected_count += counts[1]
	_emit_command_feedback("TacticalWithdraw", accepted_count, rejected_count)


func _execute_targeted_ground_attack_move(target_point: Vector3):
	var selected_units = _get_selected_controlled_units()
	var tanks = selected_units.filter(
		func(unit): return unit is Tank and Actions.Moving.is_applicable(unit)
	)
	var terrain_tanks = tanks.filter(
		func(unit): return unit.movement_domain == Constants.Match.Navigation.Domain.TERRAIN
	)
	var targets = Utils.Match.Unit.Movement.crowd_moved_to_new_pivot(terrain_tanks, target_point)
	var accepted_count := 0
	var rejected_count: int = selected_units.size() - targets.size()
	for tuple in targets:
		var result = _get_command_gateway().GroundAttackMoveUnits(
			[tuple[0]], tuple[1], get_parent()
		)
		var counts = _count_command_result(result)
		accepted_count += counts[0]
		rejected_count += counts[1]
	_emit_command_feedback("GroundAttackMove", accepted_count, rejected_count)


func _execute_targeted_force_attack(target_unit):
	var selected_units = _get_selected_controlled_units()
	var tanks = selected_units.filter(func(unit): return unit is Tank)
	var accepted_count := 0
	var rejected_count: int = selected_units.size() - tanks.size()
	if not tanks.is_empty():
		var result = _get_command_gateway().ForceAttackUnits(tanks, target_unit, get_parent())
		var counts = _count_command_result(result)
		accepted_count += counts[0]
		rejected_count += counts[1]
	_emit_command_feedback("ForceAttack", accepted_count, rejected_count)


func _execute_targeted_ground_force_attack(target_point: Vector3):
	var selected_units = _get_selected_controlled_units()
	var tanks = selected_units.filter(func(unit): return unit is Tank)
	var accepted_count := 0
	var rejected_count: int = selected_units.size() - tanks.size()
	if not tanks.is_empty():
		var result = _get_command_gateway().ForceAttackGround(tanks, target_point, get_parent())
		var counts = _count_command_result(result)
		accepted_count += counts[0]
		rejected_count += counts[1]
	_emit_command_feedback("ForceAttackGround", accepted_count, rejected_count)


func _get_selected_controlled_units() -> Array:
	return get_tree().get_nodes_in_group("selected_units").filter(
		func(unit): return unit.is_in_group("controlled_units")
	)


func _get_command_gateway():
	var command_gateway = get_parent().find_child("UnitCommandGateway")
	assert(command_gateway != null)
	return command_gateway


func _count_command_result(result: Dictionary) -> Array[int]:
	var accepted_count := 0
	var rejected_count := 0
	for unit_result in result["unit_results"]:
		if unit_result["accepted"]:
			accepted_count += 1
		else:
			rejected_count += 1
	return [accepted_count, rejected_count]


func _emit_command_feedback(command_name: String, accepted_count: int, rejected_count: int):
	var status := "Rejected"
	if accepted_count > 0 and rejected_count == 0:
		status = "Accepted"
	elif accepted_count > 0:
		status = "PartiallyAccepted"
	command_feedback.emit(command_name, accepted_count, rejected_count, status)


func _try_setting_rally_points(target_point: Vector3):
	var controlled_structures = get_tree().get_nodes_in_group("selected_units").filter(
		func(unit):
			return unit.is_in_group("controlled_units") and unit.find_child("RallyPoint") != null
	)
	for structure in controlled_structures:
		var rally_point = structure.find_child("RallyPoint")
		if rally_point != null:
			rally_point.target_unit = null
			rally_point.global_position = target_point


func _try_ordering_selected_workers_to_construct_structure(potential_structure):
	if not potential_structure is Structure or potential_structure.is_constructed():
		return
	var structure = potential_structure
	var selected_constructors = get_tree().get_nodes_in_group("selected_units").filter(
		func(unit):
			return (
				unit.is_in_group("controlled_units")
				and Actions.Constructing.is_applicable(unit, structure)
			)
	)
	for unit in selected_constructors:
		unit.action = Actions.Constructing.new(structure)


func _navigate_selected_units_towards_unit(target_unit):
	var at_least_one_unit_navigated = false
	for unit in get_tree().get_nodes_in_group("selected_units"):
		if not unit.is_in_group("controlled_units"):
			continue
		if _navigate_unit_towards_unit(unit, target_unit):
			at_least_one_unit_navigated = true
	return at_least_one_unit_navigated


func _navigate_unit_towards_unit(unit, target_unit):
	if Actions.CollectingResourcesSequentially.is_applicable(unit, target_unit):
		unit.action = Actions.CollectingResourcesSequentially.new(target_unit)
		return true
	if Actions.AutoAttacking.is_applicable(unit, target_unit):
		if unit is Tank and _get_command_gateway().GetFirePolicy(unit) == "HoldFire":
			return false
		unit.action = Actions.AutoAttacking.new(target_unit)
		return true
	if Actions.Constructing.is_applicable(unit, target_unit):
		unit.action = Actions.Constructing.new(target_unit)
		return true
	if (
		(target_unit.is_in_group("adversary_units") or target_unit.is_in_group("controlled_units"))
		and Actions.Following.is_applicable(unit)
	):
		unit.action = Actions.Following.new(target_unit)
		return true
	if Actions.MovingToUnit.is_applicable(unit):
		unit.action = Actions.MovingToUnit.new(target_unit)
		return true
	if _try_setting_rally_point_to_unit(unit, target_unit):
		return true
	return false  # gdlint: ignore = max-returns


func _try_setting_rally_point_to_unit(unit, target_unit):
	if not unit is Structure:
		return false
	if not target_unit is ResourceUnit and unit.player != target_unit.player:
		# it's not allowed to set rally point to enemy at the moment as with current implementation
		# the position of enemy unit hidden in the fog of war could be hinted
		return false
	var rally_point = unit.find_child("RallyPoint")
	if rally_point == null:
		return false
	rally_point.target_unit = target_unit
	return true


func _on_terrain_targeted(position):
	if _is_ground_attack_move_targeting:
		_is_ground_attack_move_targeting = false
		command_targeting_changed.emit("")
		_execute_targeted_ground_attack_move(position)
		return
	if _is_tactical_withdraw_targeting:
		_is_tactical_withdraw_targeting = false
		command_targeting_changed.emit("")
		_execute_targeted_tactical_withdraw(position)
		return
	if _is_force_move_targeting:
		_is_force_move_targeting = false
		command_targeting_changed.emit("")
		_execute_targeted_force_move(position)
		return
	if _is_force_attack_targeting:
		_is_force_attack_targeting = false
		command_targeting_changed.emit("")
		_execute_targeted_ground_force_attack(position)
		return
	_try_navigating_selected_units_towards_position(position)
	_try_setting_rally_points(position)


func _on_unit_targeted(unit):
	if _is_force_attack_targeting:
		_is_force_attack_targeting = false
		command_targeting_changed.emit("")
		_execute_targeted_force_attack(unit)
		var explicit_targetability = unit.find_child("Targetability")
		if explicit_targetability != null:
			explicit_targetability.animate()
		return
	if _navigate_selected_units_towards_unit(unit):
		var targetability = unit.find_child("Targetability")
		if targetability != null:
			targetability.animate()


func _on_unit_spawned(unit):
	_try_ordering_selected_workers_to_construct_structure(unit)


func _on_navigate_unit_to_rally_point(unit, rally_point):
	if rally_point.target_unit != null:
		_navigate_unit_towards_unit(unit, rally_point.target_unit)
	elif rally_point.global_position != rally_point.get_parent().global_position:
		unit.action = Actions.Moving.new(rally_point.global_position)
