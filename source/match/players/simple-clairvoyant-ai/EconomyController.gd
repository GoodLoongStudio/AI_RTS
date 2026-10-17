extends Node

const AiPerfStats = preload("res://source/match/players/simple-clairvoyant-ai/AiPerfStats.gd")
const AiBuildAnchors = preload("res://source/match/players/simple-clairvoyant-ai/AiBuildAnchors.gd")

signal resources_required(resources, metadata)

const CommandCenterScene = preload("res://source/match/units/CommandCenter.tscn")
const WorkerScene = preload("res://source/match/units/Worker.tscn")
const OreRefineryScene = preload("res://source/match/units/OreRefinery.tscn")
const VehicleFactoryScene = preload("res://source/match/units/VehicleFactory.tscn")

const FIELD_POSITION := 1 << 0
const FIELD_TYPE := 1 << 1
const FIELD_CONSTRUCTION := 1 << 4
const FIELD_PRODUCTION := 1 << 5
const FIELD_ORDER := 1 << 6
const REFRESH_INTERVAL_S := 0.5
const PLACEMENT_BACKOFF_MS := 8000
const COMMAND_CENTER_TYPE_ID := "command_center"
const WORKER_TYPE_ID := "worker"
## 【2026-09-28 红警2 口径】矿车（原"工人"）改由车厂生产（balance 同步），
## 主基地不再能生产它；开局也不送，车厂是唯一稳定产能入口。
const VEHICLE_FACTORY_TYPE_ID := "vehicle_factory"
## 矿场是**点火建筑**：开局不送矿车后，`OreRefinery._grant_free_miner` 完工赠的那一辆
## 是场上第一辆矿车的唯一来源（balance 里 ore_refinery 的 constructionProgressSource
## 是 "automatic"，不需要工人就能自己盖起来）。
const ORE_REFINERY_TYPE_ID := "ore_refinery"
## 统一货币（2026-09-14）：B 已从玩法移除，AI 只认 resource_a。
const RESOURCE_A_TYPE_ID := "resource_a"

## ---- 扩张选址与落点搜索（2026-09-27 缩放适配）----
## 地图 XZ ×2 之后 80m 圈在 512m 图上经常一个合格矿点都扫不到，扩到 120m。
const EXPANSION_SCAN_RADIUS_M := 120.0
## 新基地至少离任意己方基地 30m（平方距离）。
const MIN_CC_SEPARATION_SQ := 900.0
## 扩张点必须落在己方单位视野覆盖内：放置层要求整个 footprint 圆 `FullyVisible`，
## 而单位 sight 为 10~20m（2026-10-01 尺度 ×2 后）（见 balance 的 sightRangeMeters）⇒ 远处未揭示的矿点
## 周边一个合法落点都搜不到，只会刷"放置被拒绝"。
const EXPANSION_VISION_COVERAGE_M := 10.0
## 在已观测的真实矿点附近搜索；是否允许远程建造由权威放置层判定。
const SITE_SPOT_MAX_RADIUS_M := 24.0
## 贴主基地搜索时给足半径：CC footprint 半径 6m（建筑 ×3 缩放后），
## 基地周边还挤着厂/塔，环太短永远撞避让圈。
const BASE_SPOT_MAX_RADIUS_M := 48.0
## CommandCenter 走"resource"模式（与玩家侧自动落点口径一致：首环 = 半径 + 2m）。
const CC_AUTO_SPOT_MODE := "resource"

## 决策节奏倍率：由 SimpleClairvoyantAI 按"本局电脑玩家人数"注入（唯一实现见 AiCadence）。
## 默认 1.0 = 原始节奏；3 个电脑时为 2.0（0.5s → 1.0s）。
var refresh_scale := 1.0

