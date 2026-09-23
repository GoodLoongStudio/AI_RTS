extends Node

enum State { FORMING, ATTACKING, RETREATING }

## 撤退后**最短稳定期**（模拟毫秒）：期间即使人数补足也不回头，
## 避免"一边撤一边折返"的抖动（方案 3.E.3）。
const RETREAT_SETTLE_MS := 4000
## 编组中心连续多久没有可观测位移即判为"卡住"（模拟毫秒），见 `_last_center` 的说明。
const STUCK_TIMEOUT_MS := 12000
## 判定"有可观测位移"的最小距离（米）。
const STUCK_MOVE_EPSILON_M := 1.0
## 重返阈值系数：兵力必须恢复到满编的这个比例才考虑再出击。
## 必须 **高于** 撤退阈值（`retreat_threshold`，如 0.35/0.5/0.6）才能形成滞回，
## 否则"掉到 0.35 撤退、补到 0.36 就回头"，行为等同抖动。
const RE_ENGAGE_THRESHOLD := 0.8
## 视作"立刻能伤害我方"的威胁半径（米）：该半径内的非结构敌单位会被提到最高优先，
## 压过远处的低价值目标（如勘探工人）。首版近似，不做战斗仿真（方案允许）。
const THREAT_IMMEDIATE_RADIUS_M := 18.0

const FIELD_POSITION := 1 << 0
const FIELD_TYPE := 1 << 1
const FIELD_RELATION := 1 << 2
const FIELD_ORDER := 1 << 6
const GLOBAL_DEMO_SCAN_RADIUS_M := 100000.0
const POSITION_EPSILON_SQUARED := 0.25

var _expected_number_of_units := 0
var _min_launch_size := 0
## 首波最早可出击的**模拟时刻**（ms）。0 = 无约束。
## 只对 FORMING（尚未出击过）的编组生效：兵可以先造好等着，到点再出门。
var _earliest_attack_sim_ms := 0
## 【2026-09-19】卡住检测：编组中心连续 STUCK_TIMEOUT_MS 没有可观测位移 ⇒ 判为"卡住"。
## 实测证据（200 秒真局观测）：3 个编组全部满编 6/6、状态 ATTACKING，却停在距基地 67m
## 处一动不动、`攻击中=0`。原因是 `_advance_towards(override_orders=false)` 会跳过所有
## "已有非 Move 订单"的单位（避免打断交战），而当那个陈旧订单再也无法带来推进时，
## 整个编组就永久站桩 —— 违反方案"编组永不静止待机"。
var _last_center := Vector3.INF
var _last_moved_sim_ms := 0
## 【2026-09-19】目标**推进判据**：对同一目标持续 TARGET_STALL_TIMEOUT_MS 仍未实质
## 缩短距离 ⇒ 判定"够不到"，放弃该目标并短期忽略。这是"编组站桩"的正解 —— 根因是
## `_issue_attack_for_available_members()` 只要"某个成员已下过 Attack 令"就返回 true，
## 于是 `_refresh_combat` 永久 return，后面的推进分支一次都走不到（攻击永远够不到目标时
## 就是永久站桩）。只看"是否已下令"不够，必须看"攻击是否在推进"。
const TARGET_STALL_TIMEOUT_MS := 10000
## 判定"距离有实质缩短"的阈值（米）。
const TARGET_CLOSE_ENOUGH_M := 3.0

var _current_target_started_sim_ms := 0
var _current_target_best_distance := INF
## 【2026-09-19】兜底推进的**"终点之后"语义**：编组走到"敌方出生点"附近后，若继续
## 指向同一个坐标，`_order_targets_position()` 会判定"已在该点"而不再下指令 ——
## 整组就永久驻扎在敌人门口（实测 170s~200s 距离恒定 61.7m 不动）。因此到达附近后
## 改为**环绕该点轮换搜索方位**，每 SEARCH_SECTOR_DWELL_MS 换一次扇区以免抖动。
## （方案要求"编组永不静止待机"；只给终点、不给终点之后的行为等于把站桩点从自家
## 门口搬到敌人门口。）
const SEARCH_ARRIVE_RADIUS_M := 25.0
const SEARCH_RING_RADIUS_M := 22.0
const SEARCH_SECTOR_DWELL_MS := 15000
const SEARCH_SECTOR_COUNT := 4

