extends Node

enum State { FORMING, ATTACKING }

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
var _state := State.FORMING
var _attached_unit_ids: Array[String] = []
var _current_target_id := ""
var _fallback_target_by_member := {}


## 绑定编组容量以及公共查询、固定身份命令边界。
func setup(
	expected_number_of_units: int,
	world_query_runtime,
	query_session_id: String,
	command_gateway
):
	_expected_number_of_units = expected_number_of_units
	_world_query_runtime = world_query_runtime
	_query_session_id = query_session_id
	_command_gateway = command_gateway


## 返回仍登记在编组中的稳定单位数量。
func size() -> int:
	return _attached_unit_ids.size()


## 判断稳定单位 ID 是否已经属于本编组。
func has_member(unit_id: String) -> bool:
	return unit_id in _attached_unit_ids


## 在成军阶段接收一个由己方公共查询返回的作战单位。
func attach_entity(entity: Dictionary):
	assert(_state == State.FORMING, "unexpected state")
	var unit_id: String = entity.get("id", "")
	if unit_id.is_empty() or has_member(unit_id):
		return
	_attached_unit_ids.append(unit_id)
	if size() >= _expected_number_of_units:
		_state = State.ATTACKING


## 用同一帧己方快照清理损失成员，并在满编后推进受视野约束的作战决策。
func refresh(own_entities: Array):
	var members := _member_entities(own_entities)
	_attached_unit_ids.clear()
	for member in members:
		_attached_unit_ids.append(member.get("id", ""))
	for member_id in _fallback_target_by_member.keys():
		if member_id not in _attached_unit_ids:
			_fallback_target_by_member.erase(member_id)
	if _state == State.ATTACKING and members.is_empty():
		queue_free()
		return
	if _state == State.FORMING or members.is_empty():
		return
	_refresh_combat(members)


## 返回当前快照中仍然存活的编组成员。
func _member_entities(own_entities: Array) -> Array:
	return own_entities.filter(
		func(entity): return entity.get("id", "") in _attached_unit_ids
	)


## 优先延续现有目标；目标终止后才选择最近的当前可见敌军。
func _refresh_combat(members: Array):
	var center := _group_center(members)
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

	visible_enemies.sort_custom(
		func(left, right):
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
		_move_idle_members(members, last_known_structures[0]["position"])


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


## 只让当前没有活动订单的成员向敌方建筑残影推进。
func _move_idle_members(members: Array, destination: Vector3):
	var unit_ids: Array[String] = []
	for member in members:
		var order = member.get("order", null)
		if order == null:
			unit_ids.append(member.get("id", ""))
		elif order.get("kind", "") == "Move":
			var target = order.get("target", null)
			if target != null and target.get("position", null) != null:
				if _planar_distance_squared(target["position"], destination) <= (
					POSITION_EPSILON_SQUARED
				):
					continue
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