var _world_query_runtime = null
var _query_session_id := ""
## 查询边界缺失只警告一次（开局首帧属正常竞态窗口，见 _resolve_query_runtime 注释）。
var _query_boundary_warned := false
var _command_gateway = null
var _number_of_pending_cc_resource_requests := 0
var _number_of_pending_worker_resource_requests := 0
var _number_of_pending_refinery_resource_requests := 0
var _number_of_pending_factory_resource_requests := 0
var _placement_backoff_until_ms := 0
var _assign_first_recorded := false
var _production_home_anchor := Vector3.INF

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
func provision(resources, metadata) -> String:
	if metadata == "worker":
		assert(
			resources == _balance.GetProductionCost(WorkerScene),
			"unexpected amount of resources"
		)
		_number_of_pending_worker_resource_requests -= 1
		_try_produce_worker(_get_own_entities())
		return "done"
	elif metadata == "cc":
		assert(
			resources == _balance.GetConstructionCost(CommandCenterScene),
			"unexpected amount of resources"
		)
		var own_entities := _get_own_entities()
		var outcome := _try_construct_cc(own_entities, _find_expansion_site(own_entities))
		if outcome != "pending":
			_number_of_pending_cc_resource_requests -= 1
		return outcome
	elif metadata == "refinery":
		assert(
			resources == _balance.GetConstructionCost(OreRefineryScene),
			"unexpected amount of resources"
		)
		var outcome := _try_construct_refinery(_get_own_entities())
		if outcome != "pending":
			_number_of_pending_refinery_resource_requests -= 1
		return outcome
	elif metadata == "factory":
		assert(
			resources == _balance.GetConstructionCost(VehicleFactoryScene),
			"unexpected amount of resources"
		)
		var outcome := _try_construct_factory(_get_own_entities())
		if outcome != "pending":
			_number_of_pending_factory_resource_requests -= 1
		return outcome
	else:
		assert(false, "unexpected flow")
		return "done"


func _setup_refresh_timer():
	var timer = Timer.new()
	add_child(timer)
	timer.timeout.connect(_on_refresh_timer_timeout)
	timer.start(REFRESH_INTERVAL_S * refresh_scale)


## 使用同一己方快照补齐建筑、Worker 与采集计划，避免读取 Legacy Node 状态。
func _refresh_planning():
	var perf_on := AiPerfStats.enabled()
	var own_started := Time.get_ticks_usec() if perf_on else 0
	var own_entities := _get_own_entities()
	if perf_on:
		AiPerfStats.add("economy_forces", Time.get_ticks_usec() - own_started)
	var enforce_started := Time.get_ticks_usec() if perf_on else 0
	if not _production_home_anchor.is_finite():
		_production_home_anchor = AiBuildAnchors.production_anchor(own_entities)
	_enforce_number_of_refineries(own_entities)
	_enforce_number_of_ccs(own_entities)
	_enforce_number_of_workers(own_entities)
	if perf_on:
		AiPerfStats.add("economy_enforce", Time.get_ticks_usec() - enforce_started)
	var assign_started := Time.get_ticks_usec() if perf_on else 0
	_assign_idle_workers_to_resources(own_entities)
	if perf_on:
		var assign_elapsed := Time.get_ticks_usec() - assign_started
		AiPerfStats.add("economy_assign", assign_elapsed)
		if not _assign_first_recorded:
			_assign_first_recorded = true
			AiPerfStats.add("economy_assign_first", assign_elapsed)


## 经济点火（2026-09-28 红警2 口径的补课）：场上既没有矿车、也没有生产中的矿车、
## 还没有矿场时，先要一座矿场。规则 AI 原来只有"CC + 矿车"两步，矿车改由车厂生产、
## 开局又不送之后，它就永远拿不到第一辆矿车 ⇒ 采集/车厂/生产线全部停摆
## （实测 rule-ai-economy-query、rule-ai-expansion、rule-ai-offense-logistics 同批变红）。
## 矿场是自动施工（balance: constructionProgressSource="automatic"），不需要工人；
## 完工时 `OreRefinery._grant_free_miner` 送出第一辆矿车，链条才接上。
func _enforce_number_of_refineries(own_entities: Array):
	if Time.get_ticks_msec() < _placement_backoff_until_ms:
		return
	if AiBuildAnchors.refinery_anchor(own_entities) == Vector3.INF:
		return
	if own_entities.any(func(entity):
		var site = entity.get("construction", null)
		return site != null and site.get("state", "") == "UnderConstruction"):
		return
	if _number_of_pending_refinery_resource_requests > 0:
		return
	resources_required.emit(_balance.GetConstructionCost(OreRefineryScene), "refinery")
	_number_of_pending_refinery_resource_requests += 1