var _search_sector_index := 0
var _search_sector_since_sim_ms := 0
## 短期忽略集合：够不到的目标 id → true（到 `_ignored_target_until_sim_ms` 为止）。
var _ignored_target_ids := {}
var _ignored_target_until_sim_ms := 0
## 本次撤退开始的模拟毫秒（用于最短稳定期）。
var _retreat_started_sim_ms := 0
## 【2026-09-21 S2 多线】袭扰组标记：优先打工人与落单单位、不啃结构塔，
## 与主力组（结构优先）形成两条独立战线（方案 2.D："中等主攻加独立矿区袭扰"）。
var _harasser := false
var _world_query_runtime = null
var _query_session_id := ""
var _command_gateway = null
var _retreat_threshold := 0.5
var _state := State.FORMING
var _attached_unit_ids: Array[String] = []
var _current_target_id := ""
var _fallback_target_by_member := {}
var _defense_position := Vector3.INF
var _passive_test_mode := false


## 绑定编组容量以及公共查询、固定身份命令边界。
func setup(
	expected_number_of_units: int,
	world_query_runtime,
	query_session_id: String,
	command_gateway,
	retreat_threshold: float = 0.5,
	passive_test_mode: bool = false,
	min_launch_size: int = 0,
	earliest_attack_sim_ms: int = 0,
	harasser: bool = false
):
	_expected_number_of_units = expected_number_of_units
	_world_query_runtime = world_query_runtime
	_query_session_id = query_session_id
	_command_gateway = command_gateway
	_retreat_threshold = retreat_threshold
	_passive_test_mode = passive_test_mode
	_min_launch_size = min_launch_size
	_earliest_attack_sim_ms = earliest_attack_sim_ms
	_harasser = harasser


## 当前战局模拟毫秒。编组被单独挂载（单测/探针）时回退实时时钟。
## 与 `SimpleClairvoyantAI.battlefield_scan` 用同一套取父节点方式。
func _now_sim_ms() -> int:
	var offense := get_parent()
	var ai := offense.get_parent() if offense != null else null
	if ai != null and ai.has_method("simulation_msec"):
		return int(ai.simulation_msec())
	return Time.get_ticks_msec()


## 读取所属 AI 的"再派间隔"（模拟秒）；取不到配置时返回 0（不额外限制）。
func _re_dispatch_interval_s() -> float:
	var offense := get_parent()
	var ai := offense.get_parent() if offense != null else null
	if ai != null and "re_dispatch_interval_s" in ai:
		return maxf(0.0, float(ai.re_dispatch_interval_s))
	return 0.0


## 简单档可在未满编时先出击；0 = 必须满编。
## 另外受**首波出击门槛**约束：尚未出击过（FORMING）的编组必须等到
## `_earliest_attack_sim_ms`。兵可以提前造好，但不提前出门 —— 这样"生产"与
## "出击"两个节奏彻底分离（方案第 1 节：困难档不该靠 120 秒不产兵来"更慢"）。
func _ready_to_attack() -> bool:
	var need := _expected_number_of_units if _min_launch_size <= 0 \
		else mini(_min_launch_size, _expected_number_of_units)
	if size() < need:
		return false
	if _state == State.FORMING and _earliest_attack_sim_ms > 0:
		return _now_sim_ms() >= _earliest_attack_sim_ms
	return true


## 返回仍登记在编组中的稳定单位数量。
func size() -> int:
	return _attached_unit_ids.size()


## 返回编组满编容量（增援目标数量）。
func capacity() -> int:
	return _expected_number_of_units


## 是否处于撤退回基地的状态（不计入进攻任务，可被增援回满）。
func is_retreating() -> bool:
	return _state == State.RETREATING


## 判断稳定单位 ID 是否已经属于本编组。
func has_member(unit_id: String) -> bool:
	return unit_id in _attached_unit_ids


## 接收一个由己方公共查询返回的作战单位；允许向 ATTACKING/RETREATING 编组增援。
func attach_entity(entity: Dictionary):
	var unit_id: String = entity.get("id", "")
	if unit_id.is_empty() or has_member(unit_id):
		return
	_attached_unit_ids.append(unit_id)
	if _ready_to_attack() and _state != State.RETREATING:
		_state = State.ATTACKING


