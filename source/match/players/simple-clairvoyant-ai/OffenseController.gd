extends Node

signal resources_required(resources, metadata)

const VehicleFactoryScene = preload("res://source/match/units/VehicleFactory.tscn")
const Tank = preload("res://source/match/units/Tank.gd")
const TankScene = preload("res://source/match/units/Tank.tscn")
const AircraftFactoryScene = preload("res://source/match/units/AircraftFactory.tscn")
const Helicopter = preload("res://source/match/units/Helicopter.gd")
const HelicopterScene = preload("res://source/match/units/Helicopter.tscn")
const AutoAttackingBattlegroup = preload(
	"res://source/match/players/simple-clairvoyant-ai/AutoAttackingBattlegroup.gd"
)

const FIELD_POSITION := 1 << 0
const FIELD_TYPE := 1 << 1
const FIELD_CONSTRUCTION := 1 << 4
const FIELD_PRODUCTION := 1 << 5
const REFRESH_INTERVAL_S := 0.5
const COMMAND_CENTER_TYPE_ID := "command_center"
const WORKER_TYPE_ID := "worker"
const VEHICLE_FACTORY_TYPE_ID := "vehicle_factory"
const AIRCRAFT_FACTORY_TYPE_ID := "aircraft_factory"
const TANK_TYPE_ID := "tank"
const HELICOPTER_TYPE_ID := "helicopter"

var _player = null
var _world_query_runtime = null
var _query_session_id := ""
var _command_gateway = null
var _primary_structure_scene: PackedScene = null
var _secondary_structure_scene: PackedScene = null
var _primary_structure_type_id := ""
var _secondary_structure_type_id := ""
var _number_of_pending_structure_resource_requests := {}
var _primary_unit_scene: PackedScene = null
var _secondary_unit_scene: PackedScene = null
var _primary_unit_type_id := ""
var _secondary_unit_type_id := ""
var _number_of_pending_unit_resource_requests := {}
var _secondary_production_enabled := false
var _battlegroup_under_forming = null
var _battlegroups := []

@onready var _ai = get_parent()
@onready var _balance = find_parent("Match").get_node("BalanceConfigRuntime")


## 绑定公共查询与固定身份命令边界，并保留 Legacy Battlegroup 作为后续迁移边界。
func setup(player, world_query_runtime, query_session_id: String, command_gateway):
	_player = player
	_world_query_runtime = world_query_runtime
	_query_session_id = query_session_id
	_command_gateway = command_gateway
	_configure_primary_and_secondary_types()
	_setup_refresh_timer()
	_try_creating_new_battlegroup()
	_attach_current_battle_units()
	MatchSignals.unit_spawned.connect(_on_unit_spawned)
	_refresh_logistics()


## 使用已经获准的资源请求放置生产建筑或向对应完工建筑提交生产入队。
func provision(resources, metadata):
	var own_entities := _get_own_entities()
	if metadata == "primary_structure":
		_provision_structure(
			_primary_structure_type_id,
			_primary_structure_scene,
			resources,
			metadata,
			own_entities
		)
	elif metadata == "secondary_structure":
		_provision_structure(
			_secondary_structure_type_id,
			_secondary_structure_scene,
			resources,
			metadata,
			own_entities
		)
	elif metadata == "primary_unit":
		_provision_unit(
			_primary_unit_type_id,
			_primary_structure_type_id,
			_primary_unit_scene,
			resources,
			metadata,
			own_entities
		)
	elif metadata == "secondary_unit":
		_provision_unit(
			_secondary_unit_type_id,
			_secondary_structure_type_id,
			_secondary_unit_scene,
			resources,
			metadata,
			own_entities
		)
	else:
		assert(false, "unexpected flow")


func _configure_primary_and_secondary_types():
	var primary_is_vehicle: bool = (
		_ai.primary_offensive_structure == _ai.OffensiveStructure.VEHICLE_FACTORY
	)
	var secondary_is_vehicle: bool = (
		_ai.secondary_offensive_structure == _ai.OffensiveStructure.VEHICLE_FACTORY
	)
	_primary_structure_scene = VehicleFactoryScene if primary_is_vehicle else AircraftFactoryScene
	_primary_structure_type_id = (
		VEHICLE_FACTORY_TYPE_ID if primary_is_vehicle else AIRCRAFT_FACTORY_TYPE_ID
	)
	_primary_unit_scene = TankScene if primary_is_vehicle else HelicopterScene
	_primary_unit_type_id = TANK_TYPE_ID if primary_is_vehicle else HELICOPTER_TYPE_ID
	_secondary_structure_scene = (
		VehicleFactoryScene if secondary_is_vehicle else AircraftFactoryScene
	)
	_secondary_structure_type_id = (
		VEHICLE_FACTORY_TYPE_ID if secondary_is_vehicle else AIRCRAFT_FACTORY_TYPE_ID
	)
	_secondary_unit_scene = TankScene if secondary_is_vehicle else HelicopterScene
	_secondary_unit_type_id = TANK_TYPE_ID if secondary_is_vehicle else HELICOPTER_TYPE_ID


