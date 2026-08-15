extends Node

signal resources_required(resources, metadata)

const CommandCenterScene = preload("res://source/match/units/CommandCenter.tscn")
const Worker = preload("res://source/match/units/Worker.gd")
const WorkerScene = preload("res://source/match/units/Worker.tscn")
const CollectingResourcesSequentially = preload(
	"res://source/match/units/actions/CollectingResourcesSequentially.gd"
)

const FIELD_POSITION := 1 << 0
const FIELD_TYPE := 1 << 1
const FIELD_CONSTRUCTION := 1 << 4
const FIELD_PRODUCTION := 1 << 5
const REFRESH_INTERVAL_S := 0.5
const COMMAND_CENTER_TYPE_ID := "command_center"
const WORKER_TYPE_ID := "worker"

var _player = null
var _workers = []
var _world_query_runtime = null
var _query_session_id := ""
var _command_gateway = null
var _number_of_pending_cc_resource_requests := 0
var _number_of_pending_worker_resource_requests := 0

@onready var _ai = get_parent()
@onready var _balance = find_parent("Match").get_node("BalanceConfigRuntime")


## 绑定己方观察与固定身份命令边界，并开始维护经济单位数量。
func setup(player, world_query_runtime, query_session_id: String, command_gateway):
	_player = player
	_world_query_runtime = world_query_runtime
	_query_session_id = query_session_id
	_command_gateway = command_gateway
	_attach_current_workers()
	MatchSignals.unit_spawned.connect(_on_unit_spawned)
	_setup_refresh_timer()
	_refresh_planning()


## 使用已经获准的资源请求，通过公共命令边界生产 Worker 或放置 CommandCenter。
func provision(resources, metadata):
	if metadata == "worker":
		assert(
			resources == _balance.GetProductionCost(WorkerScene),
			"unexpected amount of resources"
		)
		_number_of_pending_worker_resource_requests -= 1
		_try_produce_worker(_get_own_entities())
	elif metadata == "cc":
		assert(
			resources == _balance.GetConstructionCost(CommandCenterScene),
			"unexpected amount of resources"
		)
		_number_of_pending_cc_resource_requests -= 1
		_try_construct_cc(_get_own_entities())
	else:
		assert(false, "unexpected flow")


func _setup_refresh_timer():
	var timer = Timer.new()
	add_child(timer)
	timer.timeout.connect(_on_refresh_timer_timeout)
	timer.start(REFRESH_INTERVAL_S)


## 根据己方查询快照同时补齐 CommandCenter 与 Worker 规划，避免直接遍历建筑节点。
func _refresh_planning():
	var own_entities := _get_own_entities()
	_enforce_number_of_ccs(own_entities)
	_enforce_number_of_workers(own_entities)


## 统计己方 CommandCenter（含施工现场）并为数量缺口提交资源请求。
func _enforce_number_of_ccs(own_entities: Array):
	var current_count := own_entities.filter(
		func(entity): return entity.get("type_id", "") == COMMAND_CENTER_TYPE_ID
	).size()
	var missing_count: int = (
		_ai.expected_number_of_ccs
		- current_count
		- _number_of_pending_cc_resource_requests
	)
	for _i in range(max(0, missing_count)):
		resources_required.emit(_balance.GetConstructionCost(CommandCenterScene), "cc")
		_number_of_pending_cc_resource_requests += 1


## 统计已部署及所有生产队列中的 Worker，并为数量缺口提交资源请求。
func _enforce_number_of_workers(own_entities: Array):
	var current_count := own_entities.filter(
		func(entity): return entity.get("type_id", "") == WORKER_TYPE_ID
	).size()
	var queued_count := 0
	for entity in own_entities:
		var production = entity.get("production", null)
		if production == null:
			continue
		for item in production.get("items", []):
			if item.get("product_type_id", "") == WORKER_TYPE_ID:
				queued_count += 1
	var missing_count: int = (
		_ai.expected_number_of_workers
		- current_count
		- queued_count
		- _number_of_pending_worker_resource_requests
	)
	for _i in range(max(0, missing_count)):
		resources_required.emit(_balance.GetProductionCost(WorkerScene), "worker")
		_number_of_pending_worker_resource_requests += 1


