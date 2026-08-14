extends Area3D

const LegacyMovingAction = preload("res://source/match/units/actions/Moving.gd")
const LegacyTacticalWithdrawingAction = preload(
	"res://source/match/units/actions/TacticalWithdrawing.gd"
)
const LegacyGroundAttackMovingAction = preload(
	"res://source/match/units/actions/GroundAttackMoving.gd"
)
const LegacyForceAttackAction = preload(
	"res://source/match/units/actions/ExplicitForceAttacking.gd"
)
const LegacyGroundForceAttackAction = preload(
	"res://source/match/units/actions/ExplicitGroundForceAttacking.gd"
)
const LegacyOrdinaryAttackAction = preload(
	"res://source/match/units/actions/OrdinaryAttacking.gd"
)

signal selected
signal deselected
signal hp_changed
signal action_changed(new_action)
signal action_updated
signal explicit_force_attack_ended(reason)
signal ordinary_attack_ended(reason)
signal entity_attack_move_ended(reason)

const MATERIAL_ALBEDO_TO_REPLACE = Color(0.99, 0.81, 0.48)
const MATERIAL_ALBEDO_TO_REPLACE_EPSILON = 0.05

var hp = null:
	set = _set_hp
var hp_max = null:
	set = _set_hp_max
var attack_damage = null
var attack_interval = null
var attack_range = null
var attack_domains = []
var radius:
	get = _get_radius
var movement_domain:
	get = _get_movement_domain
var movement_speed:
	get = _get_movement_speed
var can_reverse:
	get = _get_can_reverse
var can_fire_while_moving:
	get = _get_can_fire_while_moving
var can_force_fire_ground:
	get = _get_can_force_fire_ground
var moving_weapon_arc_degrees:
	get = _get_moving_weapon_arc_degrees
var sight_range = null
var player:
	get:
		return get_parent()
var color:
	get:
		return player.color
var action = null:
	set = _set_action
var global_position_yless:
	get:
		return global_position * Vector3(1, 0, 1)
var type:
	get = _get_type

var _action_locked = false

@onready var _match = find_parent("Match")


func _ready():
	if not _match.is_node_ready():
		await _match.ready
	_setup_color()
	_setup_default_properties_from_constants()
	assert(_safety_checks())


func is_revealing():
	return is_in_group("revealed_units") and visible


# Temporary C# migration bridge. Domain/Application code calls this through
# LegacyMovementPort; new command code must not assign action directly.
func request_legacy_move(target_position: Vector3) -> bool:
	if find_child("Movement") == null:
		return false
	action = LegacyMovingAction.new(target_position, true)
	return true


# Temporary C# migration bridge. Ground AttackMove owns its encounter state
# while the Application layer retains the authoritative order identity.
func request_legacy_ground_attack_move(target_position: Vector3) -> bool:
	if find_child("Movement") == null or attack_range == null:
		return false
	action = LegacyGroundAttackMovingAction.new(target_position)
	return true


# 临时 C# 迁移桥：Entity AttackMove 保留最终目标身份，同时复用已评审的接敌与恢复推进 Action。
func request_legacy_entity_attack_move(target_unit) -> bool:
	if (
		find_child("Movement") == null
		or attack_range == null
		or target_unit == null
		or not is_instance_valid(target_unit)
	):
		return false
	var attack_move = LegacyGroundAttackMovingAction.new(target_unit)
	attack_move.final_target_ended.connect(entity_attack_move_ended.emit)
	action = attack_move
	return true


# Temporary C# migration bridge. Tactical withdrawal keeps the vehicle rear
# aligned with the local navigation path instead of locking its initial facing.
func request_legacy_tactical_withdraw(target_position: Vector3) -> bool:
	if find_child("Movement") == null or not can_reverse:
		return false
	action = LegacyTacticalWithdrawingAction.new(target_position)
	return true


func request_legacy_halt_movement() -> bool:
	if find_child("Movement") == null:
		return false
	if action != null and action.get_script() in [
		LegacyMovingAction, LegacyGroundAttackMovingAction, LegacyTacticalWithdrawingAction
	]:
		action = null
	return true


## 迁移期统一 Stop 桥：暂停移动类任务并取消当前普通/强制攻击，不改变持续战斗策略。
## 采集和施工迁移后应在这里改为“保留任务、暂停且不自动恢复”，而不是丢弃任务身份。
func request_legacy_stop() -> bool:
	if action != null and action.get_script() in [
		LegacyMovingAction,
		LegacyGroundAttackMovingAction,
		LegacyTacticalWithdrawingAction,
		LegacyOrdinaryAttackAction,
		LegacyForceAttackAction,
		LegacyGroundForceAttackAction,
	]:
		action = null
	return true


# Temporary C# migration bridge. It only asks the current autonomous combat
# action to re-read authoritative policy; it does not choose a stance itself.
func request_legacy_refresh_combat_policy():
	if action != null and action.has_method("refresh_combat_policy"):
		action.refresh_combat_policy()


