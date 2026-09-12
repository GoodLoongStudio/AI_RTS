extends Area3D

const LegacyMovingAction = preload("res://source/match/units/actions/Moving.gd")
const LegacyTacticalWithdrawingAction = preload(
	"res://source/match/units/actions/TacticalWithdrawing.gd"
)
const LegacyReturningToBaseAction = preload(
	"res://source/match/units/actions/ReturningToBase.gd"
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
const LegacyAutoGatherAction = preload(
	"res://source/match/units/actions/AutoGatheringResources.gd"
)
const LegacyConstructingAction = preload("res://source/match/units/actions/Constructing.gd")
const LegacyMovingToUnitAction = preload("res://source/match/units/actions/MovingToUnit.gd")
const LegacyFollowingAction = preload("res://source/match/units/actions/Following.gd")

signal selected
signal deselected
signal hp_changed
signal action_changed(new_action)
signal action_updated
## 实际创建投射物后发出；表现层不得仅凭攻击 Action 推断本帧开火。
signal attack_fired
signal explicit_force_attack_ended(reason)
signal ordinary_attack_ended(reason)
signal entity_attack_move_ended(reason)
signal gather_task_ended(reason)
signal approach_ended(reason)
signal follow_ended(reason)
## 持续回基地 Action 的权威终态：Arrived、TargetLost 或 Unreachable。
signal return_to_base_ended(reason)

const MATERIAL_ALBEDO_TO_REPLACE = Color(0.99, 0.81, 0.48)
## 无 SyntyMaterialBinder 的单位（如 GLB 步兵）的阵营着色 shader
const TEAM_TINT_SHADER: Shader = preload("res://source/shaders/3d/team_tint.gdshader")
const COMBAT_SFX = preload("res://source/match/units/traits/CombatSfx.gd")
## 客户端弹道表现回放（用 preload 而不是依赖 class_name：headless 不重扫项目注册类名）
const PROJECTILE_VISUALS = preload("res://source/match/units/projectiles/ProjectileVisuals.gd")
static var _team_material_cache := {}
## 战斗音效：命中冷却与上次 HP 快照（_process 轮询受击）
var _sfx_last_hp = null
var _sfx_impact_cooldowns := {}
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
		var owner_player = get_parent()
		if owner_player == null or not "color" in owner_player:
			return Color.WHITE
		return owner_player.color
var action = null:
	set = _set_action
var global_position_yless:
	get:
		return global_position * Vector3(1, 0, 1)
var type:
	get = _get_type

var _action_locked = false
var _suppress_damage_event := false
## 客户端表现用：权威端下发的"当前动作脚本路径"。
## 傀儡本地 `action` 恒为 null（见 `_set_action` 的 puppet 分支），
## 表现层/UI 需要知道"这个单位在干什么"时，只能读这个权威镜像（见 NetSync 快照）。
var _presented_action_path := ""

@onready var _match = find_parent("Match")


func _ready():
	if not _match.is_node_ready():
		await _match.ready
	_setup_color()
	_setup_properties_from_balance_catalog()
	assert(_safety_checks())
	_setup_combat_sfx()


func _setup_combat_sfx():
	if not has_signal("attack_fired"):
		return
	attack_fired.connect(_on_combat_sfx_fired)


## 开火音效：攻击动作发射投射物时由 attack_fired 触发。
func _on_combat_sfx_fired():
	COMBAT_SFX.play_at(self, COMBAT_SFX.fire_key_for(self))
	_broadcast_fired()


## 把"真实开火"广播给客户端（纯表现层）。
## 为什么需要：客户端是傀儡、没有投射物，`attack_fired` **永远不会**在客户端触发，
## 于是客户端既没有开火动画也没有开火音效（2026-09-11 用户报"看不到交火"）。
## 这里在权威端唯一"确实创建了投射物"的位置广播一次；只读、不改权威状态。
func _broadcast_fired() -> void:
	broadcast_presentation("fired", _fired_aim_payload())


## 权威端开火时把**真实瞄准点**一起广播。
## 为什么需要：客户端傀儡没有 Action，`ProjectileVisuals` 原先只能按
## "炮口朝向前方 attack_range 米"猜弹道终点 —— 敌人比射程近时会明显打过头
## （用户报"子弹落点不对"）。带上 aim 后客户端弹道终点与权威端一致。
## 取不到（无 Action / 目标已失效）时返回空字典，客户端退回原有近似。
func _fired_aim_payload() -> Dictionary:
	# 朝向必须一并下发（2026-09-12 用户报"坦克没瞄准好就开火"）：
	# 客户端傀儡的车体朝向走 NetSync 的 lerp_angle 插值（快照 ≈10Hz），而开火表现事件
	# 一到就立刻播炮口火光/弹道 —— 画面上炮口还在追，看起来就是"没瞄准就开火"。
	# 权威端走到这里时**必定已满足 10° 瞄准门槛**（AttackingWhileInRange._hit_target），
	# 所以把权威 yaw 一起带上，客户端收到后直接对齐即可。
	var payload := {"yaw": rotation.y}
	var aim_source = _firing_aim_source()
	if aim_source == null:
		return payload
	var aim: Vector3 = aim_source.presentation_aim_point()
	if not aim.is_finite():
		return payload
	payload["aim"] = aim
	return payload


## 找出"本次开火真正携带瞄准点"的动作节点。
## 为什么不能只看 `action`：**炮塔类建筑的顶层动作是 `WaitingForTargets`**（其 `_set_action`
## 恒拒替换，见 09-07 强制攻击提交），真正开火并带瞄准点的是它挂载的**子动作**
## （如 `AttackingWhileInRange`）。只看顶层会拿不到 aim → 客户端退回"炮口前方
## attack_range 米"的近似 —— 而那个近似的轴向原先还写反了 →
## 用户报"炮管朝着目标，炮弹却往反方向飞"（2026-09-12）。
func _firing_aim_source():
	if action == null:
		return null
	if action.has_method("presentation_aim_point"):
		return action
	# 顶层动作常常是 `WaitingForTargets`（炮塔与坦克/步兵自动交战都走它，
	# 真正带瞄准点的是它的**子动作**：`AttackingWhileInRange` / `AutoAttacking`），
	# 所以必须**递归**找。同时跳过 `is_queued_for_deletion()` 的节点：
	# 换目标时 `WaitingForTargets` 是先 `queue_free` 旧的、再加新的（延迟释放），
	# 这段时间里同时存在两个，挑到将死的那个会拿到**过期目标**的坐标
	# （2026-09-12 用户报"爆炸落点根本不对"）。取最后加进来的那个。
	var candidates: Array = []
	_collect_aim_sources(action, candidates)
	return candidates[-1] if not candidates.is_empty() else null


func _collect_aim_sources(node: Node, out: Array) -> void:
	for child in node.get_children():
		if child.is_queued_for_deletion():
			continue
		if child.has_method("presentation_aim_point"):
			out.append(child)
		_collect_aim_sources(child, out)


## 傀儡端把车体朝向直接对齐权威值，并让 NetSync 从新值继续插值。
## 为什么必须同时重置插值锚点：NetSync 每帧 `rotation.y = lerp_angle(prev, target, t)`，
## 只改 rotation.y 的话下一帧会被旧 prev 拉回去，出现"开火瞬间归位、随即弹回"的抖动。
func _snap_presentation_yaw(yaw: float) -> void:
	rotation.y = yaw
	if _match == null:
		return
	var sync = _match.get_node_or_null("NetSync")
	if sync != null and sync.has_method("reset_presentation_yaw"):
		sync.reset_presentation_yaw(str(_match.get_path_to(self)), yaw)


## 炮塔类建筑的**炮管节点**（与权威端 `AttackingWhileInRange._find_stationary_aim_node`
## 同一套定位规则：待机扫描 trait 的 `node_to_rotate`，相对 trait 解析）。
## 为什么客户端也要能解析它：权威端转的是这个炮管节点，而快照只下发**根节点** yaw，
## 于是客户端炮塔的炮管永远停在出厂角度（"联机看到的炮口和本地不一样"）。
func presentation_aim_node() -> Node3D:
	var idle_trait = find_child("RotateRandomlyWhenLookingForTargets", false, false)
	if idle_trait == null:
		return null
	var node_path: NodePath = idle_trait.get("node_to_rotate")
	if node_path.is_empty():
		return null
	var node = idle_trait.get_node_or_null(node_path)
	return node if node is Node3D else null


## 傀儡端按权威值设置炮管朝向（快照里的 `barrel_yaw`）。
## 直接赋值而不是插值：炮塔战斗转速 90°/s、快照 10Hz → 每帧 9°，
## 与权威端保持逐值一致（先求"和本地一样"，观感再按需加平滑）。
func apply_presentation_barrel_yaw(yaw: float) -> void:
	var aim_node := presentation_aim_node()
	if aim_node != null:
		aim_node.global_rotation.y = yaw


## 表现事件广播入口（权威端调用；客户端傀儡上 `broadcast_presentation` 会自行忽略）。
## 各 Action 用它把"本地才有的事件"（采集火花等）补发给客户端。
func broadcast_presentation(kind: String, payload: Dictionary = {}) -> void:
	if _match == null:
		return
	var sync = _match.get_node_or_null("NetSync")
	if sync != null and sync.has_method("broadcast_presentation"):
		sync.broadcast_presentation(kind, str(_match.get_path_to(self)), payload)


## 客户端表现入口：由 NetSync 的可靠广播在傀儡上补发同一条信号，
## 让既有的动画驱动（Fire）与音效订阅者照常工作 —— **不新增第二套表现逻辑**。
## 另外补**弹道视觉回放**：客户端的权威投射物不存在（见 `ProjectileVisuals`），
## 没有这一步就只有枪声与动画、看不到任何弹道（实测客户端弹道节点数为 0）。
func present_fired(payload: Dictionary = {}) -> void:
	if not is_inside_tree():
		return
	# 先对齐炮口朝向再播表现：炮口火光、弹道起点、开火动画都与权威端一致，
	# 否则会出现"炮管还没转过来就冒火/弹道"（用户报"没瞄准好就开火"）。
	if payload.has("yaw"):
		_snap_presentation_yaw(float(payload["yaw"]))
	attack_fired.emit()
	PROJECTILE_VISUALS.present(self, payload.get("aim", Vector3.INF))


## 当前动作脚本路径：本地跑 Action 就用真实值；傀儡端退回权威镜像。
## 表现层/UI 判断"在干什么"统一走这里，不要直接读 `action`（傀儡端恒空）。
func presentation_action_name() -> String:
	if action != null and action.get_script() != null:
		return str(action.get_script().resource_path)
	return _presented_action_path


## 接收权威端下发的当前动作路径（客户端表现镜像，见 NetSync 快照的 action 字段）。
func apply_presentation_action(action_path: String) -> void:
	_presented_action_path = action_path


## 客户端表现入口：采集火花开关。
## 客户端傀儡不跑 Action（见 `_set_action` 的 puppet 分支），
## 采集表现原先完全依赖本地 Action（CollectingResourcesWhileInRange）→ 客户端永远看不到。
func present_gather(active: bool) -> void:
	var sparkling = get_node_or_null("Sparkling")
	if sparkling == null:
		return
	if active and sparkling.has_method("enable"):
		sparkling.enable()
	elif not active and sparkling.has_method("disable"):
		sparkling.disable()


func is_revealing():
	return is_in_group("revealed_units") and visible


# Temporary C# migration bridge. Domain/Application code calls this through
# LegacyMovementPort; new command code must not assign action directly.
func request_legacy_move(target_position: Vector3) -> bool:
	if find_child("Movement") == null:
		return false
	action = LegacyMovingAction.new(target_position, true)
	return true


## 临时 C# 迁移桥：靠近单位、建筑或资源实体，并转发明确终态。
func request_legacy_approach_entity(target_unit) -> bool:
	if not LegacyMovingToUnitAction.is_applicable(self):
		return false
	var approach_action = LegacyMovingToUnitAction.new(target_unit)
	approach_action.ended.connect(approach_ended.emit)
	action = approach_action
	return true


## 临时 C# 迁移桥：持续跟随单位或建筑，并转发目标失效终态。
func request_legacy_follow_entity(target_unit) -> bool:
	if not LegacyFollowingAction.is_applicable(self):
		return false
	var follow_action = LegacyFollowingAction.new(target_unit)
	follow_action.ended.connect(follow_ended.emit)
	action = follow_action
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


## 临时 C# 迁移桥：以最高速度前往已由权威层选定的己方 CommandCenter。
## 与 TacticalWithdraw 分开，绝不启用倒车速度或后退朝向。
func request_legacy_return_to_base(command_center) -> bool:
	if (
		find_child("Movement") == null
		or command_center == null
		or not is_instance_valid(command_center)
		or not command_center.is_inside_tree()
		or not command_center.has_method("is_constructed")
		or not command_center.is_constructed()
	):
		return false
	var return_action = LegacyReturningToBaseAction.new(command_center)
	if return_action.has_signal("ended"):
		return_action.ended.connect(return_to_base_ended.emit)
	elif return_action.has_signal("return_to_base_ended"):
		return_action.return_to_base_ended.connect(return_to_base_ended.emit)
	else:
		return false
	action = return_action
	return true


## 在一次性移动命令结束后由 WaitingForTargets 请求新的基地目标。
## 目标仍由 CommandRuntime 按己方已完成基地权威筛选。
func request_legacy_start_return_to_base() -> bool:
	var runtime = _match.get_node_or_null("CommandRuntime") if _match != null else null
	if runtime == null or not runtime.has_method("FindNearestCompletedCommandCenter"):
		return false
	return request_legacy_return_to_base(runtime.FindNearestCompletedCommandCenter(self))


## 临时 C# 迁移桥：Worker 在侵略姿态下自动寻找最近资源并循环采集。
func request_legacy_start_auto_gather() -> bool:
	if resources_max <= 0 or not has_method("request_legacy_gather"):
		return false
	if action != null and action.get_script() == LegacyAutoGatherAction:
		return true
	action = LegacyAutoGatherAction.new()
	return true


func request_legacy_halt_movement() -> bool:
	if find_child("Movement") == null:
		return false
	if action != null and action.get_script() in [
		LegacyMovingAction,
		LegacyMovingToUnitAction,
		LegacyFollowingAction,
		LegacyGroundAttackMovingAction,
		LegacyTacticalWithdrawingAction,
		LegacyReturningToBaseAction,
		LegacyAutoGatherAction,
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
		LegacyMovingToUnitAction,
		LegacyFollowingAction,
		LegacyGroundAttackMovingAction,
		LegacyTacticalWithdrawingAction,
		LegacyReturningToBaseAction,
		LegacyOrdinaryAttackAction,
		LegacyForceAttackAction,
		LegacyGroundForceAttackAction,
		LegacyAutoGatherAction,
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
	var runtime = _match.get_node_or_null("CommandRuntime") if _match != null else null
	var stance := ""
	if runtime != null and runtime.has_method("GetEngagementStance"):
		stance = runtime.GetEngagementStance(self)
	if stance == "ReturnToBase":
		if action != null and action.get_script() == LegacyReturningToBaseAction:
			if action.has_method("refresh_combat_policy"):
				action.refresh_combat_policy()
			return
		request_legacy_start_return_to_base()
		return
	if resources_max > 0:
		if stance == "Aggressive":
			request_legacy_start_auto_gather()
		elif action != null and action.get_script() == LegacyAutoGatherAction:
			action = null
		return
	if action != null and action.get_script() == LegacyReturningToBaseAction:
		action = null
		return
	if action != null and action.has_method("refresh_combat_policy"):
		action.refresh_combat_policy()


## 回基地命令到达时交付 Worker 当前携带资源；无货物时保持幂等成功。
func request_legacy_deliver_resources_to_base() -> bool:
	if resources_max <= 0 or player == null:
		return false
	var resource_a_amount: int = int(get("resource_a"))
	var resource_b_amount: int = int(get("resource_b"))
	if resource_a_amount <= 0 and resource_b_amount <= 0:
		return true
	var accepted = player.add_resources(
		{"resource_a": resource_a_amount, "resource_b": resource_b_amount},
		"WorkerDelivery",
		self
	)
	if not accepted:
		return false
	set("resource_a", 0)
	set("resource_b", 0)
	return true


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
	# 炮塔等固定单位顶层动作恒为 WaitingForTargets（其 _set_action 拒绝替换），
	# 强制攻击作为其子动作挂载（2026-09-07 炮塔支持强制攻击）
	if action != null and action.has_method("force_attack"):
		return action.force_attack(target_unit)
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
	# 命中音效：C# 权威结算在改 hp 的瞬间设置 damage_presentation（reaction 类别），
	# 只在这个窗口内能读到——延迟到帧末播放（meta 随后被移除/还原）。
	if old_hp != null and hp < old_hp and has_meta("damage_presentation") and is_inside_tree():
		var reaction := str(get_meta("damage_presentation").get("reaction", "explosion"))
		call_deferred("_play_impact_sfx", COMBAT_SFX.impact_key_for(reaction, self))
	hp_changed.emit()
	if hp == 0:
		_handle_unit_death()


## 播放命中音效（按音效键冷却，连续炮击不吞掉夹在中间的子弹金属声）。
func _play_impact_sfx(sfx_key: String):
	if sfx_key.is_empty() or not is_inside_tree():
		return
	if float(_sfx_impact_cooldowns.get(sfx_key, 0.0)) > 0.0:
		return
	_sfx_impact_cooldowns[sfx_key] = 0.09
	COMBAT_SFX.play_at(self, sfx_key)


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
	# Synty 换模单位的阵营色（2026-09-05）：图集材质与玩家阵营色相乘，
	# 让步兵/兵营/工厂等新模型在小地图之外也能直观区分阵营。
	var geometry = find_child("Geometry")
	if geometry == null:
		return
	for node in geometry.find_children("*", "Node", true, false):
		if node.has_method("apply_team_tint"):
			node.apply_team_tint(player.color)
	# 无 binder 的网格（GLB 步兵等）：逐面片覆盖阵营 ShaderMaterial。
	# 已有 material_override 的（binder 单位）跳过，避免双重着色。
	for mesh_instance in geometry.find_children("*", "MeshInstance3D", true, false):
		if mesh_instance.material_override != null:
			continue
		for surface_id in range(mesh_instance.mesh.get_surface_count()):
			mesh_instance.set_surface_override_material(
				surface_id,
				_team_shader_material(mesh_instance.get_active_material(surface_id), player.color)
			)


func _team_shader_material(source_material: Material, color: Color) -> Material:
	var texture: Texture2D = null
	var base := Color.WHITE
	if source_material is StandardMaterial3D:
		texture = source_material.albedo_texture
		base = source_material.albedo_color
	var texture_key := texture.resource_path if texture != null else "none"
	var cache_key := "%s|%s|%s" % [texture_key, base.to_html(), color.to_html()]
	var material = _team_material_cache.get(cache_key)
	if material == null:
		material = ShaderMaterial.new()
		material.shader = TEAM_TINT_SHADER
		material.set_shader_parameter("albedo_texture", texture)
		material.set_shader_parameter("albedo_color", base)
		material.set_shader_parameter("team_color", color)
		material.set_shader_parameter("team_mix", 0.85)
		_team_material_cache[cache_key] = material
	return material


func _set_action(action_node):
	if action_node != null and name in ["Unit_2", "Unit_3"]:
		print(
			"[ACT] ", name,
			" puppet=", NetSession.is_client_puppet(),
			" in_tree=", is_inside_tree(),
			" locked=", _action_locked,
			" script=", action_node.get_script().resource_path if action_node.get_script() != null else "null"
		)
	if NetSession.is_client_puppet():
		if action_node != null:
			action_node.queue_free()
		return
	if not is_inside_tree() or _action_locked:
		if action_node != null:
			action_node.queue_free()
		return
	_action_locked = true
	_teardown_current_action()
	action = action_node
	if action_node != null and name in ["Unit_2", "Unit_3"]:
		print("[ACT] ", name, " attached child=", action_node.get_parent() == self)
	if action != null:
		var action_copy = action  # bind() performs copy itself, but lets force copy just in case
		action.tree_exited.connect(_on_action_node_tree_exited.bind(action_copy))
		add_child(action_node)
		if action_node.name in ["Unit_2", "Unit_3"] or name in ["Unit_2", "Unit_3"]:
			print("[ACT] ", name, " 已 add_child: in_tree=", action_node.is_inside_tree())
	_action_locked = false
	action_changed.emit(action)


func _get_type():
	var unit_script_path = get_script().resource_path
	var unit_file_name = unit_script_path.substr(unit_script_path.rfind("/") + 1)
	var unit_name = unit_file_name.split(".")[0]
	return unit_name


func _teardown_current_action():
	if action != null and action.is_inside_tree():
		if action.tree_exited.is_connected(_on_action_node_tree_exited):
			action.tree_exited.disconnect(_on_action_node_tree_exited)
		action.queue_free()
		remove_child(action)  # triggers descendant tree_exited immediately


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
	# 先取消选择再发死亡，保证 HUD / 菜单收到 unit_deselected，且 Space 仍能拿到有效坐标。
	var selection = find_child("Selection")
	if selection != null:
		selection.deselect()
	for squad_id in range(1, 4):
		var squad_group := "legacy_ai_squad_%d" % squad_id
		if is_in_group(squad_group):
			remove_from_group(squad_group)
	MatchSignals.unit_died.emit(self)
	queue_free()


## 从 Match 唯一配置快照注入单位基础属性和当前主武器，不读取场景路径常量字典。
func _setup_properties_from_balance_catalog():
	_match.get_node("BalanceConfigRuntime").ConfigureUnit(self)


func _on_action_node_tree_exited(action_node):
	assert(action_node == action, "unexpected action released")
	action = null