## 开局点火；分基地完工后也在本地接入一座矿场。
func _try_construct_refinery(own_entities: Array) -> String:
	if Time.get_ticks_msec() < _placement_backoff_until_ms:
		return "done"
	var anchor := AiBuildAnchors.refinery_anchor(own_entities)
	if anchor == Vector3.INF:
		return "done"
	var spot := _find_legal_structure_spot(
		OreRefineryScene, anchor, BASE_SPOT_MAX_RADIUS_M
	)
	if _placement_pending():
		return "pending"
	if spot == Vector3.INF:
		# 【2026-09-30】"施工中"不是选址失败：一次只能建一个，等当前工地完工即可，
		# 不要把全局忙碌误报成"无合法落点"误导上层换点/放弃。
		_break_off_placement(
			"矿场选址未成（%s）anchor=%s" % [
				_spot_fail_reason(_last_spot_reply), str(anchor)],
			ORE_REFINERY_TYPE_ID
		)
		return "done"
	var result: Dictionary = _command_gateway.PlaceStructure(
		ORE_REFINERY_TYPE_ID, Transform3D(Basis.IDENTITY, spot)
	)
	if result.get("accepted", false):
		print("规则 AI 矿场已放置 %s" % str(spot))
		return "done"
	if result.get("primary_issue", "") == "InsufficientResources":
		return "done"
	_break_off_placement("落点 %s 放置被拒 %s" % [str(spot), str(result)], ORE_REFINERY_TYPE_ID)
	return "done"


func _has_completed_vehicle_factory(own_entities: Array) -> bool:
	for entity in own_entities:
		if entity.get("type_id", "") != VEHICLE_FACTORY_TYPE_ID:
			continue
		var construction = entity.get("construction", null)
		if construction != null and construction.get("state", "") == "Completed":
			return true
	return false


## 点火矿场（或它赠的第一辆矿车）还没出现时不建车厂，避免和矿场抢同一个施工位。
## 已有别的建筑在施工、或主基地/矿场的放置请求还排着时，这一轮也不插队。
func _request_vehicle_factory(own_entities: Array) -> void:
	if Time.get_ticks_msec() < _placement_backoff_until_ms:
		return
	if _number_of_pending_factory_resource_requests > 0:
		return
	if _number_of_pending_cc_resource_requests > 0 or _number_of_pending_refinery_resource_requests > 0:
		return
	for entity in own_entities:
		if entity.get("type_id", "") == VEHICLE_FACTORY_TYPE_ID:
			return
		var construction = entity.get("construction", null)
		if construction != null and construction.get("state", "") not in ["", "Completed"]:
			return
	var has_worker: bool = own_entities.any(
		func(entity): return entity.get("type_id", "") == WORKER_TYPE_ID
	)
	var has_refinery: bool = own_entities.any(
		func(entity):
			var construction = entity.get("construction", null)
			return entity.get("type_id", "") == ORE_REFINERY_TYPE_ID \
				and construction != null and construction.get("state", "") == "Completed"
	)
	if not has_worker and not has_refinery:
		return
	resources_required.emit(_balance.GetConstructionCost(VehicleFactoryScene), "factory")
	_number_of_pending_factory_resource_requests += 1


func _try_construct_factory(own_entities: Array) -> String:
	if Time.get_ticks_msec() < _placement_backoff_until_ms:
		return "done"
	var anchor := AiBuildAnchors.production_anchor(own_entities, _production_home_anchor)
	if anchor == Vector3.INF:
		return "done"
	var spot := _find_legal_structure_spot(
		VehicleFactoryScene, anchor, BASE_SPOT_MAX_RADIUS_M
	)
	if _placement_pending():
		return "pending"
	if spot == Vector3.INF:
		_break_off_placement(
			"车厂选址未成（%s）anchor=%s" % [
				_spot_fail_reason(_last_spot_reply), str(anchor)],
			VEHICLE_FACTORY_TYPE_ID
		)
		return "done"
	var result: Dictionary = _command_gateway.PlaceStructure(
		VEHICLE_FACTORY_TYPE_ID, Transform3D(Basis.IDENTITY, spot)
	)
	if result.get("accepted", false):
		print("规则 AI 车厂已放置 %s" % str(spot))
		return "done"
	if result.get("primary_issue", "") == "InsufficientResources":
		return "done"
	_break_off_placement("落点 %s 放置被拒 %s" % [str(spot), str(result)], VEHICLE_FACTORY_TYPE_ID)
	return "done"