## 用同一帧己方快照清理损失成员、推进状态机，并执行受视野约束的作战决策。
func refresh(own_entities: Array):
	var members := _member_entities(own_entities)
	_attached_unit_ids.clear()
	for member in members:
		_attached_unit_ids.append(member.get("id", ""))
	for member_id in _fallback_target_by_member.keys():
		if member_id not in _attached_unit_ids:
			_fallback_target_by_member.erase(member_id)
	_update_state(members)
	if _state == State.ATTACKING and members.is_empty():
		queue_free()
		return
	# 【2026-09-17 修复回归】FORMING 早退**不能吞掉防御召回**：首波出击门槛只约束
	# "主动出击"，敌人打到家门口时必须能回防（方案 3.E.5："基地遭实质攻击不能受
	# 全局长冷却阻挡"）。否则首波等待期内的编组面对进攻会站着不动。
	if members.is_empty():
		return
	if _state == State.FORMING and _defense_position == Vector3.INF:
		return
	# 【2026-09-19 修"站桩"】卡住检测必须放在 `_refresh_combat` **之前**：首版加在
	# "兜底推进"分支里，实测无效 —— 因为编组在更早的分支就 return 了（有陈旧的目标/
	# 订单残留），根本走不到兜底推进。
	# 这里做**入口级**兜底：确认卡住时直接 Halt 掉全组订单，下一拍单位变为"无订单"，
	# 后续的 `_advance_towards` 就会正常推进它们。12 秒没有任何可观测位移已经不可能
	# 是正常交战，所以覆盖订单是安全的（方案要求"编组永不静止待机"）。
	if _note_center_and_is_stuck(_group_center(members)):
		var stuck_ids: Array[String] = []
		for member in members:
			stuck_ids.append(member.get("id", ""))
		if not stuck_ids.is_empty():
			_command_gateway.Halt(stuck_ids)
			_clear_current_target()
		return
	if _passive_test_mode:
		# 保留成员登记和生产缺口统计，但不向 AI 编组下达移动/攻击命令。
		return
	_refresh_combat(members)


## 状态机：满编成军 → 出击；出击中损失过半 → 整编撤退回主基地；回满 → 再出击。
func _update_state(members: Array):
	match _state:
		State.FORMING:
			if _ready_to_attack():
				_state = State.ATTACKING
				# 【2026-09-21 S4 验收埋点】首波出击时刻（模拟秒）+ 人数。
				# 批跑工具（tools/rule_ai_match_batch.py）解析此行断言"首波窗口"。
				print("规则 AI 首波出击 @%.1fs 人数=%d" % [_now_sim_ms() / 1000.0, size()])
		State.ATTACKING:
			if (
				not members.is_empty()
				and size() < _expected_number_of_units * _retreat_threshold
			):
				_state = State.RETREATING
				_retreat_started_sim_ms = _now_sim_ms()
				_clear_current_target()
		State.RETREATING:
			# 【2026-09-17 方案 3.E.3】撤退→重返必须有**滞回 + 最短稳定期**。
			# 历史：曾经只要"人数补足"（_ready_to_attack，阈值 = 撤退阈值）就立刻回头
			# ⇒ 刚补齐就折返、边撤边打（方案第 1 节："撤退仅看人数且可中途折返"）。
			# 现在三个条件都满足才恢复进攻：
			#   ① 已撤够 RETREAT_SETTLE_MS（最短稳定期，防止抖动）；
			#   ② 兵力恢复到 满编 × RE_ENGAGE_THRESHOLD（高于撤退阈值 ⇒ 滞回）；
			#   ③ 满足出击门槛（含首波时间与最小出击规模）。
			# 本游戏没有治疗/维修能力，所以**不虚构"回血完成"**，只看人数与时间。
			if _now_sim_ms() - _retreat_started_sim_ms < RETREAT_SETTLE_MS:
				return
			# 【2026-09-19 三档校准】再派间隔：本波结束（进入 RETREATING）后必须等满
			# `re_dispatch_interval_s` 才投入下一波 ⇒ 这是"压迫是否连续"的直接来源。
			# EASY 32s / NORMAL 17s / HARD 8s（方案第 2 节区间的中值）。
			if _now_sim_ms() - _retreat_started_sim_ms < int(_re_dispatch_interval_s() * 1000.0):
				return
			if size() < _expected_number_of_units * RE_ENGAGE_THRESHOLD:
				return
			if _ready_to_attack():
				_state = State.ATTACKING
				# 【2026-09-21 S4 验收埋点】再次出击时刻（再派间隔的实测证据）。
				print("规则 AI 再次出击 @%.1fs 人数=%d" % [_now_sim_ms() / 1000.0, size()])
				_clear_current_target()
				_defense_position = Vector3.INF


