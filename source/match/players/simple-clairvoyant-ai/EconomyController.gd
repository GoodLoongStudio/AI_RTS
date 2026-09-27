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
const PLACEMENT_BACKOFF_MS := 8000
const COMMAND_CENTER_TYPE_ID := "command_center"
const WORKER_TYPE_ID := "worker"
## 统一货币（2026-09-14）：B 已从玩法移除，AI 只认 resource_a。
const RESOURCE_A_TYPE_ID := "resource_a"

## ---- 扩张选址与落点搜索（2026-09-27 缩放适配）----
## 地图 XZ ×2 之后 80m 圈在 512m 图上经常一个合格矿点都扫不到，扩到 120m。
const EXPANSION_SCAN_RADIUS_M := 120.0
## 新基地必须与现有基地保持的平安距离（20m 的平方）。
const MIN_CC_SEPARATION_SQ := 400.0
## 扩张点必须落在己方单位视野覆盖内：放置层要求整个 footprint 圆 `FullyVisible`，
## 而单位 sight 只有 5~10m（见 balance 的 sightRangeMeters）⇒ 远处未揭示的矿点
## 周边一个合法落点都搜不到，只会刷"放置被拒绝"。
const EXPANSION_VISION_COVERAGE_M := 10.0
## 远处扩张点只在工人视野内做螺旋搜索（外扩太多整环落到视野外 = NotVisible）。
const SITE_SPOT_MAX_RADIUS_M := 14.0
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
var _placement_backoff_until_ms := 0

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
	timer.start(REFRESH_INTERVAL_S * refresh_scale)


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
	if idle_worker_count > 0:
		return
	if not _economy_meets_expansion_threshold():
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
		var resource := _find_visible_resource(worker["position"], RESOURCE_A_TYPE_ID, assigned_counts_by_node)
		if resource.is_empty():
			continue
		var result: Dictionary = _command_gateway.Gather(
			[worker["id"]],
			resource["id"]
		)

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
	var result: Dictionary = runtime.ScanCircle(
		_resolve_query_session_id(),
		worker_position,
		Constants.Match.Units.NEW_RESOURCE_SEARCH_RADIUS_M,
		FIELD_POSITION | FIELD_TYPE
	)
	if result.get("status", "") != "Accepted":
		push_warning("rule AI resource query was rejected: %s" % result.get("error", "Unknown"))
		return {}
	var resources: Array = result["entities"].filter(
		func(entity): return entity.get("type_id", "") == RESOURCE_A_TYPE_ID
	)
	if resources.is_empty():
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
		print("规则 AI 生产 Worker 被拒绝：%s" % result)


## 围绕指定中心（扩张=选定的远处资源簇；重建=残余 Worker）尝试放置新 CommandCenter。
##
## 【2026-09-27 缩放适配】旧实现自己在 center 周围铺 3~17m 的环、再 `shuffle()` 后只探
## 8 个点：建筑 ×3（CC footprint 半径 6m）+ 地图 ×2 之后，这些环全落在己方建筑避让圈里，
## 放置必被拒（issues=NotVisible/OutOfBounds/SurfaceNotBuildable）。
## 现在改用玩家侧同一套 footprint 感知的螺旋搜索（`FindAutoSpot`：首环 = 半径+2m、
## 逐环外扩 2m、黄金角错开、每个候选都过权威放置校验），并按
## "远处扩张点 → 主 CC → 残余 Worker" 的顺序回退重试。
func _try_construct_cc(own_entities: Array, preferred_center: Vector3 = Vector3.INF):
	if Time.get_ticks_msec() < _placement_backoff_until_ms:
		return
	var workers: Array = own_entities.filter(
		func(entity): return entity.get("type_id", "") == WORKER_TYPE_ID
	)
	if workers.is_empty():
		return
	var command_centers: Array = own_entities.filter(
		func(entity): return entity.get("type_id", "") == COMMAND_CENTER_TYPE_ID
	)
	# 回退链：扩张点（有工人视野覆盖才给）→ 主 CC → 残余 Worker。
	var anchors: Array = []
	if preferred_center != Vector3.INF:
		anchors.append({"position": preferred_center, "max_radius": SITE_SPOT_MAX_RADIUS_M})
	var base_position: Vector3 = (
		command_centers[0]["position"] if not command_centers.is_empty()
		else workers[0]["position"]
	)
	anchors.append({"position": base_position, "max_radius": BASE_SPOT_MAX_RADIUS_M})
	if command_centers.is_empty():
		anchors.append({"position": workers[0]["position"], "max_radius": BASE_SPOT_MAX_RADIUS_M})
	for anchor in anchors:
		var spot := _find_legal_cc_spot(anchor["position"], anchor["max_radius"])
		if spot == Vector3.INF:
			continue
		var result: Dictionary = _command_gateway.PlaceStructure(
			COMMAND_CENTER_TYPE_ID,
			Transform3D(Basis.IDENTITY, spot)
		)
		if result.get("accepted", false):
			return
		# 缺钱不是选址问题：落点合法，扣款失败等下一轮，别进选址退避。
		if result.get("primary_issue", "") == "InsufficientResources":
			return
		_break_off_placement("落点 %s 放置被拒 %s" % [str(spot), str(result)])
		return
	_break_off_placement("无合法落点 anchors=%d" % anchors.size())


## 进入选址退避并留一行诊断（原来只在失败时 print 一次被拒结果）。
func _break_off_placement(reason: String) -> void:
	_placement_backoff_until_ms = Time.get_ticks_msec() + PLACEMENT_BACKOFF_MS
	print("规则 AI 放置 CommandCenter 被拒绝：%s" % reason)


## 用玩家侧的自动落点搜索找一个能放 CC 的合法坐标；找不到返回 Vector3.INF。
func _find_legal_cc_spot(anchor: Vector3, max_radius_m: float) -> Vector3:
	var placement := _structure_placement_runtime()
	if placement == null:
		return Vector3.INF
	var reply: Variant = placement.FindAutoSpot(
		_ai, CommandCenterScene, CC_AUTO_SPOT_MODE, anchor, max_radius_m
	)
	if not (reply is Dictionary) or not bool(reply.get("found", false)):
		return Vector3.INF
	return reply.get("pos", Vector3.INF)


func _structure_placement_runtime() -> Node:
	var match_node := find_parent("Match")
	if match_node == null:
		return null
	var placement: Node = match_node.get_node_or_null("StructurePlacementRuntime")
	if placement == null or not placement.has_method("FindAutoSpot"):
		return null
	return placement


## 扩张选址：以主 CC 为心做大半径扫描，取「距所有己方 CC 至少 20m、且落在己方单位
## 视野覆盖内（否则放置层整圈 NotVisible）」中**最近**的资源簇位置。
## 【2026-09-19】此前取的是**最远**的（见下方注释），与方案 3.F"不再默认最远矿点最优"冲突。
## 找不到合适资源时返回 Vector3.INF（本轮放弃扩张，由 _try_construct_cc 回退到主 CC 附近）。
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
	var best_distance := 400.0  # 20m 平方下限：新基地必须与现有基地保持距离
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
		if not _covered_by_own_vision(position, own_entities):
			continue
		# 【2026-09-19 修确定缺陷】原实现用 `distance > best_distance` ⇒ **专挑最远**的
		# 资源簇当分矿：跑得最久、最容易被截、工人往返最费的定位反而被优先选中
		# （方案第 1 节："扩张偏远…"；方案 3.F："不再默认最远矿点最优"）。
		# 改为取"满足平安距离（best_distance 初值 = 20m 平方）之外**最近**"的资源簇：
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
	_refresh_planning()