## 统计没有活动订单的 Worker 数量；自动施工不以该数量作为扩张门槛。
func _count_idle_workers(own_entities: Array) -> int:
	return own_entities.filter(
		func(entity):
			return entity.get("type_id", "") == WORKER_TYPE_ID and entity.get("order", null) == null
	).size()


## 扩张逻辑（AI-plan Part A Phase 1）：
## - 无任何 CC 时无条件重建（旧口径兜底）；
## - 有 CC 时条件触发：未达上限、无待处理施工、各基地矿场已补齐、资金达标且有新矿。
## 一次只请求一座（串行扩张），规避 ConstructionWorksController 单工地短路。
func _enforce_number_of_ccs(own_entities: Array, _idle_worker_count: int = 0):
	if Time.get_ticks_msec() < _placement_backoff_until_ms:
		return
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
	if own_entities.any(func(entity):
		var site = entity.get("construction", null)
		return site != null and site.get("state", "") == "UnderConstruction"):
		return
	if not own_entities.any(func(entity): return entity.get("type_id", "") == ORE_REFINERY_TYPE_ID):
		return
	if _number_of_pending_refinery_resource_requests > 0 \
		or AiBuildAnchors.refinery_anchor(own_entities) != Vector3.INF:
		return
	if not _economy_meets_expansion_threshold():
		return
	if _find_expansion_site(own_entities) == Vector3.INF:
		return
	resources_required.emit(_balance.GetConstructionCost(CommandCenterScene), "cc")
	_number_of_pending_cc_resource_requests += 1


## 扩张门槛：只要求资源 A 达到 _ai.expansion_resource_threshold。
##
## 【统一货币 2026-09-14】原口径是"resource_a 与 resource_b 都 ≥ 门槛"（A=资金、B=电力的
## 双资源时代产物）。B 已从玩法移除（地图无 B 矿、权威观测只导出 A）⇒ 若继续 `and` B，
## 这个条件**永远不会成立、AI 永不扩张**。门槛语义不变：确认资源已稳定入账
## （不是"攒够建造费"——建造费另经 `resources_required` 请求）。
func _economy_meets_expansion_threshold() -> bool:
	var runtime: Variant = _resolve_query_runtime()
	if runtime == null:
		return false
	var result: Dictionary = runtime.GetOwnEconomy(_resolve_query_session_id())
	if result.get("status", "") != "Accepted":
		return false
	var balances: Dictionary = result.get("economy", {}).get("balances", {})
	var threshold: float = _ai.expansion_resource_threshold
	return balances.get("resource_a", 0.0) >= threshold