## 返回当前快照中仍然存活的编组成员。
func _member_entities(own_entities: Array) -> Array:
	return own_entities.filter(
		func(entity): return entity.get("id", "") in _attached_unit_ids
	)


## 作战决策总入口：防御召回 > 撤退行军 > 常规交战（目标价值序）> 兜底推进，绝不站桩。
func _refresh_combat(members: Array):
	var center := _group_center(members)
	if _defense_position != Vector3.INF:
		_advance_towards(members, _defense_position, true)
		return
	if _state == State.RETREATING:
		_advance_towards(members, _rally_point(members), true)
		return
	var observations := _scan_battlefield(center)
	var visible_enemies: Array = observations.filter(
		func(entity):
			return (
				entity.get("state", "") == "VisibleNow"
				and entity.get("relation", "") == "Enemy"
			)
	)
	var current_target = _find_entity(visible_enemies, _current_target_id)
	if not _current_target_id.is_empty():
		if current_target != null:
			# 【2026-09-19 修"站桩"】只看"是否已下过 Attack 令"会永久 return（见
			# TARGET_STALL_TIMEOUT_MS 的说明）。改为要求"攻击确实在推进"：够不到就
			# 放弃该目标并短期忽略，让下面的分支（含兜底推进）重新生效。
			if _is_target_making_progress(members, current_target):
				_issue_attack_for_available_members(members, current_target)
				return
			_ignore_target(_current_target_id)
			_clear_current_target()
		elif _members_still_attacking_current_target(members):
			return
		else:
			_clear_current_target()

	# 目标价值序（AI-plan Part A Phase 4）：Worker > 生产建筑 > 防御塔 > 其他结构 > 其他单位，
	# 同权重取距编组中心最近者。
	visible_enemies.sort_custom(
		func(left, right):
			var weight_left := _target_priority(left, center)
			var weight_right := _target_priority(right, center)
			if weight_left != weight_right:
				return weight_left < weight_right
			return _planar_distance_squared(left["position"], center) < (
				_planar_distance_squared(right["position"], center)
			)
	)
	for target in visible_enemies:
		var candidate_id: String = target.get("id", "")
		# 跳过刚判定"够不到"的目标，否则下一拍立刻又选回同一个、继续站桩空转。
		if _is_target_ignored(candidate_id):
			continue
		if _issue_attack_for_available_members(members, target):
			_current_target_id = candidate_id
			_reset_target_progress()
			return

	var last_known_structures: Array = observations.filter(
		func(entity):
			return (
				entity.get("state", "") == "LastKnown"
				and entity.get("relation", "") == "Enemy"
				and entity.get("kind", "") == "Structure"
			)
	)
	last_known_structures.sort_custom(
		func(left, right):
			return _planar_distance_squared(left["position"], center) < (
				_planar_distance_squared(right["position"], center)
			)
	)
	if not last_known_structures.is_empty():
		_advance_towards(members, last_known_structures[0]["position"], false)
		return

	# 兜底推进（AI-plan Part A Phase 2）：没有任何可见敌军与已知敌建筑时，
	# 向敌方出生点推进——编组永不静止待机。
	var enemy_spawn := _nearest_enemy_spawn(center)
	if enemy_spawn != Vector3.INF:
		# 卡住检测已上移到 refresh() 入口（见那里的说明）。
		# 目的地改为 `_search_destination()`：到达敌方出生点附近后环绕搜索，
		# 不再永远指向同一个坐标（见 SEARCH_ARRIVE_RADIUS_M 的说明）。
		_advance_towards(members, _search_destination(center, enemy_spawn), false)


## 兜底推进的目的地：还没到敌方出生点就直接去；到了附近就按扇区环绕搜索，
## 每 `SEARCH_SECTOR_DWELL_MS` 换一个方位（节流防抖，避免每拍改点造成原地转圈）。
func _search_destination(center: Vector3, enemy_spawn: Vector3) -> Vector3:
	if center.distance_to(enemy_spawn) >= SEARCH_ARRIVE_RADIUS_M:
		return enemy_spawn
	var now := _now_sim_ms()
	if now - _search_sector_since_sim_ms >= SEARCH_SECTOR_DWELL_MS:
		_search_sector_index = (_search_sector_index + 1) % SEARCH_SECTOR_COUNT
		_search_sector_since_sim_ms = now
	var angle := TAU * float(_search_sector_index) / float(SEARCH_SECTOR_COUNT)
	return enemy_spawn + Vector3(cos(angle), 0.0, sin(angle)) * SEARCH_RING_RADIUS_M


