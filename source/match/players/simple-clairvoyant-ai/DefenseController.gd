extends Node

signal resources_required(resources, metadata)

const AGTurretScene = preload("res://source/match/units/AntiGroundTurret.tscn")
const AATurretScene = preload("res://source/match/units/AntiAirTurret.tscn")

const FIELD_POSITION := 1 << 0
const FIELD_TYPE := 1 << 1
const FIELD_RELATION := 1 << 2
const REFRESH_INTERVAL_S := 1.0 / 60.0 * 30.0
const COMMAND_CENTER_TYPE_ID := "command_center"
const WORKER_TYPE_ID := "worker"
const AG_TURRET_TYPE_ID := "anti_ground_turret"
const AA_TURRET_TYPE_ID := "anti_air_turret"

var _world_query_runtime = null
var _query_session_id := ""
var _command_gateway = null
var _number_of_pending_ag_turret_resource_requests := 0
var _number_of_pending_aa_turret_resource_requests := 0
var _clear_streak := 0

@onready var _ai = get_parent()
@onready var _balance = find_parent("Match").get_node("BalanceConfigRuntime")


## 绑定己方观察与固定身份放置命令，并开始维持防御建筑数量。
func setup(world_query_runtime, query_session_id: String, command_gateway):
	_world_query_runtime = world_query_runtime
	_query_session_id = query_session_id
	_command_gateway = command_gateway
	_setup_refresh_timer()
	_enforce_number_of_ag_turrets()
	_enforce_number_of_aa_turrets()


## 使用已经获准的资源请求尝试放置对应防御建筑。
func provision(resources, metadata):
	var own_entities := _get_own_entities()
	if metadata == "ag_turret":
		assert(resources == _balance.GetConstructionCost(AGTurretScene), "unexpected resources")
		_number_of_pending_ag_turret_resource_requests -= 1
		_try_construct_turret(AG_TURRET_TYPE_ID, own_entities)
	elif metadata == "aa_turret":
		assert(resources == _balance.GetConstructionCost(AATurretScene), "unexpected resources")
		_number_of_pending_aa_turret_resource_requests -= 1
		_try_construct_turret(AA_TURRET_TYPE_ID, own_entities)
	else:
		assert(false, "unexpected flow")


func _setup_refresh_timer():
	var timer = Timer.new()
	add_child(timer)
	timer.timeout.connect(_on_refresh_timer_timeout)
	timer.start(REFRESH_INTERVAL_S)


## 根据己方查询结果补齐期望的对地炮塔数量。
func _enforce_number_of_ag_turrets():
	_enforce_structure_count(
		AG_TURRET_TYPE_ID,
		_ai.expected_number_of_ag_turrets,
		"ag_turret",
		AGTurretScene,
		"_number_of_pending_ag_turret_resource_requests"
	)


## 根据己方查询结果补齐期望的防空炮塔数量。
func _enforce_number_of_aa_turrets():
	_enforce_structure_count(
		AA_TURRET_TYPE_ID,
		_ai.expected_number_of_aa_turrets,
		"aa_turret",
		AATurretScene,
		"_number_of_pending_aa_turret_resource_requests"
	)


## 按稳定类型统计己方建筑，并为缺口提交资源请求。
func _enforce_structure_count(
	unit_type_id: String,
	expected_count: int,
	metadata: String,
	prototype: PackedScene,
	pending_property: String
):
	var own_entities := _get_own_entities()
	var current_count := own_entities.filter(
		func(entity): return entity.get("type_id", "") == unit_type_id
	).size()
	var pending_count: int = get(pending_property)
	var missing_count := expected_count - current_count - pending_count
	for _i in range(max(0, missing_count)):
		resources_required.emit(_balance.GetConstructionCost(prototype), metadata)
		pending_count += 1
	set(pending_property, pending_count)


## 围绕己方指挥中心尝试一组随机化候选位置，并提交首个合法放置。
func _try_construct_turret(unit_type_id: String, own_entities: Array):
	if not own_entities.any(func(entity): return entity.get("type_id", "") == WORKER_TYPE_ID):
		return
	var command_centers: Array = own_entities.filter(
		func(entity): return entity.get("type_id", "") == COMMAND_CENTER_TYPE_ID
	)
	if command_centers.is_empty():
		return
	var center: Vector3 = command_centers[0]["position"]
	var candidates: Array[Vector3] = []
	for radius in range(3, 18, 2):
		for sector in range(16):
			var angle := TAU * float(sector) / 16.0
			candidates.append(center + Vector3(cos(angle) * radius, 0.0, sin(angle) * radius))
	candidates.shuffle()
	var last_result: Dictionary = {}
	for position in candidates:
		last_result = _command_gateway.PlaceStructure(
			unit_type_id,
			Transform3D(Basis.IDENTITY, position)
		)
		if last_result.get("accepted", false):
			return
		if last_result.get("primary_issue", "") == "InsufficientResources":
			break
	push_warning("规则 AI 放置防御建筑被拒绝：%s" % last_result)


## 查询准确己方实体；查询失败时返回显式空集合并保留诊断。
func _get_own_entities() -> Array:
	var result: Dictionary = _world_query_runtime.GetOwnForces(
		_query_session_id,
		FIELD_POSITION | FIELD_TYPE
	)
	if result.get("status", "") != "Accepted":
		push_warning("rule AI force query was rejected: %s" % result.get("error", "Unknown"))
		return []
	return result["entities"]


func _on_refresh_timer_timeout():
	_enforce_number_of_ag_turrets()
	_enforce_number_of_aa_turrets()
	_refresh_threat_scan()


## 基地威胁扫描（AI-plan Part A Phase 5，降级版）：
## 以主 CC 为中心一次大半径扫描（而非逐建筑扫描，规避查询量随建筑数线性膨胀）。
## 发现 VisibleNow 敌人 → 上报主脑（30s 防抖）；连续 3 轮无敌人 → 解除。
func _refresh_threat_scan():
	var command_centers: Array = _get_own_entities().filter(
		func(entity): return entity.get("type_id", "") == COMMAND_CENTER_TYPE_ID
	)
	if command_centers.is_empty():
		return
	var center: Vector3 = command_centers[0]["position"]
	var result: Dictionary = _world_query_runtime.ScanCircle(
		_query_session_id,
		center,
		_ai.defense_scan_radius,
		FIELD_POSITION | FIELD_RELATION
	)
	if result.get("status", "") != "Accepted":
		return
	var enemies: Array = result.get("entities", []).filter(
		func(entity):
			return (
				entity.get("state", "") == "VisibleNow"
				and entity.get("relation", "") == "Enemy"
			)
	)
	if enemies.is_empty():
		_clear_streak += 1
		if _clear_streak >= 3:
			_ai.clear_base_threat()
			_clear_streak = 0
		return
	_clear_streak = 0
	var nearest_position: Vector3 = enemies[0]["position"]
	for enemy in enemies:
		if center.distance_squared_to(enemy["position"]) < center.distance_squared_to(
			nearest_position
		):
			nearest_position = enemy["position"]
	_ai.notify_base_threat(nearest_position)