## 统计已部署及所有生产队列中的 Worker，并为数量缺口提交资源请求。
## 目标工人数 = 现有 CC 数（含施工现场）× workers_per_command_center。
## 矿车只能由车厂生产。没有完工车厂时不发生产请求；点火矿场还没落下之前也不抢施工位。
func _enforce_number_of_workers(own_entities: Array):
	if not _has_completed_vehicle_factory(own_entities):
		_request_vehicle_factory(own_entities)
		return
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
## 2026-09-03：按资源节点(而非仅资源类型)统计已分配人数，优先选择"人少且近"的
## 节点，避免多个工人挤同一矿点造成寻路拥塞和原地转圈。
func _assign_idle_workers_to_resources(own_entities: Array):
	var workers: Array = own_entities.filter(
		func(entity): return entity.get("type_id", "") == WORKER_TYPE_ID
	)
	workers.sort_custom(func(left, right): return left["id"] < right["id"])
	var assigned_counts_by_type := {
		RESOURCE_A_TYPE_ID: 0,
	}
	var assigned_counts_by_node := {}
	for worker in workers:
		var order = worker.get("order", null)
		if order == null or order.get("kind", "") != "Gather":
			continue
		var target = order.get("target", null)
		if target == null:
			continue
		var target_type: String = target.get("type_id", "")
		if assigned_counts_by_type.has(target_type):
			assigned_counts_by_type[target_type] += 1
		var node_id: String = target.get("entity_id", "")
		if not node_id.is_empty():
			assigned_counts_by_node[node_id] = assigned_counts_by_node.get(node_id, 0) + 1

	for worker in workers:
		if worker.get("order", null) != null:
			continue
		# 统一货币：场上只有资源 A 一种矿，原来在这里做的 A/B 均衡分配不再需要。
		var perf_on := AiPerfStats.enabled()
		var scan_started := Time.get_ticks_usec() if perf_on else 0
		var resource := _find_visible_resource(worker["position"], RESOURCE_A_TYPE_ID, assigned_counts_by_node)
		if perf_on:
			AiPerfStats.add("economy_assign_scan", Time.get_ticks_usec() - scan_started)
		if resource.is_empty():
			continue
		var gather_started := Time.get_ticks_usec() if perf_on else 0
		var result: Dictionary = _command_gateway.Gather(
			[worker["id"]],
			resource["id"]
		)
		if perf_on:
			AiPerfStats.add("economy_assign_gather", Time.get_ticks_usec() - gather_started)

		if result.get("status", "") in ["Accepted", "PartiallyAccepted"]:
			assigned_counts_by_type[resource["type_id"]] += 1
			assigned_counts_by_node[resource["id"]] = assigned_counts_by_node.get(resource["id"], 0) + 1
		else:
			push_warning("规则 AI Gather 被拒绝：%s" % result)


## 在 Worker 当前视野与搜索半径交集中选择资源；先选当前分配人数最少的节点，
## 同等拥挤度时取最近，尽量把工人摊开到不同矿点。
func _find_visible_resource(
	worker_position: Vector3, preferred_type: String, assigned_counts_by_node: Dictionary = {}
) -> Dictionary:
	var runtime: Variant = _resolve_query_runtime()
	if runtime == null:
		return {}
	var perf_on := AiPerfStats.enabled()
	var api_started := Time.get_ticks_usec() if perf_on else 0
	var result: Dictionary = runtime.ScanCircle(
		_resolve_query_session_id(),
		worker_position,
		Constants.Match.Units.NEW_RESOURCE_SEARCH_RADIUS_M,
		FIELD_POSITION | FIELD_TYPE
	)
	if perf_on:
		AiPerfStats.add("economy_scan_api", Time.get_ticks_usec() - api_started)
	if result.get("status", "") != "Accepted":
		push_warning("rule AI resource query was rejected: %s" % result.get("error", "Unknown"))
		return {}
	var sort_started := Time.get_ticks_usec() if perf_on else 0
	var resources: Array = result["entities"].filter(
		func(entity): return entity.get("type_id", "") == RESOURCE_A_TYPE_ID
	)
	if resources.is_empty():
		if perf_on:
			AiPerfStats.add("economy_scan_sort", Time.get_ticks_usec() - sort_started)
		return {}
	var preferred: Array = resources.filter(
		func(entity): return entity.get("type_id", "") == preferred_type
	)
	var candidates: Array = preferred if not preferred.is_empty() else resources
	candidates.sort_custom(
		func(left, right):
			var left_count: int = assigned_counts_by_node.get(left["id"], 0)
			var right_count: int = assigned_counts_by_node.get(right["id"], 0)
			if left_count != right_count:
				return left_count < right_count
			return worker_position.distance_squared_to(left["position"]) < (
				worker_position.distance_squared_to(right["position"])
			)
	)
	if perf_on:
		AiPerfStats.add("economy_scan_sort", Time.get_ticks_usec() - sort_started)
	return candidates[0]


