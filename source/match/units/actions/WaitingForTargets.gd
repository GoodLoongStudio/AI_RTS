extends "res://source/match/units/actions/Action.gd"

const AttackingWhileInRange = preload("res://source/match/units/actions/AttackingWhileInRange.gd")
const AutoAttacking = preload("res://source/match/units/actions/AutoAttacking.gd")
const ExplicitForceAttacking = preload("res://source/match/units/actions/ExplicitForceAttacking.gd")
const Moving = preload("res://source/match/units/actions/Moving.gd")

const REFRESH_INTERVAL = 1.0 / 60.0 * 10.0
## 警戒（Guard）姿态的追逐上限（相对岗位点的视野倍数）——与
## `AutoAttacking.GUARD_MAX_CHASE_FACTOR` 同源，追逐收手与"不再接新战"
## 必须用同一把尺子，否则单位会"追远→收手→眼前又有人→再追"无限循环。
const GUARD_MAX_CHASE_FACTOR = AutoAttacking.GUARD_MAX_CHASE_FACTOR

var _timer = null
var _sub_action = null
## 是否正在"回岗位点"的归途中（归途可被敌人进视野打断）。
var _returning_home = false
## 空间网格索敌索引（Match 级，2026-09-26 优化）。为 null 时回退全场组扫描。
var _target_grid = null

@onready var _unit = Utils.NodeEx.find_parent_with_group(self, "units")
@onready var _command_runtime = null


func _ready():
	# Initial scene units are added to the `units` group by Match after their
	# child _ready callbacks. Fall back to the direct Unit parent, then resolve
	# CommandRuntime once the Match tree is available.
	if _unit == null and get_parent() != null:
		_unit = get_parent()
	if _unit != null:
		var match_node = _unit.find_parent("Match")
		if match_node != null:
			_command_runtime = match_node.get_node_or_null("CommandRuntime")
			_target_grid = match_node.get_node_or_null("TargetAcquisitionGrid")
	_timer = Timer.new()
	_timer.timeout.connect(_on_timer_timeout)
	add_child(_timer)
	_start_acquisition_timer(true)


## 索敌计时器：稳态周期恒为 REFRESH_INTERVAL（~167ms），AI 反应节奏不变。
## 错峰：首个回调按网格分配的相位槽推迟（slot/STAGGER_SLOTS 个周期），
## 把 N 个单位原本"同帧对齐"的全场扫描摊开到一个索敌周期内——
## 相位由注册顺序决定（稳定、可复现，不用随机数或墙上时钟）。
## 玩家显式命令与战斗策略变化的立即刷新（refresh_combat_policy）不走本队列。
func _start_acquisition_timer(first: bool) -> void:
	if first and _target_grid != null and _target_grid.use_stagger and _unit != null:
		_timer.one_shot = true
		_timer.start(
			REFRESH_INTERVAL * float(_target_grid.get_phase_slot(_unit))
			/ float(_target_grid.STAGGER_SLOTS)
		)
		return
	_timer.one_shot = false
	_timer.start(REFRESH_INTERVAL)


func _to_string():
	return "{0}({1})".format([super(), str(_sub_action) if _sub_action != null else ""])


func is_idle():
	return _sub_action == null


## 在权威战斗策略变化时立即撤销旧自主行为，避免轮询间隔内继续追击或开火。
func refresh_combat_policy():
	if _unit == null:
		return
	var movement = _unit.find_child("Movement")
	if movement != null:
		movement.stop()
	if _sub_action != null:
		_sub_action.free()
		return
	_on_timer_timeout()


func _get_units_to_attack():
	if _unit == null or _command_runtime == null:
		return []
	# 单人测试局：AI 单位保持待机，不因视野内目标自动开火；
	# 人类单位及明确下达的攻击命令仍走正常路径。
	if _unit.player != null and _unit.player.has_method("is_passive_test_ai"):
		if _unit.player.is_passive_test_ai():
			return []
	if _command_runtime.GetFirePolicy(_unit) == "HoldFire":
		return []
	var stance: String = _command_runtime.GetEngagementStance(_unit)
	# 回基地期间完全停止自主索敌，避免追击逻辑抢回移动控制权。
	if stance == "ReturnToBase":
		return []
	var guard_anchor: Vector3 = _command_runtime.GetGuardAnchor(_unit)
	if stance == "Guard":
		# 已经追出岗位太远 → 不再接新战，先回家（否则刚被 leash 收手，回头又看见
		# 一个敌人 → 再追 → 再收手，单位永远在离家越来越远的地方打）。
		if guard_anchor.is_finite() and _unit.global_position_yless.distance_to(
			guard_anchor * Vector3(1, 0, 1)
		) > _unit.sight_range * GUARD_MAX_CHASE_FACTOR:
			return []
	# 索敌圆心 = **本单位自己的位置**（用户口径 2026-09-22：敌方单位进入
	# 本单位视野就该打）。警戒旧口径拿"岗位点"当圆心——单位一旦离开岗位
	# （归途/被命令挪动），贴着他身边的敌人反而进不了索敌圈，单位站着挨打。
	var detection_origin: Vector3 = _unit.global_position_yless
	var detection_range: float = _unit.sight_range
	if stance == "HoldGround":
		detection_range = _unit.attack_range
	# 候选筛选源（2026-09-26 优化）：默认走 Match 级空间网格（XZ 分格，
	# 覆盖检测圆的所有格子，不只 9 宫格）；敌我/域/姿态/有效性仍在此处按
	# 原规则精确检查。AIRTS_TARGETING=basestats/baseline 时回退全场组扫描。
	var scan_t0 := Time.get_ticks_usec()
	var candidates: Array = (
		_target_grid.acquire_candidates(detection_origin, detection_range)
		if _target_grid != null
		else get_tree().get_nodes_in_group("units")
	)
	var result := candidates.filter(
		func(unit):
			return (
				is_instance_valid(unit)
				and unit.player != _unit.player
				and unit.movement_domain in _unit.attack_domains
				and detection_origin.distance_to(unit.global_position_yless) <= detection_range
			)
	)
	# 诊断：索敌总耗时 = 候选收集 + 精确过滤（基线/网格两口径对称计入）。
	if _target_grid != null:
		_target_grid.note_scan(candidates.size(), Time.get_ticks_usec() - scan_t0)
	return result


