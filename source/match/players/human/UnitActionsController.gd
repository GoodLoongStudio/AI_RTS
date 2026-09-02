extends Node

signal command_targeting_changed(command_name)
signal command_feedback(command_name, accepted_count, rejected_count, status)

const Structure = preload("res://source/match/units/Structure.gd")
const ResourceUnit = preload("res://source/match/units/non-player/ResourceUnit.gd")

var _is_force_move_targeting := false
var _is_force_attack_targeting := false
var _is_tactical_withdraw_targeting := false
var _is_ground_attack_move_targeting := false
var _local_input_bound := false
var _skill_targeting_id := ""
var _skill_targeting_kind := ""


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
	var match_node = find_parent("Match")
	if match_node != null and not match_node.is_node_ready():
		await match_node.ready
	if not MatchSignals.match_started.is_connected(_on_match_started_for_input):
		MatchSignals.match_started.connect(_on_match_started_for_input, CONNECT_ONE_SHOT)
	call_deferred("_bind_local_input")


func _on_match_started_for_input():
	call_deferred("_bind_local_input")


func _bind_local_input():
	if _local_input_bound or not is_inside_tree():
		return
	if not _is_local_controller():
		print("[INPUT] UnitActionsController waiting for local player player=", get_parent().name)
		return
	_local_input_bound = true
	if MatchSignals.match_started.is_connected(_on_match_started_for_input):
		MatchSignals.match_started.disconnect(_on_match_started_for_input)
	print("[INPUT] UnitActionsController enabled player=", get_parent().name)
	MatchSignals.terrain_targeted.connect(_on_terrain_targeted)
	MatchSignals.unit_targeted.connect(_on_unit_targeted)
	MatchSignals.unit_spawned.connect(_on_unit_spawned)
	var command_runtime = find_parent("Match").get_node_or_null("CommandRuntime")
	if command_runtime != null:
		command_runtime.connect("OrderStateChanged", _on_order_state_changed)


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
	var command_gateway = _get_command_gateway()
	assert(command_gateway != null)
	for tuple in new_unit_targets:
		command_gateway.MoveUnits([tuple[0]], tuple[1], get_parent())


## 进入一次性的强制移动目标选择状态；下一次地面目标将消费此状态。
func begin_force_move_targeting():
	_clear_skill_targeting()
	_is_force_attack_targeting = false
	_is_tactical_withdraw_targeting = false
	_is_ground_attack_move_targeting = false
	_is_force_move_targeting = true
	command_targeting_changed.emit("ForceMove")


## 进入一次性的强制攻击目标选择状态；右键实体或地面将消费此状态。
func begin_force_attack_targeting():
	_clear_skill_targeting()
	_is_force_move_targeting = false
	_is_tactical_withdraw_targeting = false
	_is_ground_attack_move_targeting = false
	_is_force_attack_targeting = true
	command_targeting_changed.emit("ForceAttack")


## 进入一次性的战术撤退目标选择状态；单位将令车尾沿局部路径方向移动。
func begin_tactical_withdraw_targeting():
	_clear_skill_targeting()
	_is_force_move_targeting = false
	_is_force_attack_targeting = false
	_is_ground_attack_move_targeting = false
	_is_tactical_withdraw_targeting = true
	command_targeting_changed.emit("TacticalWithdraw")


## 进入一次性的地面移动攻击目标选择状态。
func begin_ground_attack_move_targeting():
	_clear_skill_targeting()
	_is_force_move_targeting = false
	_is_force_attack_targeting = false
	_is_tactical_withdraw_targeting = false
	_is_ground_attack_move_targeting = true
	command_targeting_changed.emit("GroundAttackMove")


## 当前尚未确认的显式命令名；没有选目标状态时为空字符串。
func get_active_command_targeting() -> String:
	if _is_force_move_targeting:
		return "ForceMove"
	if _is_force_attack_targeting:
		return "ForceAttack"
	if _is_tactical_withdraw_targeting:
		return "TacticalWithdraw"
	if _is_ground_attack_move_targeting:
		return "GroundAttackMove"
	if not _skill_targeting_id.is_empty():
		return "Skill:%s" % _skill_targeting_id
	return ""


## 取消尚未指定目标的显式命令，不影响单位当前正在执行的命令。
func cancel_command_targeting():
	if (
		not _is_force_move_targeting
		and not _is_force_attack_targeting
		and not _is_tactical_withdraw_targeting
		and not _is_ground_attack_move_targeting
		and _skill_targeting_id.is_empty()
	):
		return
	_is_force_move_targeting = false
	_is_force_attack_targeting = false
	_is_tactical_withdraw_targeting = false
	_is_ground_attack_move_targeting = false
	_clear_skill_targeting()
	command_targeting_changed.emit("")


