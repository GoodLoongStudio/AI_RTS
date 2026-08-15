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
const LegacyGatherAction = preload(
	"res://source/match/units/actions/CollectingResourcesSequentially.gd"
)
const LegacyConstructingAction = preload("res://source/match/units/actions/Constructing.gd")
const LegacyMovingToUnitAction = preload("res://source/match/units/actions/MovingToUnit.gd")
const LegacyFollowingAction = preload("res://source/match/units/actions/Following.gd")

signal selected
signal deselected
signal hp_changed
signal action_changed(new_action)
signal action_updated
signal explicit_force_attack_ended(reason)
signal ordinary_attack_ended(reason)
signal entity_attack_move_ended(reason)
signal gather_task_ended(reason)

const MATERIAL_ALBEDO_TO_REPLACE = Color(0.99, 0.81, 0.48)
const MATERIAL_ALBEDO_TO_REPLACE_EPSILON = 0.05

var hp = null:
	set = _set_hp
var hp_max = null:
	set = _set_hp_max
var unit_type_id := ""
var weapon_definition_id := ""
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
var can_reverse := false
var can_fire_while_moving := false
var can_force_fire_ground := false
var moving_weapon_arc_degrees := 0.0
var resources_max := 0
var construction_work_per_tick := 0
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
var _suppress_damage_event := false

@onready var _match = find_parent("Match")


func _ready():
	if not _match.is_node_ready():
		await _match.ready
	_setup_color()
	_setup_properties_from_balance_catalog()
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


## 临时 Rally 桥：非 Worker 出厂后只靠近资源或其他静态实体。
func request_legacy_move_to_unit(target_unit) -> bool:
	if not LegacyMovingToUnitAction.is_applicable(self):
		return false
	action = LegacyMovingToUnitAction.new(target_unit)
	return true


## 临时 Rally 桥：出厂单位持续跟随同玩家移动实体。
func request_legacy_follow(target_unit) -> bool:
	if not LegacyFollowingAction.is_applicable(self):
		return false
	action = LegacyFollowingAction.new(target_unit)
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
	if action != null and action.get_script() == LegacyGatherAction:
		return action.suspend_task()
	if action != null and action.get_script() == LegacyConstructingAction:
		# 施工任务尚未具备保留阶段的暂停桥，必须明确拒绝，不能返回假成功。
		return false
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


## 临时 C# 迁移桥：开始围绕玩家明确指定资源点的持续采集与交付任务。
func request_legacy_gather(resource_unit) -> bool:
	if not LegacyGatherAction.is_applicable(self, resource_unit):
		return false
	var gather_action = LegacyGatherAction.new(resource_unit)
	gather_action.task_ended.connect(gather_task_ended.emit)
	action = gather_action
	return true


## 临时 C# 迁移桥：暂停整个采集任务并保留阶段、目标和未交付载荷。
func request_legacy_suspend_work() -> bool:
	if action == null or action.get_script() != LegacyGatherAction:
		return false
	return action.suspend_task()


## 临时 C# 迁移桥：开始或恢复前往指定施工现场的完整任务。
func request_legacy_construct(construction_site) -> bool:
	if not LegacyConstructingAction.is_applicable(self, construction_site):
		return false
	action = LegacyConstructingAction.new(construction_site)
	return true


## 临时 C# 迁移桥：暂停施工并停止移动/贡献，工地与订单身份由 C# 保留。
func request_legacy_suspend_construction() -> bool:
	if action == null or action.get_script() != LegacyConstructingAction:
		return false
	return action.suspend_task()


## 查询当前 Worker 是否已经贴近指定现场并正在贡献工作量。
func is_legacy_contributing_to_construction(construction_site) -> bool:
	return (
		action != null
		and action.get_script() == LegacyConstructingAction
		and action.is_contributing_to(construction_site)
	)


## 终态清理施工表现；不会保留现场 Node 引用。
func request_legacy_clear_construction():
	if action != null and action.get_script() == LegacyConstructingAction:
		action = null


## 设置非伤害来源 HP；仍更新血条，但不会广播 unit_damaged。
func set_hp_without_damage(value):
	_suppress_damage_event = true
	hp = value
	_suppress_damage_event = false


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
	if old_hp != null and hp < old_hp and not _suppress_damage_event:
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


## 从 Match 唯一配置快照注入单位基础属性和当前主武器，不读取场景路径常量字典。
func _setup_properties_from_balance_catalog():
	_match.get_node("BalanceConfigRuntime").ConfigureUnit(self)


func _on_action_node_tree_exited(action_node):
	assert(action_node == action, "unexpected action released")
	action = null
