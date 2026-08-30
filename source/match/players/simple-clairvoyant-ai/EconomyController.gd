extends Node

signal resources_required(resources, metadata)

const CommandCenterScene = preload("res://source/match/units/CommandCenter.tscn")
const WorkerScene = preload("res://source/match/units/Worker.tscn")

const FIELD_POSITION := 1 << 0
const FIELD_TYPE := 1 << 1
const FIELD_CONSTRUCTION := 1 << 4
const FIELD_PRODUCTION := 1 << 5
const FIELD_ORDER := 1 << 6
const REFRESH_INTERVAL_S := 0.5
const COMMAND_CENTER_TYPE_ID := "command_center"
const WORKER_TYPE_ID := "worker"
const RESOURCE_A_TYPE_ID := "resource_a"
const RESOURCE_B_TYPE_ID := "resource_b"

var _world_query_runtime = null
var _query_session_id := ""
var _command_gateway = null
var _number_of_pending_cc_resource_requests := 0
var _number_of_pending_worker_resource_requests := 0

@onready var _ai = get_parent()
@onready var _balance = find_parent("Match").get_node("BalanceConfigRuntime")


## 绑定己方观察与固定身份命令边界，并开始维护经济单位和采集任务。
func setup(world_query_runtime, query_session_id: String, command_gateway):
	_world_query_runtime = world_query_runtime
	_query_session_id = query_session_id
	_command_gateway = command_gateway
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
		var own_entities := _get_own_entities()
		_try_construct_cc(own_entities, _find_expansion_site(own_entities))
	else:
		assert(false, "unexpected flow")


func _setup_refresh_timer():
	var timer = Timer.new()
	add_child(timer)
	timer.timeout.connect(_on_refresh_timer_timeout)
	timer.start(REFRESH_INTERVAL_S)


## 使用同一己方快照补齐建筑、Worker 与采集计划，避免读取 Legacy Node 状态。
func _refresh_planning():
	var own_entities := _get_own_entities()
	var idle_workers := _count_idle_workers(own_entities)
	_enforce_number_of_ccs(own_entities, idle_workers)
	_enforce_number_of_workers(own_entities)
	_assign_idle_workers_to_resources(own_entities)


## 统计没有活动订单的 Worker 数量（扩张门槛用：全部在岗才允许开分矿）。
func _count_idle_workers(own_entities: Array) -> int:
	return own_entities.filter(
		func(entity):
			return entity.get("type_id", "") == WORKER_TYPE_ID and entity.get("order", null) == null
	).size()


## 扩张逻辑（AI-plan Part A Phase 1）：
## - 无任何 CC 时无条件重建（旧口径兜底）；
## - 有 CC 时条件触发：未达上限 + 无待处理扩张请求 + 工人全部在岗 + 双资源余额过门槛。
## 一次只请求一座（串行扩张），规避 ConstructionWorksController 单工地短路。
func _enforce_number_of_ccs(own_entities: Array, idle_worker_count: int):
	var current_count := own_entities.filter(
		func(entity): return entity.get("type_id", "") == COMMAND_CENTER_TYPE_ID
	).size()
	if current_count == 0:
		if _number_of_pending_cc_resource_requests <= 0:
			resources_required.emit(_balance.GetConstructionCost(CommandCenterScene), "cc")
			_number_of_pending_cc_resource_requests += 1
		return
	if current_count >= _ai.max_command_centers:
		return
	if _number_of_pending_cc_resource_requests > 0:
		return
	if idle_worker_count > 0:
		return
	if not _economy_meets_expansion_threshold():
		return
	resources_required.emit(_balance.GetConstructionCost(CommandCenterScene), "cc")
	_number_of_pending_cc_resource_requests += 1


## 双资源余额均达到扩张门槛才允许开分矿。
func _economy_meets_expansion_threshold() -> bool:
	var result: Dictionary = _world_query_runtime.GetOwnEconomy(_query_session_id)
	if result.get("status", "") != "Accepted":
		return false
	var balances: Dictionary = result.get("economy", {}).get("balances", {})
	var threshold: float = _ai.expansion_resource_threshold
	return (
		balances.get("resource_a", 0.0) >= threshold
		and balances.get("resource_b", 0.0) >= threshold
	)


## 统计已部署及所有生产队列中的 Worker，并为数量缺口提交资源请求。
## 目标工人数 = 现有 CC 数（含施工现场）× workers_per_command_center。
func _enforce_number_of_workers(own_entities: Array):
	var current_count := own_entities.filter(
		func(entity): return entity.get("type_id", "") == WORKER_TYPE_ID
	).size()
	var command_center_count := own_entities.filter(
		func(entity): return entity.get("type_id", "") == COMMAND_CENTER_TYPE_ID
	).size()
	var worker_target: int = command_center_count * _ai.workers_per_command_center
	var queued_count := 0
	for entity in own_entities:
		var production = entity.get("production", null)
		if production == null:
			continue
		for item in production.get("items", []):
			if item.get("product_type_id", "") == WORKER_TYPE_ID:
				queued_count += 1
	var missing_count: int = (
		worker_target
		- current_count
		- queued_count
		- _number_of_pending_worker_resource_requests
	)
	for _i in range(max(0, missing_count)):
		resources_required.emit(_balance.GetProductionCost(WorkerScene), "worker")
		_number_of_pending_worker_resource_requests += 1