func _attack_unit(unit):
	_timer.timeout.disconnect(_on_timer_timeout)
	_sub_action = (
		AutoAttacking.new(unit) if _unit.movement_speed > 0.0 else AttackingWhileInRange.new(unit)
	)
	_sub_action.tree_exited.connect(_on_attack_finished.bind(_sub_action))
	add_child(_sub_action)
	_unit.action_updated.emit()


## 炮塔等固定单位的显式强制攻击入口：作为子动作挂载，结束后续接自主索敌。
func force_attack(target_unit) -> bool:
	if _sub_action != null:
		_sub_action.queue_free()
	_sub_action = ExplicitForceAttacking.new(target_unit)
	_sub_action.force_attack_ended.connect(
		func(reason): _unit.explicit_force_attack_ended.emit(reason)
	)
	_sub_action.tree_exited.connect(_on_attack_finished.bind(_sub_action))
	add_child(_sub_action)
	_unit.action_updated.emit()
	return true


func _on_timer_timeout():
	if _timer.one_shot:
		# 相位偏移的首跑结束 → 转入标准周期（此后一直重复，动作期间只摘回调不停表，
		# 攻击开始/结束不会让相位重新扎堆）。
		_start_acquisition_timer(false)
	if _command_runtime == null:
		# 单位创建早于 Match 就绪时 @onready 解析为 Nil（基线既有问题），
		# 每个计时周期静默跳过，避免对 Nil 调 C# 方法刷屏。
		return
	# 敌人进视野 → 打（归途中的立即转身，不再走完回家的路再回头）。
	var units_to_attack = _get_units_to_attack()
	if not units_to_attack.is_empty():
		if _returning_home:
			_abort_return_home()
		if _sub_action == null:
			_attack_unit(_pick_closest_unit(units_to_attack, _unit))
		return
	if _sub_action != null:
		return
	# 附近没有敌人 → 该回岗位点就回。
	_try_returning_to_guard_anchor()


func _on_attack_finished(finished_action = null):
	if not is_inside_tree():
		return
	# 只清理退出的那个子动作，避免旧子动作收尾时误清新子动作
	if finished_action != null and _sub_action != finished_action:
		return
	_sub_action = null
	_returning_home = false
	_unit.action_updated.emit()
	if not _timer.timeout.is_connected(_on_timer_timeout):
		_timer.timeout.connect(_on_timer_timeout)


func _try_returning_to_guard_anchor() -> bool:
	if _unit == null or _command_runtime == null:
		return false
	if _command_runtime.GetEngagementStance(_unit) != "Guard":
		return false
	var guard_anchor: Vector3 = _command_runtime.GetGuardAnchor(_unit)
	if not guard_anchor.is_finite() or _unit.global_position.distance_to(guard_anchor) <= 0.5:
		return false
	# 不摘 timer：归途途中敌人进视野要能立即转身（旧口径摘了 timer，
	# 单位在整段归途里对敌人完全无反应，白挨打）。
	_sub_action = Moving.new(guard_anchor)
	_sub_action.tree_exited.connect(_on_attack_finished)
	_returning_home = true
	add_child(_sub_action)
	_unit.action_updated.emit()
	return true


## 打断归途：释放回家移动，回到"空闲待命"（随后由调用方决定接战）。
func _abort_return_home():
	_returning_home = false
	if _sub_action != null and is_instance_valid(_sub_action):
		_sub_action.free()
	var movement = _unit.find_child("Movement")
	if movement != null:
		movement.stop()


static func _pick_closest_unit(units, unit):
	assert(not units.is_empty())
	# 平方距离与距离同序，省掉每候选一次 sqrt。
	# 等距目标的 tie-break 用 instance_id（稳定、与遍历顺序无关）：
	# 不允许候选来源的遍历顺序（格子顺序/组顺序）让单位在等距目标间随机换目标。
	var distance_to_closest_unit := INF
	var closest_unit = null
	for unit_to_check in units:
		var distance = unit.global_position_yless.distance_squared_to(
			unit_to_check.global_position_yless
		)
		if distance < distance_to_closest_unit or (
			is_equal_approx(distance, distance_to_closest_unit)
			and closest_unit != null
			and unit_to_check.get_instance_id() < closest_unit.get_instance_id()
		):
			distance_to_closest_unit = distance
			closest_unit = unit_to_check
	return closest_unit