## 选择一个已经完工的己方生产建筑，并以稳定 ID 提交 Worker 入队命令。
func _try_produce_worker(own_entities: Array):
	var producers: Array = own_entities.filter(
		func(entity):
			if entity.get("type_id", "") != VEHICLE_FACTORY_TYPE_ID:
				return false
			if entity.get("production", null) == null:
				return false
			var construction = entity.get("construction", null)
			return construction != null and construction.get("state", "") == "Completed"
	)
	if producers.is_empty():
		return
	# 队列里已经在产矿车就不再下单：权威端回 QueueFull，而旧实现每轮都重发一遍
	# （实测 rule-ai-offense-logistics 一轮里连刷 6 条被拒命令，白占命令边界与日志）。
	var queue = producers[0].get("production", null)
	if queue != null:
		for item in queue.get("items", []):
			if item.get("product_type_id", "") == WORKER_TYPE_ID:
				return
	var result: Dictionary = _command_gateway.EnqueueProduction(
		producers[0]["id"],
		WORKER_TYPE_ID
	)
	if not result.get("accepted", false):
		print("规则 AI 生产 Worker 被拒绝：%s" % result)


## 围绕指定中心（扩张=选定的远处资源簇；重建=残余 Worker）尝试放置新 CommandCenter。
##
## 【2026-09-27 缩放适配】旧实现自己在 center 周围铺 3~17m 的环、再 `shuffle()` 后只探
## 8 个点：建筑 ×3（CC footprint 半径 6m）+ 地图 ×2 之后，这些环全落在己方建筑避让圈里，
## 放置必被拒（issues=NotVisible/OutOfBounds/SurfaceNotBuildable）。
## 现在调用共用 FindAutoSpot：有预算的几何评分、通道保护和权威复验。
## 有基地时只去新矿扩张；无基地时才允许从残余 Worker 附近重建。
func _try_construct_cc(own_entities: Array, preferred_center: Vector3 = Vector3.INF) -> String:
	if Time.get_ticks_msec() < _placement_backoff_until_ms:
		return "done"
	var workers: Array = own_entities.filter(
		func(entity): return entity.get("type_id", "") == WORKER_TYPE_ID
	)
	var command_centers: Array = own_entities.filter(
		func(entity): return entity.get("type_id", "") == COMMAND_CENTER_TYPE_ID
	)
	# 扩张使用新矿锚点；残余 Worker 仅用于失去全部基地后的重建。
	var anchors: Array = []
	if preferred_center != Vector3.INF:
		anchors.append({"position": preferred_center, "max_radius": SITE_SPOT_MAX_RADIUS_M})
	var base_position: Vector3 = (
		command_centers[0]["position"] if not command_centers.is_empty()
		else (workers[0]["position"] if not workers.is_empty() else Vector3.INF)
	)
	# Existing HQ: an unavailable expansion is a wait, never a second HQ at home.
	if not command_centers.is_empty() and preferred_center == Vector3.INF:
		return "done"
	if command_centers.is_empty():
		if base_position == Vector3.INF:
			return "done"
		anchors.append({"position": base_position, "max_radius": BASE_SPOT_MAX_RADIUS_M})
	var fail_reason := "无合法落点"
	for anchor in anchors:
		var spot := _find_legal_cc_spot(anchor["position"], anchor["max_radius"])
		if _placement_pending():
			return "pending"
		if spot == Vector3.INF:
			# 全局性拒绝（施工中等）与锚点无关：换锚点结果不变，直接终局并如实上报。
			var reason := _spot_fail_reason(_last_spot_reply)
			if reason.begins_with("全局忙碌"):
				fail_reason = reason
				break
			continue
		if command_centers.any(func(center): return spot.distance_squared_to(center["position"]) < MIN_CC_SEPARATION_SQ):
			continue
		var result: Dictionary = _command_gateway.PlaceStructure(
			COMMAND_CENTER_TYPE_ID,
			Transform3D(Basis.IDENTITY, spot)
		)
		if result.get("accepted", false):
			return "done"
		# 缺钱不是选址问题：落点合法，扣款失败等下一轮，别进选址退避。
		if result.get("primary_issue", "") == "InsufficientResources":
			return "done"
		_break_off_placement("落点 %s 放置被拒 %s" % [str(spot), str(result)])
		return "done"
	_break_off_placement("分基地 %s anchors=%d" % [fail_reason, anchors.size()])
	return "done"