## 记录编组中心并判断是否"卡住"：连续 `STUCK_TIMEOUT_MS` 没有可观测位移即认为
## 当前订单已无法带来推进（例如目标消失后遗留的持续性追击订单）。
## 首次调用只记录基准，返回 false。
func _note_center_and_is_stuck(center: Vector3) -> bool:
	var now := _now_sim_ms()
	if _last_center == Vector3.INF or center.distance_to(_last_center) > STUCK_MOVE_EPSILON_M:
		_last_center = center
		_last_moved_sim_ms = now
		return false
	if now - _last_moved_sim_ms < STUCK_TIMEOUT_MS:
		return false
	# 卡住确认：把计时基准推到现在，避免每拍都强制覆盖订单。
	_last_moved_sim_ms = now
	return true


## 判断当前目标是否"在推进"：以**编组中心到目标的距离**是否实质缩短为准。
## 首次接触只记录基准；距离缩短超过 TARGET_CLOSE_ENOUGH_M 即刷新基准与计时；
## 超过 TARGET_STALL_TIMEOUT_MS 没缩短 ⇒ 判定够不到（返回 false）。
func _is_target_making_progress(members: Array, target: Dictionary) -> bool:
	var target_position: Vector3 = target.get("position", Vector3.INF)
	if target_position == Vector3.INF or members.is_empty():
		return true
	var now := _now_sim_ms()
	var distance := _group_center(members).distance_to(target_position)
	if _current_target_started_sim_ms == 0 or _current_target_best_distance == INF:
		_current_target_started_sim_ms = now
		_current_target_best_distance = distance
		return true
	if distance < _current_target_best_distance - TARGET_CLOSE_ENOUGH_M:
		_current_target_best_distance = distance
		_current_target_started_sim_ms = now
		return true
	return now - _current_target_started_sim_ms < TARGET_STALL_TIMEOUT_MS


## 把"够不到"的目标加入短期忽略集合，避免下一拍又把它选回来（否则会来回空转）。
func _ignore_target(target_id: String) -> void:
	if target_id.is_empty():
		return
	_ignored_target_ids[target_id] = true
	_ignored_target_until_sim_ms = _now_sim_ms() + TARGET_STALL_TIMEOUT_MS


## 目标是否仍在短期忽略期内。超期后整表清空（自然过期，无需逐条管理）。
func _is_target_ignored(target_id: String) -> bool:
	if _ignored_target_ids.is_empty():
		return false
	if _now_sim_ms() >= _ignored_target_until_sim_ms:
		_ignored_target_ids.clear()
		return false
	return _ignored_target_ids.has(target_id)


## 清除当前目标时同步重置"推进判据"的基准，避免下一个目标沿用旧基准。
func _reset_target_progress() -> void:
	_current_target_started_sim_ms = 0
	_current_target_best_distance = INF


## 目标价值权重：越小越优先。未知类型按「结构 3 / 单位 4」兜底。
##
## 【2026-09-17 方案 3.E.1】在原"价值序"之前叠加**威胁紧迫度**：方案要求
## "先合法性和局部生存，再比较任务收益"，且"敌方能立刻伤害自己的单位必须有
## 合理的紧急优先级"。原实现里 `worker` 恒为 0（最高），于是**远处一个工人**会
## 压过**近处正在开火的敌战斗单位**（方案第 1 节："远方工人优先于近处战斗威胁"）。
## 首版近似（方案允许）：离编组中心很近的**非结构**单位视为紧迫威胁，优先级 0；
## 其余沿用原价值序，`worker` 顺延为 1。不做昂贵战斗仿真。
func _target_priority(entity: Dictionary, group_center: Vector3) -> int:
	var type_id: String = entity.get("type_id", "")
	var is_structure: bool = entity.get("kind", "") == "Structure"
	if not is_structure:
		var position: Vector3 = entity.get("position", Vector3.INF)
		if _planar_distance_squared(position, group_center) <= (
			THREAT_IMMEDIATE_RADIUS_M * THREAT_IMMEDIATE_RADIUS_M
		):
			return 0
	# 【2026-09-21 S2 多线】袭扰组与主力组的目标分工（只在**没有立即威胁**时生效，
	# 上面已提前返回 0）：袭扰组优先工人与落单单位、结构压到最低权重；
	# 主力组维持原价值序（生产建筑/塔优先）。两支编组因此自然分到不同目标，
	# 而不是撞同一个（方案 2.D："中等主攻加独立矿区袭扰"）。
	if _harasser:
		if type_id == "worker":
			return 0
		return 1 if not is_structure else 5
	match type_id:
		"worker":
			return 1
		"vehicle_factory", "aircraft_factory", "command_center":
			return 1
		"anti_ground_turret", "anti_air_turret":
			return 2
		_:
			return 3 if is_structure else 4


