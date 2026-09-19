extends Node

signal resources_required(resources, metadata)

const AGTurretScene = preload("res://source/match/units/AntiGroundTurret.tscn")
const AATurretScene = preload("res://source/match/units/AntiAirTurret.tscn")

const FIELD_POSITION := 1 << 0
const FIELD_TYPE := 1 << 1
const FIELD_RELATION := 1 << 2
const REFRESH_INTERVAL_S := 1.0 / 60.0 * 30.0
const MAX_PLACEMENT_PROBES := 8
const PLACEMENT_BACKOFF_MS := 8000
const COMMAND_CENTER_TYPE_ID := "command_center"
const WORKER_TYPE_ID := "worker"
const AG_TURRET_TYPE_ID := "anti_ground_turret"
const AA_TURRET_TYPE_ID := "anti_air_turret"
## 防御塔"外围 / 内圈"分界（米）：≥ 此距离算"基地外围"（用户 2026-09-15 口径）。
## 与 Python `placement.TURRET_INNER_RADIUS_M` 同值（内圈判据两侧必须同口径）。
const TURRET_OUTER_RADIUS_M := 8.0
## 防御塔的**目标落点带外缘**（米）：带内越外越好，**出了带越远越差**。
## 【2026-09-15 晚 用户实测："AI副官让防御塔造的位置太靠外面了"】统一口径 ——
## 塔站在基地外缘，不再一路外推到视野尽头（旧口径是"离基地最远先试" + 上限 17/31m）。
## 唯一实现在 Python `adjutant_coordinator/graph/placement.py::turret_band_rank`
## （规则地板与四列模型两条路径都调它）；本文件必须与 Python 侧同值，
## 一致性由 `tools/verify_turret_band_parity.gd` 机器校验。
const TURRET_BAND_OUTER_M := 12.0
## 还没有塔锚点 / 已有塔锚点时的候选半径上限（米）：= Python
## `rules_fallback.TURRET_MAX_HQ_M`(16) 与 `TURRET_MAX_HQ_WITH_ANCHOR_M`(18)。
## 两档的理由不变：没塔时只有基地（10m）与工人（5m）的视野，再往外试探全是 `NotVisible`
## —— 白耗 `MAX_PLACEMENT_PROBES`（8 次用光就退避 8 秒），塔反而建不出来。
const TURRET_INITIAL_RADIUS_M := 16.0
const TURRET_MAX_RADIUS_M := 18.0
## 同类塔之间的**最小水平间距**（米）—— 【2026-09-15 用户报「简单电脑把防御塔造在一个地方」】。
## 原来候选项只按「离基地远近」排序，没有塔与塔的间距判据 ⇒ 每座新塔都从同一片（最外圈
## 的同一批扇区）开始试，多座塔会挤在相邻位置。塔占位约 2m，这里取 12m：
## 既避免两座塔贴身（浪费视野与火力覆盖），又不会因为"没地方可放"而建不出来。
const TURRET_MIN_SEPARATION_M := 12.0

## 决策节奏倍率：由 SimpleClairvoyantAI 按"本局电脑玩家人数"注入（唯一实现见 AiCadence）。
## 默认 1.0 = 原始节奏；3 个电脑时为 2.0（0.5s → 1.0s）。
var refresh_scale := 1.0

var _world_query_runtime = null
var _query_session_id := ""
var _command_gateway = null
var _number_of_pending_ag_turret_resource_requests := 0
var _number_of_pending_aa_turret_resource_requests := 0
var _clear_streak := 0
var _placement_backoff_until_ms := 0

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
	timer.start(REFRESH_INTERVAL_S * refresh_scale)


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