## 进入选址退避并留一行诊断（原来只在失败时 print 一次被拒结果）。
func _break_off_placement(reason: String, what: String = "CommandCenter") -> void:
	_placement_backoff_until_ms = Time.get_ticks_msec() + PLACEMENT_BACKOFF_MS
	print("规则 AI 放置 %s 被拒绝：%s" % [what, reason])


## 用玩家侧的自动落点搜索找一个能放 CC 的合法坐标；找不到返回 Vector3.INF。
func _find_legal_cc_spot(anchor: Vector3, max_radius_m: float) -> Vector3:
	return _find_legal_structure_spot(CommandCenterScene, anchor, max_radius_m, "resource")


## 共用自动选址入口：候选先按 footprint/通道评分，优选点再通过权威放置校验。
## resource 模式用于矿场/分基地，base 模式用于已完工基地周边的发展。
## 找到返回落点，找不到返回 Vector3.INF；原始回执（含 reason）留在 _last_spot_reply。
var _last_spot_reply: Variant = null


func _find_legal_structure_spot(prototype: PackedScene, anchor: Vector3, max_radius_m: float, mode: String = "base") -> Vector3:
	var placement := _structure_placement_runtime()
	if placement == null:
		_last_spot_reply = null
		return Vector3.INF
	var reply: Variant = placement.FindAutoSpotBudgeted(
		_ai, prototype, mode, anchor, max_radius_m, 1500
	) if placement.has_method("FindAutoSpotBudgeted") else placement.FindAutoSpot(
		_ai, prototype, mode, anchor, max_radius_m
	)
	_last_spot_reply = reply
	if not (reply is Dictionary) or not bool(reply.get("found", false)):
		return Vector3.INF
	return reply.get("pos", Vector3.INF)


## 选址失败的**准确**原因：全局性拒绝（施工中/未授权/校验不可用）不是"无合法落点"，
## 上层应等待而不是换点或放弃（2026-09-30 修"busy 被误报成无落点"）。
func _placement_pending() -> bool:
	return _last_spot_reply is Dictionary and bool(_last_spot_reply.get("pending", false))


func _spot_fail_reason(reply: Variant) -> String:
	if reply == null or not (reply is Dictionary):
		return "选址服务不可用"
	var reason := str(reply.get("reason", ""))
	if not reason.is_empty():
		return "全局忙碌 %s，等当前施工完成" % reason
	return "无合法落点"


func _structure_placement_runtime() -> Node:
	var match_node := find_parent("Match")
	if match_node == null:
		return null
	var placement: Node = match_node.get_node_or_null("StructurePlacementRuntime")
	if placement == null or not placement.has_method("FindAutoSpot"):
		return null
	return placement


## 扩张选址：以主 CC 为心扫描已观测资源，选距所有己方 CC 至少 30m 的最近新矿。
## 【2026-09-19】此前取的是**最远**的（见下方注释），与方案 3.F"不再默认最远矿点最优"冲突。
## 找不到新矿返回 Vector3.INF，等待下一轮探索，不在主基地旁造伪分基地。
func _find_expansion_site(own_entities: Array) -> Vector3:
	var command_centers: Array = own_entities.filter(
		func(entity): return entity.get("type_id", "") == COMMAND_CENTER_TYPE_ID
	)
	if command_centers.is_empty():
		return Vector3.INF
	var primary_position: Vector3 = command_centers[0]["position"]
	var runtime: Variant = _resolve_query_runtime()
	if runtime == null:
		return Vector3.INF
	var result: Dictionary = runtime.ScanCircle(
		_resolve_query_session_id(),
		primary_position,
		EXPANSION_SCAN_RADIUS_M,
		FIELD_POSITION | FIELD_TYPE
	)
	if result.get("status", "") != "Accepted":
		return Vector3.INF
	var best_position := Vector3.INF
	var best_distance := INF  # Separation is a lower bound, not the best-distance upper bound.
	for entity in result.get("entities", []):
		if entity.get("type_id", "") != RESOURCE_A_TYPE_ID:
			continue
		var position: Vector3 = entity["position"]
		var too_close := false
		for center in command_centers:
			if position.distance_squared_to(center["position"]) < MIN_CC_SEPARATION_SQ:
				too_close = true
				break
		if too_close:
			continue
		# ScanCircle already enforces this player's observation policy. Remote CC
		# does not require a worker standing within a stale fixed 10m proxy.
		# 【2026-09-19 修确定缺陷】原实现用 `distance > best_distance` ⇒ **专挑最远**的
		# 资源簇当分矿：跑得最久、最容易被截、工人往返最费的定位反而被优先选中
		# （方案第 1 节："扩张偏远…"；方案 3.F："不再默认最远矿点最优"）。
		# 最小间距单独检查，best_distance 从 INF 开始取最近新矿。
		# 路程短 ⇒ 回收期短、防御链短、工人往返少。过近点已被上面的 too_close 排除。
		var distance := position.distance_squared_to(primary_position)
		if distance < best_distance:
			best_distance = distance
			best_position = position
	return best_position


