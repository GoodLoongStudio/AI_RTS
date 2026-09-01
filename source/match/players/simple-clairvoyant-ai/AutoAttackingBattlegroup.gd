extends Node

enum State { FORMING, ATTACKING, RETREATING }

const FIELD_POSITION := 1 << 0
const FIELD_TYPE := 1 << 1
const FIELD_RELATION := 1 << 2
const FIELD_ORDER := 1 << 6
const GLOBAL_DEMO_SCAN_RADIUS_M := 100000.0
const POSITION_EPSILON_SQUARED := 0.25

var _expected_number_of_units := 0
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
	passive_test_mode: bool = false
):
	_expected_number_of_units = expected_number_of_units
	_world_query_runtime = world_query_runtime
	_query_session_id = query_session_id
	_command_gateway = command_gateway
	_retreat_threshold = retreat_threshold
	_passive_test_mode = passive_test_mode


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
	if size() >= _expected_number_of_units and _state != State.RETREATING:
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
	if _state == State.FORMING or members.is_empty():
		return
	if _passive_test_mode:
		# 保留成员登记和生产缺口统计，但不向 AI 编组下达移动/攻击命令。
		return
	_refresh_combat(members)


## 状态机：满编成军 → 出击；出击中损失过半 → 整编撤退回主基地；回满 → 再出击。
func _update_state(members: Array):
	match _state:
		State.FORMING:
			if size() >= _expected_number_of_units:
				_state = State.ATTACKING
		State.ATTACKING:
			if (
				not members.is_empty()
				and size() < _expected_number_of_units * _retreat_threshold
			):
				_state = State.RETREATING
				_clear_current_target()
		State.RETREATING:
			if size() >= _expected_number_of_units:
				_state = State.ATTACKING
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
			_issue_attack_for_available_members(members, current_target)
			return
		if _members_still_attacking_current_target(members):
			return
		_clear_current_target()

	# 目标价值序（AI-plan Part A Phase 4）：Worker > 生产建筑 > 防御塔 > 其他结构 > 其他单位，
	# 同权重取距编组中心最近者。
	visible_enemies.sort_custom(
		func(left, right):
			var weight_left := _target_priority(left)
			var weight_right := _target_priority(right)
			if weight_left != weight_right:
				return weight_left < weight_right
			return _planar_distance_squared(left["position"], center) < (
				_planar_distance_squared(right["position"], center)
			)
	)
	for target in visible_enemies:
		if _issue_attack_for_available_members(members, target):
			_current_target_id = target.get("id", "")
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
		_advance_towards(members, enemy_spawn, false)


## 目标价值权重：越小越优先。未知类型按「结构 3 / 单位 4」兜底。
func _target_priority(entity: Dictionary) -> int:
	var type_id: String = entity.get("type_id", "")
	var is_structure: bool = entity.get("kind", "") == "Structure"
	match type_id:
		"worker":
			return 0
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
func _scan_battlefield(center: Vector3) -> Array:
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
			if unit_result.get("error_code", "") in [
				"WeaponCannotTargetDomain", "UnitCannotAttack"
			]:
				var unit_id: String = unit_result.get("unit_id", "")
				_fallback_target_by_member[unit_id] = target_id
				fallback_ids.append(unit_id)

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