func _setup_refresh_timer():
	var timer := Timer.new()
	add_child(timer)
	timer.timeout.connect(_on_refresh_timer_timeout)
	timer.start(REFRESH_INTERVAL_S)


## 用一次己方快照维护工厂存在性与生产队列，避免直接读取建筑 Node。
func _refresh_logistics():
	var own_entities := _get_own_entities()
	_enforce_structure_existence(
		_primary_structure_type_id,
		_primary_structure_scene,
		"primary_structure",
		own_entities
	)
	if _secondary_production_enabled:
		_enforce_structure_existence(
			_secondary_structure_type_id,
			_secondary_structure_scene,
			"secondary_structure",
			own_entities
		)
	_enforce_units_production(
		_primary_structure_type_id,
		_primary_unit_scene,
		"primary_unit",
		own_entities
	)
	if _secondary_production_enabled:
		_enforce_units_production(
			_secondary_structure_type_id,
			_secondary_unit_scene,
			"secondary_unit",
			own_entities
		)


## 消耗一项建筑资源请求，并通过稳定类型放置生产建筑。
func _provision_structure(
	structure_type_id: String,
	structure_scene: PackedScene,
	resources: Dictionary,
	metadata: String,
	own_entities: Array
):
	assert(
		resources == _balance.GetConstructionCost(structure_scene),
		"unexpected amount of resources"
	)
	_number_of_pending_structure_resource_requests[metadata] -= 1
	if own_entities.any(func(entity): return entity.get("type_id", "") == structure_type_id):
		return
	if not own_entities.any(func(entity): return entity.get("type_id", "") == WORKER_TYPE_ID):
		return
	_try_construct_structure(structure_type_id, own_entities)


## 消耗一项单位资源请求，并向对应的已完工生产建筑提交稳定 ID 入队命令。
func _provision_unit(
	unit_type_id: String,
	structure_type_id: String,
	unit_scene: PackedScene,
	resources: Dictionary,
	metadata: String,
	own_entities: Array
):
	assert(
		resources == _balance.GetProductionCost(unit_scene),
		"unexpected amount of resources"
	)
	_number_of_pending_unit_resource_requests[metadata] -= 1
	if not _is_units_production_allowed(own_entities):
		return
	var producers := _completed_producers(structure_type_id, own_entities)
	if producers.is_empty():
		return
	var result: Dictionary = _command_gateway.EnqueueProduction(
		producers[0]["id"],
		unit_type_id
	)
	if not result.get("accepted", false):
		push_warning("规则 AI 生产作战单位被拒绝：%s" % result)


## 围绕己方 CommandCenter（失去基地时改用 Worker）尝试放置生产建筑。
func _try_construct_structure(structure_type_id: String, own_entities: Array):
	var workers: Array = own_entities.filter(
		func(entity): return entity.get("type_id", "") == WORKER_TYPE_ID
	)
	if workers.is_empty():
		return
	var command_centers: Array = own_entities.filter(
		func(entity): return entity.get("type_id", "") == COMMAND_CENTER_TYPE_ID
	)
	var center: Vector3 = (
		workers[0]["position"] if command_centers.is_empty() else command_centers[0]["position"]
	)
	var candidates: Array[Vector3] = []
	for radius in range(3, 18, 2):
		for sector in range(16):
			var angle := TAU * float(sector) / 16.0
			candidates.append(center + Vector3(cos(angle) * radius, 0.0, sin(angle) * radius))
	candidates.shuffle()
	var last_result: Dictionary = {}
	for position in candidates:
		last_result = _command_gateway.PlaceStructure(
			structure_type_id,
			Transform3D(Basis.IDENTITY, position)
		)
		if last_result.get("accepted", false):
			return
		if last_result.get("primary_issue", "") == "InsufficientResources":
			break
	push_warning("规则 AI 放置生产建筑被拒绝：%s" % last_result)


## 在己方快照中确保指定生产建筑存在；施工蓝图已经计入数量。
func _enforce_structure_existence(
	structure_type_id: String,
	structure_scene: PackedScene,
	metadata: String,
	own_entities: Array
):
	var exists := own_entities.any(
		func(entity): return entity.get("type_id", "") == structure_type_id
	)
	if exists or _pending_structure_requests_for_type(structure_type_id) > 0:
		return
	_number_of_pending_structure_resource_requests[metadata] = (
		_number_of_pending_structure_resource_requests.get(metadata, 0) + 1
	)
	resources_required.emit(_balance.GetConstructionCost(structure_scene), metadata)