## 为没有活动订单的 Worker 选择视野内资源；暂停或施工订单不会被自动覆盖。
func _assign_idle_workers_to_resources(own_entities: Array):
	var workers: Array = own_entities.filter(
		func(entity): return entity.get("type_id", "") == WORKER_TYPE_ID
	)
	workers.sort_custom(func(left, right): return left["id"] < right["id"])
	var assigned_counts := {
		RESOURCE_A_TYPE_ID: 0,
		RESOURCE_B_TYPE_ID: 0,
	}
	for worker in workers:
		var order = worker.get("order", null)
		if order == null or order.get("kind", "") != "Gather":
			continue
		var target = order.get("target", null)
		if target == null:
			continue
		var target_type: String = target.get("type_id", "")
		if assigned_counts.has(target_type):
			assigned_counts[target_type] += 1
	for worker in workers:
		if worker.get("order", null) != null:
			continue
		var preferred_type := (
			RESOURCE_A_TYPE_ID
			if assigned_counts[RESOURCE_A_TYPE_ID] <= assigned_counts[RESOURCE_B_TYPE_ID]
			else RESOURCE_B_TYPE_ID
		)
		var resource := _find_visible_resource(worker["position"], preferred_type)
		if resource.is_empty():
			continue
		var result: Dictionary = _command_gateway.Gather(
			[worker["id"]],
			resource["id"]
		)
		if result.get("status", "") in ["Accepted", "PartiallyAccepted"]:
			assigned_counts[resource["type_id"]] += 1
		else:
			push_warning("规则 AI Gather 被拒绝：%s" % result)


## 在 Worker 当前视野与搜索半径交集中选择最近资源，优先保持两种资源分工平衡。
func _find_visible_resource(worker_position: Vector3, preferred_type: String) -> Dictionary:
	var result: Dictionary = _world_query_runtime.ScanCircle(
		_query_session_id,
		worker_position,
		Constants.Match.Units.NEW_RESOURCE_SEARCH_RADIUS_M,
		FIELD_POSITION | FIELD_TYPE
	)
	if result.get("status", "") != "Accepted":
		push_warning("rule AI resource query was rejected: %s" % result.get("error", "Unknown"))
		return {}
	var resources: Array = result["entities"].filter(
		func(entity):
			return entity.get("type_id", "") in [RESOURCE_A_TYPE_ID, RESOURCE_B_TYPE_ID]
	)
	if resources.is_empty():
		return {}
	var preferred: Array = resources.filter(
		func(entity): return entity.get("type_id", "") == preferred_type
	)
	var candidates: Array = preferred if not preferred.is_empty() else resources
	candidates.sort_custom(
		func(left, right):
			return worker_position.distance_squared_to(left["position"]) < (
				worker_position.distance_squared_to(right["position"])
			)
	)
	return candidates[0]


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


## 围绕指定中心（扩张=选定的远处资源簇；重建=残余 Worker）尝试放置新 CommandCenter。
func _try_construct_cc(own_entities: Array, preferred_center: Vector3 = Vector3.INF):
	var workers: Array = own_entities.filter(
		func(entity): return entity.get("type_id", "") == WORKER_TYPE_ID
	)
	if workers.is_empty():
		return
	var command_centers: Array = own_entities.filter(
		func(entity): return entity.get("type_id", "") == COMMAND_CENTER_TYPE_ID
	)
	var center: Vector3
	if preferred_center != Vector3.INF:
		center = preferred_center
	elif command_centers.is_empty():
		center = workers[0]["position"]
	else:
		center = command_centers[0]["position"]
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


## 扩张选址：以主 CC 为心做大半径扫描，取「距所有己方 CC 至少 20m」中最远的资源簇位置。
## 找不到合适资源时返回 Vector3.INF（本轮放弃扩张）。
func _find_expansion_site(own_entities: Array) -> Vector3:
	var command_centers: Array = own_entities.filter(
		func(entity): return entity.get("type_id", "") == COMMAND_CENTER_TYPE_ID
	)
	if command_centers.is_empty():
		return Vector3.INF
	var primary_position: Vector3 = command_centers[0]["position"]
	var result: Dictionary = _world_query_runtime.ScanCircle(
		_query_session_id,
		primary_position,
		80.0,
		FIELD_POSITION | FIELD_TYPE
	)
	if result.get("status", "") != "Accepted":
		return Vector3.INF
	var best_position := Vector3.INF
	var best_distance := 400.0  # 20m 平方下限：新基地必须与现有基地保持距离
	for entity in result.get("entities", []):
		if entity.get("type_id", "") not in [RESOURCE_A_TYPE_ID, RESOURCE_B_TYPE_ID]:
			continue
		var position: Vector3 = entity["position"]
		var too_close := false
		for center in command_centers:
			if position.distance_squared_to(center["position"]) < 400.0:
				too_close = true
				break
		if too_close:
			continue
		var distance := position.distance_squared_to(primary_position)
		if distance > best_distance:
			best_distance = distance
			best_position = position
	return best_position


## 查询准确己方实体以及生产、施工和活动订单；失败时返回显式空集合。
func _get_own_entities() -> Array:
	var result: Dictionary = _world_query_runtime.GetOwnForces(
		_query_session_id,
		FIELD_POSITION | FIELD_TYPE | FIELD_CONSTRUCTION | FIELD_PRODUCTION | FIELD_ORDER
	)
	if result.get("status", "") != "Accepted":
		push_warning("rule AI force query was rejected: %s" % result.get("error", "Unknown"))
		return []
	return result["entities"]


func _on_refresh_timer_timeout():
	_refresh_planning()