## 只停止当前位移并暂停移动类订单，不取消攻击、采集或施工。
func halt_selected_units():
	var selected_units = _get_selected_controlled_units()
	var accepted_count := 0
	var rejected_count := 0
	if not selected_units.is_empty():
		var result = _get_command_gateway().HaltMovement(selected_units, get_parent())
		var counts = _count_command_result(result)
		accepted_count += counts[0]
		rejected_count += counts[1]
	_emit_command_feedback("HaltMovement", accepted_count, rejected_count)


## 对当前 Selection 提交统一 Stop：移动类暂停，攻击取消，采集/施工暂停。
func stop_selected_units():
	var selected_units = _get_selected_controlled_units()
	var accepted_count := 0
	var rejected_count := 0
	if not selected_units.is_empty():
		var result = _get_command_gateway().StopUnits(selected_units, get_parent())
		var counts = _count_command_result(result)
		accepted_count += counts[0]
		rejected_count += counts[1]
	_emit_command_feedback("Stop", accepted_count, rejected_count)


## 返回当前 Selection 中已迁移到 C# 命令链路的可控单位数量，供灰盒 HUD 更新可用状态。
func get_selected_command_unit_count() -> int:
	return _get_selected_controlled_units().filter(
		func(unit): return unit.find_child("Movement") != null
	).size()


## 返回可保存自身或出厂默认战斗策略的选中实体数量。
func get_selected_combat_policy_unit_count() -> int:
	return _get_selected_controlled_units().filter(_is_migrated_combat_unit).size()


## 为当前 Selection 中已迁移的战斗单位设置持续交战姿态，并汇总即时接收结果。
func set_selected_engagement_stance(stance: String):
	_submit_selected_combat_policy("EngagementStance", stance)


## 为当前 Selection 中已迁移的战斗单位设置持续开火策略，并汇总即时接收结果。
func set_selected_fire_policy(policy: String):
	_submit_selected_combat_policy("FirePolicy", policy)


## 返回当前选中已迁移战斗单位的统一战斗策略；混合值或无选中时返回空字符串。
func get_selected_combat_policy(policy_name: String) -> String:
	var command_units = _get_selected_controlled_units().filter(_is_migrated_combat_unit)
	if command_units.is_empty():
		return ""
	var gateway = _get_command_gateway()
	var first_value: String = (
		gateway.GetEngagementStance(command_units[0])
		if policy_name == "EngagementStance"
		else gateway.GetFirePolicy(command_units[0])
	)
	for unit in command_units:
		var value: String = (
			gateway.GetEngagementStance(unit)
			if policy_name == "EngagementStance"
			else gateway.GetFirePolicy(unit)
		)
		if value != first_value:
			return ""
	return first_value


func _submit_selected_combat_policy(policy_name: String, value: String):
	var selected_units = _get_selected_controlled_units()
	var command_units = selected_units.filter(_is_migrated_combat_unit)
	var accepted_count := 0
	var rejected_count: int = selected_units.size() - command_units.size()
	if not command_units.is_empty():
		var gateway = _get_command_gateway()
		var result = (
			gateway.SetEngagementStance(command_units, value, get_parent())
			if policy_name == "EngagementStance"
			else gateway.SetFirePolicy(command_units, value, get_parent())
		)
		var counts = _count_command_result(result)
		accepted_count += counts[0]
		rejected_count += counts[1]
	_emit_command_feedback(value, accepted_count, rejected_count)


func _reject_ground_only_entity_target(command_name: String):
	var rejected_count: int = max(_get_selected_controlled_units().size(), 1)
	_emit_command_feedback(command_name, 0, rejected_count)