## 防御塔选址（用户 2026-09-15 口径）：**建在基地外缘（≤ `TURRET_BAND_OUTER_M`），基地内保留少量**。
## 规则：该类塔已有"内圈塔"时 → 外圈优先（按目标带打分，带内越外越好）；
## 一座内圈塔都没有时 → 这一座补在内圈（同样按带打分，从最靠近分界处往里收），免得基地门户全空。
func _try_construct_turret(unit_type_id: String, own_entities: Array):
	if Time.get_ticks_msec() < _placement_backoff_until_ms:
		return
	if not own_entities.any(func(entity): return entity.get("type_id", "") == WORKER_TYPE_ID):
		return
	var command_centers: Array = own_entities.filter(
		func(entity): return entity.get("type_id", "") == COMMAND_CENTER_TYPE_ID
	)
	if command_centers.is_empty():
		return
	var center: Vector3 = command_centers[0]["position"]
	# 候选上限分两档（见 `TURRET_INITIAL_RADIUS_M` 的注释）：没有塔当视野锚点时 16m，
	# 已有塔时沿它的 16m 视野最多到 18m —— 都收在基地附近（旧口径是 17/31m）。
	var existing_turrets: int = own_entities.filter(
		func(entity): return entity.get("type_id", "") == unit_type_id
	).size()
	var radius_limit := TURRET_MAX_RADIUS_M if existing_turrets > 0 else TURRET_INITIAL_RADIUS_M
	var candidates: Array[Vector3] = []
	for radius in range(3, int(radius_limit) + 1, 2):
		for sector in range(16):
			var angle := TAU * float(sector) / 16.0
			candidates.append(center + Vector3(cos(angle) * radius, 0.0, sin(angle) * radius))
	var outer: Array[Vector3] = []
	var inner: Array[Vector3] = []
	for candidate in candidates:
		if center.distance_to(candidate) >= TURRET_OUTER_RADIUS_M:
			outer.append(candidate)
		else:
			inner.append(candidate)
	# 【2026-09-15 用户报「简单电脑把防御塔造在一个地方」】
	# ① 依次剔除"离已有同类塔太近"的候选（`TURRET_MIN_SEPARATION_M`）；
	# ② 同圈内**离已有塔更远的先试**（去中心化），外围优先的口径不变。
	# 兜底：若剔除后某个圈空了，退回未剔除的列表 —— 宁可就近也不能建不出来。
	var existing_planar: Array[Vector3] = []
	for entity in own_entities:
		if entity.get("type_id", "") != unit_type_id:
			continue
		var existing_position: Vector3 = entity["position"]
		existing_planar.append(Vector3(existing_position.x, center.y, existing_position.z))
	var outer_spread := outer.filter(
		func(candidate): return _separation_from_existing(candidate, existing_planar) >= TURRET_MIN_SEPARATION_M
	)
	var inner_spread := inner.filter(
		func(candidate): return _separation_from_existing(candidate, existing_planar) >= TURRET_MIN_SEPARATION_M
	)
	if not outer_spread.is_empty():
		outer = outer_spread
	if not inner_spread.is_empty():
		inner = inner_spread
	# 两圈各自按**目标带**打分排序（`_band_rank`）：带内从外沿往里、**出带越远越靠后**；
	# 同档（打分相差 ≤0.5m）时按"离已有塔越远越先"排，避免多座塔挤在一处。
	outer.sort_custom(func(a, b): return _ranks_before(a, b, center, existing_planar))
	inner.sort_custom(func(a, b): return _ranks_before(a, b, center, existing_planar))
	var order: Array[Vector3] = (inner + outer) if _needs_one_inside_turret(
		unit_type_id, own_entities, center
	) else (outer + inner)
	var last_result: Dictionary = {}
	var probes := 0
	for position in order:
		if probes >= MAX_PLACEMENT_PROBES:
			break
		probes += 1
		last_result = _command_gateway.PlaceStructure(
			unit_type_id,
			Transform3D(Basis.IDENTITY, position)
		)
		if last_result.get("accepted", false):
			return
		if last_result.get("primary_issue", "") == "InsufficientResources":
			break
	_placement_backoff_until_ms = Time.get_ticks_msec() + PLACEMENT_BACKOFF_MS
	print("规则 AI 放置防御建筑被拒绝：%s" % last_result)


## 候选点到"最近的已有同类塔"的水平距离；没有已有塔时返回 `INF`（即不受限）。
## 【2026-09-15 用户报「简单电脑把防御塔造在一个地方」】用于给选址去中心化。
func _separation_from_existing(candidate: Vector3, existing_planar: Array[Vector3]) -> float:
	var nearest := INF
	for position in existing_planar:
		nearest = minf(nearest, candidate.distance_to(position))
	return nearest


## 防御塔"离基地远近"的打分：**带内越外越好，出了带越远越差**。
## GDScript 镜像是 Python `adjutant_coordinator/graph/placement.py::turret_band_rank`
## （唯一实现；规则地板 `pick_turret_spot` 与四列 `task_patch._build_placement` 都调它）。
## 两侧口径一致性由 `tools/verify_turret_band_parity.gd` 机器校验 —— 改这里必须同时改那边。
func _band_rank(distance_to_center: float) -> float:
	if distance_to_center <= TURRET_BAND_OUTER_M:
		return distance_to_center
	return 2.0 * TURRET_BAND_OUTER_M - distance_to_center


## 选址排序判据：先按目标带打分（大者优先），同档（≤0.5m）再按"离已有塔更远"。
func _ranks_before(a: Vector3, b: Vector3, center: Vector3,
		existing_planar: Array[Vector3]) -> bool:
	var rank_a := _band_rank(a.distance_to(center))
	var rank_b := _band_rank(b.distance_to(center))
	if absf(rank_a - rank_b) > 0.5:
		return rank_a > rank_b
	return (_separation_from_existing(a, existing_planar)
			> _separation_from_existing(b, existing_planar))


## 该类塔是否还没有"基地内"的那一座（用户口径：基地内保留少量）。
## 内圈判据与选址分界共用 `TURRET_OUTER_RADIUS_M`，避免"留了一座、系统却认为它在外圈"。
## 第一座（`existing == 0`）不做内圈保留：开局把塔砌在家门口会挡住自己的部队。
func _needs_one_inside_turret(unit_type_id: String, own_entities: Array, center: Vector3) -> bool:
	var existing := 0
	var inside := 0
	for entity in own_entities:
		if entity.get("type_id", "") != unit_type_id:
			continue
		existing += 1
		var position: Vector3 = entity["position"]
		var planar := Vector3(position.x, center.y, position.z)
		if center.distance_to(planar) < TURRET_OUTER_RADIUS_M:
			inside += 1
	return existing > 0 and inside == 0


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
	if Time.get_ticks_msec() < _placement_backoff_until_ms:
		_refresh_threat_scan()
		return
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
	# 【2026-09-19 修复确定缺陷】原实现 `if command_centers.is_empty(): return`
	# ⇒ 开局 CC 尚未建成、或 CC 被打掉之后，**整段威胁检测完全停摆**：基地挨打
	# 也不回防（方案 3.E.5："基地遭实质攻击不能受全局长冷却阻挡"）。
	# 改为无 CC 时退化为以**己方全部单位重心**为中心继续扫描，保证防守不中断。
	var center: Vector3
	if not command_centers.is_empty():
		center = command_centers[0]["position"]
	else:
		var own := _get_own_entities()
		var sum := Vector3.ZERO
		var counted := 0
		for entity in own:
			var entity_position: Vector3 = entity.get("position", Vector3.INF)
			if entity_position == Vector3.INF:
				continue
			sum += entity_position
			counted += 1
		if counted == 0:
			return
		center = sum / float(counted)
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