## 向敌方出生点中距编组中心最近的一个推进；查询失败或无敌人出生点返回 Vector3.INF。
func _nearest_enemy_spawn(center: Vector3) -> Vector3:
	var result: Dictionary = _world_query_runtime.GetSpawnPoints(_query_session_id)
	if result.get("status", "") != "Accepted":
		return Vector3.INF
	var best_position := Vector3.INF
	var best_distance := INF
	for point in result.get("spawn_points", []):
		if point.get("relation", "") != "Enemy":
			continue
		var position: Vector3 = point.get("position", Vector3.INF)
		if position == Vector3.INF:
			continue
		var distance := _planar_distance_squared(position, center)
		if distance < best_distance:
			best_distance = distance
			best_position = position
	return best_position


## 撤退/回防集结点：距编组中心最近的己方 CommandCenter；无 CC 时用成员当前位置。
func _rally_point(members: Array) -> Vector3:
	var center := _group_center(members)
	var result: Dictionary = _world_query_runtime.GetOwnForces(
		_query_session_id,
		FIELD_POSITION | FIELD_TYPE
	)
	if result.get("status", "") == "Accepted":
		var command_centers: Array = result.get("entities", []).filter(
			func(entity): return entity.get("type_id", "") == "command_center"
		)
		var best_position := Vector3.INF
		var best_distance := INF
		for command_center in command_centers:
			var position: Vector3 = command_center["position"]
			var distance := _planar_distance_squared(position, center)
			if distance < best_distance:
				best_distance = distance
				best_position = position
		if best_position != Vector3.INF:
			return best_position
	return center if not members.is_empty() else Vector3.INF


## 防御召回：把整组拉到指定位置（覆盖攻击订单），威胁解除前持续生效。
func assume_defense_position(position: Vector3):
	_defense_position = position
	_clear_current_target()


## 解除防御召回：停火一拍，让常规交战逻辑重新接管目标选择。
func resume_offense():
	_defense_position = Vector3.INF
	var member_ids: Array[String] = []
	for unit_id in _attached_unit_ids:
		member_ids.append(unit_id)
	if not member_ids.is_empty():
		_command_gateway.Halt(member_ids)


## 扫描全局 Demo 范围；服务仍会剔除战争迷雾中的实时敌军。
##
## 【性能·勿回退，用户 2026-09-15 批准】半径取 `GLOBAL_DEMO_SCAN_RADIUS_M` 时结果与"以谁为中心"
## 无关（就是全场可见实体），所以交给 AI 按物理帧缓存共用一次查询 —— 过去每个编组各扫一次，
## 3 个电脑 × 若干编组时是每拍最贵的重复开销。编组被单独挂载（单测/探针）时回退直连查询。
func _scan_battlefield(center: Vector3) -> Array:
	var offense := get_parent()
	var ai := offense.get_parent() if offense != null else null
	if ai != null and ai.has_method("battlefield_scan"):
		return ai.battlefield_scan()
	var result: Dictionary = _world_query_runtime.ScanCircle(
		_query_session_id,
		center,
		GLOBAL_DEMO_SCAN_RADIUS_M,
		FIELD_POSITION | FIELD_TYPE | FIELD_RELATION
	)
	if result.get("status", "") != "Accepted":
		push_warning("rule AI battlegroup scan was rejected: %s" % result)
		return []
	return result.get("entities", [])