func _execute_targeted_force_move(target_point: Vector3):
	var selected_units = _get_selected_controlled_units()
	var command_units = selected_units.filter(
		func(unit): return Actions.Moving.is_applicable(unit)
	)
	var terrain_units = command_units.filter(
		func(unit): return unit.movement_domain == Constants.Match.Navigation.Domain.TERRAIN
	)
	var air_units = command_units.filter(
		func(unit): return unit.movement_domain == Constants.Match.Navigation.Domain.AIR
	)
	var targets = Utils.Match.Unit.Movement.crowd_moved_to_new_pivot(terrain_units, target_point)
	targets += Utils.Match.Unit.Movement.crowd_moved_to_new_pivot(air_units, target_point)
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
	var command_units = selected_units.filter(
		func(unit): return Actions.Moving.is_applicable(unit)
	)
	var terrain_units = command_units.filter(
		func(unit): return unit.movement_domain == Constants.Match.Navigation.Domain.TERRAIN
	)
	var air_units = command_units.filter(
		func(unit): return unit.movement_domain == Constants.Match.Navigation.Domain.AIR
	)
	var targets = Utils.Match.Unit.Movement.crowd_moved_to_new_pivot(terrain_units, target_point)
	targets += Utils.Match.Unit.Movement.crowd_moved_to_new_pivot(air_units, target_point)
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
	var command_units = selected_units.filter(
		func(unit): return Actions.Moving.is_applicable(unit)
	)
	var terrain_units = command_units.filter(
		func(unit): return unit.movement_domain == Constants.Match.Navigation.Domain.TERRAIN
	)
	var air_units = command_units.filter(
		func(unit): return unit.movement_domain == Constants.Match.Navigation.Domain.AIR
	)
	var targets = Utils.Match.Unit.Movement.crowd_moved_to_new_pivot(terrain_units, target_point)
	targets += Utils.Match.Unit.Movement.crowd_moved_to_new_pivot(air_units, target_point)
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


func _execute_targeted_entity_attack_move(target_unit):
	var selected_units = _get_selected_controlled_units()
	var command_units = selected_units.filter(
		func(unit): return Actions.Moving.is_applicable(unit)
	)
	var accepted_count := 0
	var rejected_count: int = selected_units.size() - command_units.size()
	if not command_units.is_empty():
		var result = _get_command_gateway().EntityAttackMoveUnits(
			command_units, target_unit, get_parent()
		)
		var counts = _count_command_result(result)
		accepted_count += counts[0]
		rejected_count += counts[1]
	_emit_command_feedback("EntityAttackMove", accepted_count, rejected_count)


func _execute_targeted_force_attack(target_unit):
	var selected_units = _get_selected_controlled_units()
	var command_units = selected_units
	var accepted_count := 0
	var rejected_count: int = selected_units.size() - command_units.size()
	if not command_units.is_empty():
		var result = _get_command_gateway().ForceAttackUnits(
			command_units, target_unit, get_parent()
		)
		var counts = _count_command_result(result)
		accepted_count += counts[0]
		rejected_count += counts[1]
	_emit_command_feedback("ForceAttack", accepted_count, rejected_count)


func _execute_targeted_ground_force_attack(target_point: Vector3):
	var selected_units = _get_selected_controlled_units()
	var command_units = selected_units
	var accepted_count := 0
	var rejected_count: int = selected_units.size() - command_units.size()
	if not command_units.is_empty():
		var result = _get_command_gateway().ForceAttackGround(
			command_units, target_point, get_parent()
		)
		var counts = _count_command_result(result)
		accepted_count += counts[0]
		rejected_count += counts[1]
	_emit_command_feedback("ForceAttackGround", accepted_count, rejected_count)


func _get_selected_controlled_units() -> Array:
	return get_tree().get_nodes_in_group("selected_units").filter(
		func(unit): return unit.is_in_group("controlled_units")
	)


func _is_local_controller() -> bool:
	var match_node = find_parent("Match")
	if match_node == null or not match_node.has_method("get_local_player"):
		return true
	var local_player = match_node.get_local_player()
	return local_player != null and local_player == get_parent()


func _get_command_gateway():
	var command_gateway = NetSession.command_gateway_for(get_parent())
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


func _on_order_state_changed(
	_order_id: String,
	_command_id: String,
	unit_id: String,
	kind: String,
	_previous_state: String,
	current_state: String,
	_replaced_by_command_id: String
):
	if current_state != "Unreachable":
		return
	if _find_controlled_unit(unit_id) == null:
		return
	command_feedback.emit(kind, 0, 1, "Unreachable")


func _find_controlled_unit(unit_id: String) -> Node:
	for unit in get_tree().get_nodes_in_group("controlled_units"):
		if unit.has_meta("ai_rts_unit_id") and str(unit.get_meta("ai_rts_unit_id")) == unit_id:
			return unit
	return null


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
	if controlled_structures.is_empty():
		return
	var result = find_parent("Match").get_node("RallyPointRuntime").SetPosition(
		controlled_structures, target_point, get_parent()
	)
	var counts = _count_command_result(result)
	_emit_command_feedback("SetRallyPoint", counts[0], counts[1])