## 该坐标是否落在某个己方实体的视野覆盖内（放置层要求整个 footprint 圆可见）。
func _covered_by_own_vision(target: Vector3, own_entities: Array) -> bool:
	var limit_sq := EXPANSION_VISION_COVERAGE_M * EXPANSION_VISION_COVERAGE_M
	for entity in own_entities:
		var position = entity.get("position", null)
		if position is Vector3 and target.distance_squared_to(position) <= limit_sq:
			return true
	return false


## 查询准确己方实体以及生产、施工和活动订单；失败时返回显式空集合。
func _get_own_entities() -> Array:
	# round-01：同帧去重 —— 真实对局里父节点是 SimpleClairvoyantAI，走它的按物理帧
	# 缓存；独立实例化（无 AI 父节点）的单元测试保持原直查路径。
	if _ai != null and _ai.has_method("own_forces_scan"):
		return _ai.own_forces_scan()
	var runtime: Variant = _resolve_query_runtime()
	if runtime == null:
		_warn_once_query_boundary_missing()
		return []
	var result: Dictionary = runtime.GetOwnForces(
		_resolve_query_session_id(),
		FIELD_POSITION | FIELD_TYPE | FIELD_CONSTRUCTION | FIELD_PRODUCTION | FIELD_ORDER
	)
	if result.get("status", "") != "Accepted":
		push_warning("rule AI force query was rejected: %s" % result.get("error", "Unknown"))
		return []
	return result["entities"]


## 观察快照运行时/会话 ID 是 AI 在自身 `_ready` 之后才注入的，而
## `SimpleClairvoyantAI.gd:142` 把**当时仍为 null** 的引用缓存进了本控制器 ⇒
## 首个刷新周期 `GetOwnForces` 会在 Nil 上调用（套件日志里的
## "Nonexistent function 'GetOwnForces' in base 'Nil'"），己方快照变空，
## `_enforce_number_of_ccs` 误判"一座 CC 都没有"走无条件重建分支
## —— rule-ai-expansion 两条门控随开局时序 flaky 的真因（第二轮任务 C）。
## 这里惰性回源到 AI 的当前值并重新缓存，不吞错误（缺边界时警告一次）。
func _resolve_query_runtime():
	if _world_query_runtime != null:
		return _world_query_runtime
	var current: Variant = _ai.get("_world_query_runtime") if _ai != null else null
	if current != null:
		_world_query_runtime = current
	return current


func _resolve_query_session_id() -> String:
	if _query_session_id != "":
		return _query_session_id
	var current: Variant = _ai.get("_query_session_id") if _ai != null else null
	if current != null and String(current) != "":
		_query_session_id = String(current)
	return _query_session_id


func _warn_once_query_boundary_missing() -> void:
	if _query_boundary_warned:
		return
	_query_boundary_warned = true
	push_warning("规则 AI 经济控制器：查询边界（world_query_runtime）尚未注入，本周期跳过规划")


func _on_refresh_timer_timeout():
	var _perf_start := Time.get_ticks_usec()
	_refresh_planning()
	if AiPerfStats.enabled():
		AiPerfStats.add("economy", Time.get_ticks_usec() - _perf_start)