## 在生产仍有作战编组缺口时，为空闲的对应生产线提交一项资源请求。
func _enforce_units_production(
	structure_type_id: String,
	unit_scene: PackedScene,
	metadata: String,
	own_entities: Array
):
	if _completed_producers(structure_type_id, own_entities).is_empty():
		return
	if _number_of_pending_unit_resource_requests.get(metadata, 0) > 0:
		return
	if not _is_units_production_allowed(own_entities):
		return
	_number_of_pending_unit_resource_requests[metadata] = (
		_number_of_pending_unit_resource_requests.get(metadata, 0) + 1
	)
	resources_required.emit(_balance.GetProductionCost(unit_scene), metadata)


## 返回指定稳定类型且已经完工、具备生产观察的己方建筑。
func _completed_producers(structure_type_id: String, own_entities: Array) -> Array:
	return own_entities.filter(
		func(entity):
			if entity.get("type_id", "") != structure_type_id:
				return false
			if entity.get("production", null) == null:
				return false
			var construction = entity.get("construction", null)
			return construction != null and construction.get("state", "") == "Completed"
	)


## 统计同类型工厂尚未执行的资源请求，避免主次类型相同时重复放置。
func _pending_structure_requests_for_type(structure_type_id: String) -> int:
	var result := 0
	if _primary_structure_type_id == structure_type_id:
		result += _number_of_pending_structure_resource_requests.get("primary_structure", 0)
	if _secondary_structure_type_id == structure_type_id:
		result += _number_of_pending_structure_resource_requests.get("secondary_structure", 0)
	return result


## 以编组缺口减去全部相关队列项目和待处理资源请求，防止两座工厂重复超产。
func _is_units_production_allowed(own_entities: Array) -> bool:
	var queued_units := 0
	for entity in own_entities:
		var production = entity.get("production", null)
		if production == null:
			continue
		for item in production.get("items", []):
			if item.get("product_type_id", "") in [_primary_unit_type_id, _secondary_unit_type_id]:
				queued_units += 1
	var pending_requests := 0
	for value in _number_of_pending_unit_resource_requests.values():
		pending_requests += value
	return _number_of_additional_units_required() > queued_units + pending_requests


## 返回当前 Legacy 成军过程仍需要部署的作战单位数量。
func _number_of_additional_units_required() -> int:
	if _battlegroup_under_forming == null:
		return 0
	return (
		_ai.expected_number_of_battlegroups * _ai.expected_number_of_units_in_battlegroup
		- (_battlegroups.size() - 1) * _ai.expected_number_of_units_in_battlegroup
		- _battlegroup_under_forming.size()
	)


## 查询生产后勤所需的准确己方位置、类型、施工状态与生产队列。
func _get_own_entities() -> Array:
	var result: Dictionary = _world_query_runtime.GetOwnForces(
		_query_session_id,
		FIELD_POSITION | FIELD_TYPE | FIELD_CONSTRUCTION | FIELD_PRODUCTION
	)
	if result.get("status", "") != "Accepted":
		push_warning("rule AI offense query was rejected: %s" % result.get("error", "Unknown"))
		return []
	return result["entities"]


## 创建 Legacy 编组；敌情读取和战斗命令将在 RAI-001G 单独迁移。
func _try_creating_new_battlegroup() -> bool:
	if not _battlegroups.is_empty():
		_secondary_production_enabled = true
	if _battlegroups.size() == _ai.expected_number_of_battlegroups:
		_battlegroup_under_forming = null
		return false
	var adversary_players = get_tree().get_nodes_in_group("players").filter(
		func(player): return player != _player
	)
	adversary_players.shuffle()
	var battlegroup = AutoAttackingBattlegroup.new(
		_ai.expected_number_of_units_in_battlegroup,
		adversary_players
	)
	_battlegroups.append(battlegroup)
	battlegroup.tree_exited.connect(_on_battlegroup_died.bind(battlegroup))
	add_child(battlegroup)
	_battlegroup_under_forming = battlegroup
	return true


## 把场景中已有作战单位交给 Legacy 编组；该 Node 边界只保留到 RAI-001G。
func _attach_current_battle_units():
	var battle_units = get_tree().get_nodes_in_group("units").filter(
		func(unit): return unit.player == _player and (unit is Tank or unit is Helicopter)
	)
	for battle_unit in battle_units:
		_on_unit_spawned(battle_unit)


## 把新部署的作战单位交给当前 Legacy 编组，并触发下一轮公共生产规划。
func _on_unit_spawned(unit):
	if unit.player != _player or not (unit is Tank or unit is Helicopter):
		return
	if _battlegroup_under_forming == null:
		return
	_battlegroup_under_forming.attach_unit(unit)
	if _battlegroup_under_forming.size() == _ai.expected_number_of_units_in_battlegroup:
		_try_creating_new_battlegroup()
	_refresh_logistics()


func _on_battlegroup_died(battlegroup):
	if not is_inside_tree():
		return
	_battlegroups.erase(battlegroup)


func _on_refresh_timer_timeout():
	_refresh_logistics()