func _navigate_selected_units_towards_unit(target_unit, target_position: Vector3):
	var at_least_one_unit_navigated = false
	var selected_units = get_tree().get_nodes_in_group("selected_units").filter(
		func(unit): return unit.is_in_group("controlled_units")
	)
	var air_units_without_entity_interaction = selected_units.filter(
		func(unit): return _should_air_move_to_entity_position(unit, target_unit)
	)
	var air_move_targets = Utils.Match.Unit.Movement.crowd_moved_to_new_pivot(
		air_units_without_entity_interaction, target_position
	)
	var accepted_count := 0
	var rejected_count := 0
	for tuple in air_move_targets:
		var result = _get_command_gateway().MoveUnits([tuple[0]], tuple[1], get_parent())
		var counts = _count_command_result(result)
		accepted_count += counts[0]
		rejected_count += counts[1]
		at_least_one_unit_navigated = true
	if not air_move_targets.is_empty():
		_emit_command_feedback("Move", accepted_count, rejected_count)
	for unit in selected_units:
		if unit in air_units_without_entity_interaction:
			continue
		if _navigate_unit_towards_unit(unit, target_unit):
			at_least_one_unit_navigated = true
	return at_least_one_unit_navigated


## 判断空中单位是否对目标没有更高优先级的实体交互，应把本次点击解释为位置移动。
func _should_air_move_to_entity_position(unit, target_unit) -> bool:
	if unit.movement_domain != Constants.Match.Navigation.Domain.AIR:
		return false
	if not Actions.Moving.is_applicable(unit):
		return false
	if Actions.CollectingResourcesSequentially.is_applicable(unit, target_unit):
		return false
	if Actions.AutoAttacking.is_applicable(unit, target_unit):
		return false
	if Actions.Constructing.is_applicable(unit, target_unit):
		return false
	if (
		(target_unit.is_in_group("adversary_units") or target_unit.is_in_group("controlled_units"))
		and Actions.Following.is_applicable(unit)
	):
		return false
	return true


func _navigate_unit_towards_unit(unit, target_unit):
	if Actions.CollectingResourcesSequentially.is_applicable(unit, target_unit):
		var result = _get_command_gateway().GatherResources([unit], target_unit, get_parent())
		var counts = _count_command_result(result)
		_emit_command_feedback("Gather", counts[0], counts[1])
		return true
	if Actions.AutoAttacking.is_applicable(unit, target_unit):
		var result = _get_command_gateway().AttackUnits([unit], target_unit, get_parent())
		var counts = _count_command_result(result)
		_emit_command_feedback("Attack", counts[0], counts[1])
		return true
	if Actions.Constructing.is_applicable(unit, target_unit):
		var result = _get_command_gateway().ConstructUnits([unit], target_unit, get_parent())
		var counts = _count_command_result(result)
		_emit_command_feedback("Construct", counts[0], counts[1])
		return true
	if (
		(target_unit.is_in_group("adversary_units") or target_unit.is_in_group("controlled_units"))
		and Actions.Following.is_applicable(unit)
	):
		var result = _get_command_gateway().FollowEntityUnits([unit], target_unit, get_parent())
		var counts = _count_command_result(result)
		_emit_command_feedback("FollowEntity", counts[0], counts[1])
		return true
	if Actions.MovingToUnit.is_applicable(unit):
		var result = _get_command_gateway().ApproachEntityUnits([unit], target_unit, get_parent())
		var counts = _count_command_result(result)
		_emit_command_feedback("ApproachEntity", counts[0], counts[1])
		return true
	if _try_setting_rally_point_to_unit(unit, target_unit):
		return true
	return false  # gdlint: ignore = max-returns


## 按已有战斗或生产能力过滤策略设置，不依赖具体单位类名。
func _is_migrated_combat_unit(unit) -> bool:
	return unit.attack_range != null or unit.find_child("RallyPoint") != null


func _try_setting_rally_point_to_unit(unit, target_unit):
	if not unit is Structure:
		return false
	if not target_unit is ResourceUnit and unit.player != target_unit.player:
		# it's not allowed to set rally point to enemy at the moment as with current implementation
		# the position of enemy unit hidden in the fog of war could be hinted
		return false
	if unit.find_child("RallyPoint") == null:
		return false
	var result = find_parent("Match").get_node("RallyPointRuntime").SetTarget(
		[unit], target_unit, get_parent()
	)
	var counts = _count_command_result(result)
	_emit_command_feedback("SetRallyPoint", counts[0], counts[1])
	return true