## 选择一个已经完工的己方生产建筑，并以稳定 ID 提交 Worker 入队命令。
func _try_produce_worker(own_entities: Array):
	var producers: Array = own_entities.filter(
		func(entity):
			if entity.get("type_id", "") != COMMAND_CENTER_TYPE_ID:
				return false
			if entity.get("production", null) == null:
				return false
			var construction = entity.get("construction", null)
			return construction != null and construction.get("state", "") == "Completed"
	)
	if producers.is_empty():
		return
	var result: Dictionary = _command_gateway.EnqueueProduction(
		producers[0]["id"],
		WORKER_TYPE_ID
	)
	if not result.get("accepted", false):
		push_warning("规则 AI 生产 Worker 被拒绝：%s" % result)


## 围绕己方 CommandCenter（失去全部基地时改用 Worker）尝试放置新 CommandCenter。
func _try_construct_cc(own_entities: Array):
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
			COMMAND_CENTER_TYPE_ID,
			Transform3D(Basis.IDENTITY, position)
		)
		if last_result.get("accepted", false):
			return
		if last_result.get("primary_issue", "") == "InsufficientResources":
			break
	push_warning("规则 AI 放置 CommandCenter 被拒绝：%s" % last_result)


## 查询准确己方实体以及生产、施工状态；失败时返回显式空集合。
func _get_own_entities() -> Array:
	var result: Dictionary = _world_query_runtime.GetOwnForces(
		_query_session_id,
		FIELD_POSITION | FIELD_TYPE | FIELD_CONSTRUCTION | FIELD_PRODUCTION
	)
	if result.get("status", "") != "Accepted":
		push_warning("rule AI force query was rejected: %s" % result.get("error", "Unknown"))
		return []
	return result["entities"]


func _attach_worker(worker):
	if worker in _workers:
		return
	_workers.append(worker)
	worker.tree_exited.connect(_on_worker_died.bind(worker))
	worker.action_changed.connect(_on_worker_action_changed.bind(worker))
	if worker.action != null:
		return
	_make_worker_collecting_resources(worker)


func _attach_current_workers():
	var workers = get_tree().get_nodes_in_group("units").filter(
		func(unit): return unit is Worker and unit.player == _player
	)
	for worker in workers:
		_attach_worker(worker)


func _calculate_resource_collecting_statistics():
	var number_of_workers_per_resource_kind = {
		"resource_a": 0,
		"resource_b": 0,
	}
	for worker in _workers:
		if worker.action != null and worker.action is CollectingResourcesSequentially:
			var resource_unit = worker.action.get_resource_unit()
			if resource_unit == null:
				continue
			if "resource_a" in resource_unit:
				number_of_workers_per_resource_kind["resource_a"] += 1
			elif "resource_b" in resource_unit:
				number_of_workers_per_resource_kind["resource_b"] += 1
			else:
				assert(false, "unexpected flow")
	return number_of_workers_per_resource_kind


func _make_worker_collecting_resources(worker):
	var number_of_workers_per_resource_kind = _calculate_resource_collecting_statistics()
	var resource_filter = null
	if (
		number_of_workers_per_resource_kind["resource_a"] != 0
		or number_of_workers_per_resource_kind["resource_b"] != 0
	):
		if (
			number_of_workers_per_resource_kind["resource_a"]
			<= number_of_workers_per_resource_kind["resource_b"]
		):
			resource_filter = func(resource_unit): return "resource_a" in resource_unit
		else:
			resource_filter = func(resource_unit): return "resource_b" in resource_unit
	var closest_resource_unit = (
		Utils
		. Match
		. Resources
		. find_resource_unit_closest_to_unit_yet_no_further_than(
			worker, Constants.Match.Units.NEW_RESOURCE_SEARCH_RADIUS_M, resource_filter
		)
	)
	if closest_resource_unit != null:
		worker.action = CollectingResourcesSequentially.new(closest_resource_unit)


func _retarget_workers_if_necessary():
	var number_of_workers_per_resource_kind = _calculate_resource_collecting_statistics()
	if (
		abs(
			(
				number_of_workers_per_resource_kind["resource_a"]
				- number_of_workers_per_resource_kind["resource_b"]
			)
		)
		>= 2
	):
		for worker in _workers:
			_make_worker_collecting_resources(worker)


func _on_worker_died(worker):
	if not is_inside_tree():
		return
	_workers.erase(worker)
	_retarget_workers_if_necessary()


func _on_unit_spawned(unit):
	if unit.player != _player:
		return
	if unit is Worker:
		_attach_worker(unit)


func _on_worker_action_changed(new_action, worker):
	if new_action != null:
		return
	_make_worker_collecting_resources(worker)


func _on_refresh_timer_timeout():
	_refresh_planning()