# Temporary C# migration bridge. Ordinary Attack only accepts authorization
# already granted by the Application command service.
func request_legacy_attack(target_unit) -> bool:
	if attack_range == null or target_unit == null or not "hp" in target_unit:
		return false
	var ordinary_attack = LegacyOrdinaryAttackAction.new(target_unit)
	ordinary_attack.attack_ended.connect(ordinary_attack_ended.emit)
	action = ordinary_attack
	return true


# Temporary C# migration bridge. Explicit ForceAttack intentionally permits
# friendly targets and ignores persistent HoldFire for this order only.
func request_legacy_force_attack(target_unit) -> bool:
	if attack_range == null or target_unit == null or not "hp" in target_unit:
		return false
	var force_attack = LegacyForceAttackAction.new(target_unit)
	force_attack.force_attack_ended.connect(explicit_force_attack_ended.emit)
	action = force_attack
	return true


## 临时 C# 迁移桥：持续炮击纯地面坐标，命中只按单位 footprint 判定。
func request_legacy_ground_force_attack(target_position: Vector3) -> bool:
	if not can_force_fire_ground or attack_range == null or find_child("Movement") == null:
		return false
	action = LegacyGroundForceAttackAction.new(target_position)
	return true


func request_legacy_cancel_force_attack() -> bool:
	if (
		action != null
		and action.get_script() in [LegacyForceAttackAction, LegacyGroundForceAttackAction]
	):
		action = null
	return true


func _set_hp(value):
	var old_hp = hp
	hp = max(0, value)
	if old_hp != null and hp < old_hp:
		MatchSignals.unit_damaged.emit(self)
	hp_changed.emit()
	if hp == 0:
		_handle_unit_death()


func _set_hp_max(value):
	hp_max = value
	hp_changed.emit()


func _get_radius():
	if find_child("Movement") != null:
		return find_child("Movement").radius
	if find_child("MovementObstacle") != null:
		return find_child("MovementObstacle").radius
	return null


func _get_movement_domain():
	if find_child("Movement") != null:
		return find_child("Movement").domain
	if find_child("MovementObstacle") != null:
		return find_child("MovementObstacle").domain
	return null


func _get_movement_speed():
	if find_child("Movement") != null:
		return find_child("Movement").speed
	return 0.0


func _get_can_reverse() -> bool:
	return false


func _get_can_fire_while_moving() -> bool:
	return false


func _get_can_force_fire_ground() -> bool:
	return false


func _get_moving_weapon_arc_degrees() -> float:
	return 0.0


func _is_movable():
	return _get_movement_speed() > 0.0


func _setup_color():
	var material = player.get_color_material()
	Utils.Match.traverse_node_tree_and_replace_materials_matching_albedo(
		find_child("Geometry"),
		MATERIAL_ALBEDO_TO_REPLACE,
		MATERIAL_ALBEDO_TO_REPLACE_EPSILON,
		material
	)


func _set_action(action_node):
	if not is_inside_tree() or _action_locked:
		if action_node != null:
			action_node.queue_free()
		return
	_action_locked = true
	_teardown_current_action()
	action = action_node
	if action != null:
		var action_copy = action  # bind() performs copy itself, but lets force copy just in case
		action.tree_exited.connect(_on_action_node_tree_exited.bind(action_copy))
		add_child(action_node)
	_action_locked = false
	action_changed.emit(action)


func _get_type():
	var unit_script_path = get_script().resource_path
	var unit_file_name = unit_script_path.substr(unit_script_path.rfind("/") + 1)
	var unit_name = unit_file_name.split(".")[0]
	return unit_name


func _teardown_current_action():
	if action != null and action.is_inside_tree():
		action.queue_free()
		remove_child(action)  # triggers _on_action_node_tree_exited immediately


func _safety_checks():
	if movement_domain == Constants.Match.Navigation.Domain.AIR:
		assert(
			(
				radius < Constants.Match.Air.Navmesh.MAX_AGENT_RADIUS
				or is_equal_approx(radius, Constants.Match.Air.Navmesh.MAX_AGENT_RADIUS)
			),
			"Unit radius exceeds the established limit"
		)
	elif movement_domain == Constants.Match.Navigation.Domain.TERRAIN:
		assert(
			(
				not _is_movable()
				or (
					radius < Constants.Match.Terrain.Navmesh.MAX_AGENT_RADIUS
					or is_equal_approx(radius, Constants.Match.Terrain.Navmesh.MAX_AGENT_RADIUS)
				)
			),
			"Unit radius exceeds the established limit"
		)
	return true


func _handle_unit_death():
	tree_exited.connect(func(): MatchSignals.unit_died.emit(self))
	queue_free()


func _setup_default_properties_from_constants():
	var default_properties = Constants.Match.Units.DEFAULT_PROPERTIES[
		get_script().resource_path.replace(".gd", ".tscn")
	]
	for property in default_properties:
		set(property, default_properties[property])


func _on_action_node_tree_exited(action_node):
	assert(action_node == action, "unexpected action released")
	action = null