## 显式清除选中生产建筑的自定义集结点并回归默认门口。
func clear_selected_rally_points():
	var structures = _get_selected_controlled_units().filter(
		func(unit): return unit.find_child("RallyPoint") != null
	)
	if structures.is_empty():
		_emit_command_feedback("ClearRallyPoint", 0, 0)
		return
	var result = find_parent("Match").get_node("RallyPointRuntime").Clear(
		structures, get_parent()
	)
	var counts = _count_command_result(result)
	_emit_command_feedback("ClearRallyPoint", counts[0], counts[1])


## 返回当前选中并声明集结能力的生产者数量。
func get_selected_rally_producer_count() -> int:
	return _get_selected_controlled_units().filter(
		func(unit): return unit.find_child("RallyPoint") != null
	).size()


func _clear_skill_targeting():
	_skill_targeting_id = ""
	_skill_targeting_kind = ""


## 只选中一个己方单位时返回其 HUD 技能槽。
func get_selected_skill_slots() -> Array:
	var units = _get_selected_controlled_units()
	if units.size() != 1:
		return []
	var gateway = _get_command_gateway()
	# 联机傀儡端的 NetCommandProxy 不承载本地技能槽查询（技能为单机特性），返回空槽。
	if not gateway.has_method("GetHudSlots"):
		return []
	return gateway.GetHudSlots(units[0])


## 自身技能立即施放；单位/地面技能进入一次点选。
func begin_skill_use(skill_id: String, target_kind: String):
	_is_force_move_targeting = false
	_is_force_attack_targeting = false
	_is_tactical_withdraw_targeting = false
	_is_ground_attack_move_targeting = false
	if target_kind == "self":
		_clear_skill_targeting()
		command_targeting_changed.emit("")
		_cast_selected_skill(skill_id, null, null)
		return
	_skill_targeting_id = skill_id
	_skill_targeting_kind = target_kind
	command_targeting_changed.emit("Skill:%s" % skill_id)


func _cast_selected_skill(skill_id: String, target_unit, target_position):
	var selected_units = _get_selected_controlled_units()
	if selected_units.is_empty():
		_emit_command_feedback(skill_id, 0, 1)
		return
	var gateway = _get_command_gateway()
	var result
	if target_position != null:
		result = gateway.CastSkillGround(selected_units, skill_id, target_position, get_parent())
	else:
		result = gateway.CastSkill(selected_units, skill_id, get_parent(), target_unit)
	var counts = _count_command_result(result)
	_emit_command_feedback(skill_id, counts[0], counts[1])


func _on_terrain_targeted(position):
	if position == null or not (position is Vector3):
		return
	print("[INPUT] terrain_targeted player=", get_parent().name, " selected=", _get_selected_controlled_units().map(func(unit): return unit.name))
	if not _skill_targeting_id.is_empty():
		if _skill_targeting_kind != "ground":
			_reject_ground_only_entity_target(_skill_targeting_id)
			return
		var skill_id: String = _skill_targeting_id
		cancel_command_targeting()
		_cast_selected_skill(skill_id, null, position)
		return
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


func _on_unit_targeted(unit, target_position: Vector3):
	if not _skill_targeting_id.is_empty():
		if _skill_targeting_kind != "unit":
			_reject_ground_only_entity_target(_skill_targeting_id)
			return
		var skill_id: String = _skill_targeting_id
		cancel_command_targeting()
		_cast_selected_skill(skill_id, unit, null)
		var skill_targetability = unit.find_child("Targetability")
		if skill_targetability != null:
			skill_targetability.animate()
		return
	if _is_force_move_targeting:
		_reject_ground_only_entity_target("ForceMove")
		return
	if _is_tactical_withdraw_targeting:
		_reject_ground_only_entity_target("TacticalWithdraw")
		return
	if _is_force_attack_targeting:
		_is_force_attack_targeting = false
		command_targeting_changed.emit("")
		_execute_targeted_force_attack(unit)
		var explicit_targetability = unit.find_child("Targetability")
		if explicit_targetability != null:
			explicit_targetability.animate()
			return
	if _is_ground_attack_move_targeting:
		_is_ground_attack_move_targeting = false
		command_targeting_changed.emit("")
		_execute_targeted_entity_attack_move(unit)
		var attack_move_targetability = unit.find_child("Targetability")
		if attack_move_targetability != null:
			attack_move_targetability.animate()
		return
	if _navigate_selected_units_towards_unit(unit, target_position):
		var targetability = unit.find_child("Targetability")
		if targetability != null:
			targetability.animate()


func _on_unit_spawned(_unit):
	pass