## 向没有同目标攻击订单且未被暂停的成员下令，并让目标域不兼容者移动到观察位置。
func _issue_attack_for_available_members(members: Array, target: Dictionary) -> bool:
	var target_id: String = target.get("id", "")
	var attacking_ids: Array[String] = []
	var fallback_ids: Array[String] = []
	var already_engaged := false
	for member in members:
		var member_id: String = member.get("id", "")
		var order = member.get("order", null)
		if order != null and order.get("state", "") == "Suspended":
			continue
		if _order_targets_entity(order, "Attack", target_id):
			already_engaged = true
			continue
		if _fallback_target_by_member.get(member_id, "") == target_id:
			if not _order_targets_position(order, target["position"]):
				fallback_ids.append(member_id)
			continue
		attacking_ids.append(member_id)

	if not attacking_ids.is_empty():
		var result: Dictionary = _command_gateway.Attack(
			attacking_ids,
			target.get("kind", ""),
			target_id
		)
		for unit_result in result.get("unit_results", []):
			if unit_result.get("accepted", false):
				already_engaged = true
				continue
			# 【2026-09-17 修复确定缺陷】原实现把"打不了这个目标"的成员加进 fallback
			# 并 `Move` 到**目标位置** ⇒ 无法对空的地面单位会一路贴到空军下方
			# （方案第 1 节："无法对空的单位会 Move 追空军"）。
			# 现改为：攻击域不兼容（地面打空军）或该单位根本没有武器时——**不追**，
			# 也不登记 fallback，让它留在候选池里等下一个**合法**目标。
			# `_refresh_combat` 收到 false 后会自动继续尝试目标价值序里的下一个候选。
			if unit_result.get("error_code", "") in [
				"WeaponCannotTargetDomain", "UnitCannotAttack"
			]:
				continue

	if not fallback_ids.is_empty():
		_command_gateway.Move(fallback_ids, target["position"])
	return already_engaged or not fallback_ids.is_empty()


## 向目标点推进。override_orders=false 时只移动空闲成员（常规兜底）；
## true 时覆盖攻击等既有订单（撤退/防御召回需要整组立即移动）。
func _advance_towards(members: Array, destination: Vector3, override_orders: bool):
	var unit_ids: Array[String] = []
	for member in members:
		var order = member.get("order", null)
		if order != null and order.get("state", "") == "Suspended":
			continue
		if _order_targets_position(order, destination):
			continue
		if not override_orders and order != null and order.get("kind", "") != "Move":
			continue
		unit_ids.append(member.get("id", ""))
	if not unit_ids.is_empty():
		_command_gateway.Move(unit_ids, destination)


## 判断至少一个成员是否仍持有当前普通攻击订单。
func _members_still_attacking_current_target(members: Array) -> bool:
	return members.any(
		func(member):
			return _order_targets_entity(
				member.get("order", null), "Attack", _current_target_id
			)
	)


## 判断一个公开订单是否匹配指定类型与实体目标。
func _order_targets_entity(order, kind: String, target_id: String) -> bool:
	if order == null or order.get("kind", "") != kind:
		return false
	var target = order.get("target", null)
	return target != null and target.get("entity_id", "") == target_id


## 判断一个公开移动订单是否已经指向近似相同的世界位置。
func _order_targets_position(order, destination: Vector3) -> bool:
	if order == null or order.get("kind", "") != "Move":
		return false
	var target = order.get("target", null)
	return (
		target != null
		and target.get("position", null) != null
		and _planar_distance_squared(target["position"], destination) <= POSITION_EPSILON_SQUARED
	)


## 返回稳定 ID 对应的观察结果；不存在时显式返回空值。
func _find_entity(entities: Array, entity_id: String):
	for entity in entities:
		if entity.get("id", "") == entity_id:
			return entity
	return null


## 计算当前存活成员的平面中心。
func _group_center(members: Array) -> Vector3:
	var center := Vector3.ZERO
	for member in members:
		center += member["position"]
	return center / float(members.size())


## 清除已终止目标以及只对该目标有效的移动退化记录。
func _clear_current_target():
	_current_target_id = ""
	_fallback_target_by_member.clear()
	# 同步重置"目标推进判据"的基准，避免下一个目标沿用上一个目标的计时。
	_reset_target_progress()


## 返回两个世界位置的平面距离平方。
func _planar_distance_squared(left: Vector3, right: Vector3) -> float:
	var delta := (left - right) * Vector3(1.0, 0.0, 1.0)
	return delta.length_squared()


## 返回当前存活成员的平面中心（无存活成员时返回 Vector3.INF）。
func center_for(own_entities: Array) -> Vector3:
	var members := _member_entities(own_entities)
	if members.is_empty():
		return Vector3.INF
	return _group_center(members)
