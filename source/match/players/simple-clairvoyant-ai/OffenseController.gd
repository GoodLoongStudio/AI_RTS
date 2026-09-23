extends Node

signal resources_required(resources, metadata)

const VehicleFactoryScene = preload("res://source/match/units/VehicleFactory.tscn")
const TankScene = preload("res://source/match/units/Tank.tscn")
const AircraftFactoryScene = preload("res://source/match/units/AircraftFactory.tscn")
const HelicopterScene = preload("res://source/match/units/Helicopter.tscn")
const AutoAttackingBattlegroup = preload(
	"res://source/match/players/simple-clairvoyant-ai/AutoAttackingBattlegroup.gd"
)

const FIELD_POSITION := 1 << 0
const FIELD_TYPE := 1 << 1
const FIELD_CONSTRUCTION := 1 << 4
const FIELD_PRODUCTION := 1 << 5
const FIELD_ORDER := 1 << 6
const REFRESH_INTERVAL_S := 0.5
const MAX_PLACEMENT_PROBES := 8
const PLACEMENT_BACKOFF_MS := 8000
const COMMAND_CENTER_TYPE_ID := "command_center"
const WORKER_TYPE_ID := "worker"
const VEHICLE_FACTORY_TYPE_ID := "vehicle_factory"
const AIRCRAFT_FACTORY_TYPE_ID := "aircraft_factory"
const TANK_TYPE_ID := "tank"
const BarracksScene = preload("res://source/match/units/Barracks.tscn")
const SoldierScene = preload("res://source/match/units/Infantry.tscn")
const RocketeerScene = preload("res://source/match/units/Rocketeer.tscn")
const BARRACKS_TYPE_ID := "barracks"
const SOLDIER_TYPE_ID := "soldier"
const ROCKETEER_TYPE_ID := "rocketeer"
const HELICOPTER_TYPE_ID := "helicopter"

var _player = null
## 决策节奏倍率：由 SimpleClairvoyantAI 按"本局电脑玩家人数"注入（唯一实现见 AiCadence）。
## 默认 1.0 = 原始节奏；3 个电脑时为 2.0（0.5s → 1.0s）。
var refresh_scale := 1.0

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
## QueueFull 等拒绝后的退避截止时刻(ms)——按 metadata 键控。
var _queue_full_backoff := {}
## 期 2 步兵副线开关与在编上限（由难度档位决定）
var _infantry_production_enabled := false
var _infantry_cap := 0
## 简单档重型（坦克/直升机）上限；-1 = 不限制。
var _heavy_unit_cap := -1
## 兵营产炮兵上限；0 = 不产。简单档开局带对空。
var _rocketeer_cap := 0
var _secondary_production_enabled := false
var _battlegroup_under_forming = null
var _battlegroups := []
var _setup_ticks_ms := 0
var _defense_battlegroup = null
var _defense_recalled_at_ms := 0
var _placement_backoff_until_ms := 0

@onready var _ai = get_parent()
@onready var _balance = find_parent("Match").get_node("BalanceConfigRuntime")


## 绑定公共查询与固定身份命令边界，并初始化稳定 ID 作战编组。
func setup(player, world_query_runtime, query_session_id: String, command_gateway):
	_player = player
	_world_query_runtime = world_query_runtime
	_query_session_id = query_session_id
	_command_gateway = command_gateway
	# 与下方生产门控同一时间源（战局模拟时钟），混用实时时钟会算出负差值。
	_setup_ticks_ms = _ai.simulation_msec()
	_configure_primary_and_secondary_types()
	_setup_refresh_timer()
	_try_creating_new_battlegroup()
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
	elif metadata == "barracks_structure":
		_provision_structure(
			BARRACKS_TYPE_ID,
			BarracksScene,
			resources,
			metadata,
			own_entities
		)
	elif metadata == "soldier_unit":
		_provision_unit(
			SOLDIER_TYPE_ID,
			BARRACKS_TYPE_ID,
			SoldierScene,
			resources,
			metadata,
			own_entities
		)
	elif metadata == "rocketeer_unit":
		_provision_unit(
			ROCKETEER_TYPE_ID,
			BARRACKS_TYPE_ID,
			RocketeerScene,
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
	# 简单档：步兵补编制，重型最多 1；中等/困难仍以坦克为主、步兵作副线。
	if _ai.difficulty == _ai.Difficulty.EASY:
		_infantry_production_enabled = true
		_infantry_cap = maxi(
			0,
			_ai.expected_number_of_battlegroups * _ai.expected_number_of_units_in_battlegroup - 1
		)
		_heavy_unit_cap = 1
		_rocketeer_cap = 2
	else:
		_infantry_production_enabled = true
		_infantry_cap = 8 if _ai.difficulty == _ai.Difficulty.HARD else 4
		_heavy_unit_cap = -1
		_rocketeer_cap = 2 if _ai.difficulty == _ai.Difficulty.HARD else 1


func _setup_refresh_timer():
	var timer := Timer.new()
	add_child(timer)
	timer.timeout.connect(_on_refresh_timer_timeout)
	timer.start(REFRESH_INTERVAL_S * refresh_scale)


## 用一次己方快照维护工厂存在性与生产队列，避免直接读取建筑 Node。
func _refresh_logistics():
	var own_entities := _get_own_entities()
	_refresh_battlegroups(own_entities)
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
	if _infantry_production_enabled:
		_enforce_structure_existence(
			BARRACKS_TYPE_ID,
			BarracksScene,
			"barracks_structure",
			own_entities
		)
	_update_role_demand_from_intel()
	_enforce_units_production_by_ratio(own_entities)
	if _rocketeer_cap > 0:
		_enforce_rocketeer_production(own_entities)
	if _infantry_production_enabled:
		_enforce_infantry_production(own_entities)
	_enforce_recon_drones(own_entities)
	_refresh_defense_response(own_entities)


## 统计场上 + 队列 + 待处理请求里的坦克/直升机数量（简单档重型上限用）。
func _heavy_unit_count(own_entities: Array) -> int:
	var count := 0
	for entity in own_entities:
		var type_id: String = entity.get("type_id", "")
		if type_id in [TANK_TYPE_ID, HELICOPTER_TYPE_ID]:
			count += 1
		var production = entity.get("production", null)
		if production == null:
			continue
		for item in production.get("items", []):
			if item.get("product_type_id", "") in [TANK_TYPE_ID, HELICOPTER_TYPE_ID]:
				count += 1
	count += _number_of_pending_unit_resource_requests.get("primary_unit", 0)
	count += _number_of_pending_unit_resource_requests.get("secondary_unit", 0)
	return count


## 【2026-09-19 S2：侦察情报进入生产决策】
## `IntelligenceController` 每拍都在产出敌军配比直方图
## （`get_enemy_composition_summary()`），但此前**没有任何消费者** —— 侦察白做了
## （方案第 1 节："敌军配比统计无消费者"；审查 2026-09-16 同样指出旧 getter 无消费者）。
## 这里把它接进生产：观察到敌方空军 ⇒ 追加防空（rocketeer）；观察到敌方重装
## ⇒ 追加反装甲步兵。严格只用**实际观察到**的敌情，不看视野外、不加资源、不刷兵。
## 上限每次都从"档位基线"重算，不会因反复调用而累积膨胀。
func _update_role_demand_from_intel() -> void:
	var intel := (
		get_parent().get_node_or_null("IntelligenceController") if get_parent() != null else null
	)
	if intel == null or not intel.has_method("get_enemy_composition_summary"):
		return
	var counts: Dictionary = intel.call("get_enemy_composition_summary")
	if counts.is_empty():
		return
	var air_count := 0
	var heavy_count := 0
	for type_id in counts:
		var amount := int(counts[type_id])
		match String(type_id):
			"helicopter":
				air_count += amount
			"tank", "heavy_tank":
				heavy_count += amount
	# 档位基线：与 _configure_primary_and_secondary_types() 保持一致。
	var base_rocketeer := 2
	var base_infantry := 8 if _ai.difficulty == _ai.Difficulty.HARD else 4
	if _ai.difficulty == _ai.Difficulty.EASY:
		base_infantry = maxi(
			0,
			_ai.expected_number_of_battlegroups * _ai.expected_number_of_units_in_battlegroup - 1
		)
	_rocketeer_cap = base_rocketeer + (2 if air_count >= 2 else 0)
	_infantry_cap = base_infantry + (2 if heavy_count >= 3 else 0)


## 【2026-09-21 S2 侦察任务化·阵亡补位】无人机是唯一侦察单位：损失后不补，
## 地图分区复查会逐渐失效（方案 2.C："侦察员阵亡有恢复"）。按难度维持目标架数：
## 简单 1 / 中等 2 / 困难 2（侦察覆盖随难度递增，与侦察复查目标 90/60/35 秒一致）。
## 只在飞机厂完工、且"现有 + 在造 + 待处理"都不足时下单；被拒也记退避，
## 避免每个刷新拍重试刷日志与事务。
const DRONE_TYPE_ID := "drone"
const DRONE_REQUEST_BACKOFF_MS := 12000
var _last_drone_request_ms := 0


func _enforce_recon_drones(own_entities: Array) -> void:
	var target_drones := 2
	if _ai.difficulty == _ai.Difficulty.EASY:
		target_drones = 1
	var alive := 0
	var queued := 0
	for entity in own_entities:
		if entity.get("type_id", "") == DRONE_TYPE_ID:
			alive += 1
		var production = entity.get("production", null)
		if production == null:
			continue
		for item in production.get("items", []):
			if item.get("product_type_id", "") == DRONE_TYPE_ID:
				queued += 1
	if alive + queued >= target_drones:
		return
	if _ai.simulation_msec() - _last_drone_request_ms < DRONE_REQUEST_BACKOFF_MS:
		return
	var producers := _completed_producers(AIRCRAFT_FACTORY_TYPE_ID, own_entities)
	if producers.is_empty():
		return
	_last_drone_request_ms = _ai.simulation_msec()
	var result: Dictionary = _command_gateway.EnqueueProduction(
		producers[0]["id"],
		DRONE_TYPE_ID
	)
	if result.get("accepted", false):
		print("规则 AI 补充侦察无人机（现有 %d + 在造 %d / 目标 %d）" % [
			alive, queued, target_drones
		])
	else:
		print("规则 AI 补侦察无人机被拒绝（12s 退避）：%s" % result)


## 出兵入口：按主:副配比（AI-plan Part A Phase 6）决定这一拍生产哪种单位。
## 副产线未启用时保持旧口径只出主兵种。
func _enforce_units_production_by_ratio(own_entities: Array):
	if _heavy_unit_cap >= 0 and _heavy_unit_count(own_entities) >= _heavy_unit_cap:
		return
	var metadata := _preferred_unit_metadata(own_entities)
	if metadata == "primary_unit":
		_enforce_units_production(
			_primary_structure_type_id,
			_primary_unit_scene,
			"primary_unit",
			own_entities
		)
	else:
		_enforce_units_production(
			_secondary_structure_type_id,
			_secondary_unit_scene,
			"secondary_unit",
			own_entities
		)


## 以「加入后与配比偏差最小」选择本拍生产的单位类型；生产门口与完工产线校验仍由
## _enforce_units_production 兜底（无完工产线自动落到另一条线）。
func _preferred_unit_metadata(own_entities: Array) -> String:
	if not _secondary_production_enabled:
		return "primary_unit"
	var queued := _queued_unit_counts(own_entities)
	# 【2026-09-17 修复确定缺陷】原实现只看**队列 + 待处理请求**，完全不看**现役**：
	# 场上已有 3 辆坦克时 primary_count 仍是 0，于是判定"该补主兵种"继续堆坦克
	# （方案第 1 节：坦克/直升机配比只看队列及待处理请求，遗漏现役）。
	# 现役、真正排队、尚未入队请求三者相加，同一实体只占一个桶。
	var owned := _owned_unit_counts(own_entities)
	var primary_count: int = (
		owned["primary"]
		+ queued["primary"]
		+ _number_of_pending_unit_resource_requests.get("primary_unit", 0)
	)
	var secondary_count: int = (
		owned["secondary"]
		+ queued["secondary"]
		+ _number_of_pending_unit_resource_requests.get("secondary_unit", 0)
	)
	var ratio: int = maxi(1, _ai.primary_to_secondary_unit_ratio)
	var diff_if_primary := absi(primary_count + 1 - ratio * secondary_count)
	var diff_if_secondary := absi(primary_count - ratio * (secondary_count + 1))
	return "primary_unit" if diff_if_primary <= diff_if_secondary else "secondary_unit"


## 统计场上**现役**主/副兵种数量（不含生产队列与待处理请求，避免双重计数）。
## 与 `_queued_unit_counts` 配对使用：两者相加才是"这一角色的真实占有量"。
func _owned_unit_counts(own_entities: Array) -> Dictionary:
	var counts := {"primary": 0, "secondary": 0}
	for entity in own_entities:
		var type_id: String = entity.get("type_id", "")
		if type_id == _primary_unit_type_id:
			counts["primary"] += 1
		elif type_id == _secondary_unit_type_id:
			counts["secondary"] += 1
	return counts


## 统计生产队列中的主/副兵种数量（资源请求单列，避免双重计数）。
func _queued_unit_counts(own_entities: Array) -> Dictionary:
	var counts := {"primary": 0, "secondary": 0}
	for entity in own_entities:
		var production = entity.get("production", null)
		if production == null:
			continue
		for item in production.get("items", []):
			var product_type_id: String = item.get("product_type_id", "")
			if product_type_id == _primary_unit_type_id:
				counts["primary"] += 1
			elif product_type_id == _secondary_unit_type_id:
				counts["secondary"] += 1
	return counts


## 步兵副线（期 2）：兵营完工且步兵在编上限内时请求生产，不占用主/副配比。
func _enforce_infantry_production(own_entities: Array):
	# 【2026-09-17】时间源改用**战局模拟时钟**（暂停不累计），原 `Time.get_ticks_msec()`
	# 是实时时钟，暂停/卡顿会让生产门槛漂移。门槛值来自 `first_wave_delay_s`，
	# 该参数 2026-09-17 起**只门控生产**，三档默认 0（条件合法即生产）。
	if _ai.simulation_msec() - _setup_ticks_ms < int(_ai.first_wave_delay_s * 1000.0):
		return
	# 【2026-09-17 方案：时间源统一】改用模拟时钟（暂停不累计）。
	# 赋值处（下面的 `_queue_full_backoff[...] = ...`）必须同源，否则实时值减模拟值
	# 会算出巨大正数／负差值，退避窗口直接失效。
	if _ai.simulation_msec() < int(_queue_full_backoff.get("soldier_unit", 0)):
		return
	if _completed_producers(BARRACKS_TYPE_ID, own_entities).is_empty():
		return
	var soldier_count: int = _number_of_pending_unit_resource_requests.get("soldier_unit", 0)
	for entity in own_entities:
		if entity.get("type_id", "") == SOLDIER_TYPE_ID:
			soldier_count += 1
		var production = entity.get("production", null)
		if production == null:
			continue
		for item in production.get("items", []):
			if item.get("product_type_id", "") == SOLDIER_TYPE_ID:
				soldier_count += 1
	if soldier_count >= _infantry_cap or _number_of_pending_unit_resource_requests.get(
		"soldier_unit", 0
	) > 0:
		return
	_number_of_pending_unit_resource_requests["soldier_unit"] = (
		_number_of_pending_unit_resource_requests.get("soldier_unit", 0) + 1
	)
	resources_required.emit(_balance.GetProductionCost(SoldierScene), "soldier_unit")


func _count_owned_and_queued(own_entities: Array, type_id: String, request_key: String) -> int:
	var count: int = _number_of_pending_unit_resource_requests.get(request_key, 0)
	for entity in own_entities:
		if entity.get("type_id", "") == type_id:
			count += 1
		var production = entity.get("production", null)
		if production == null:
			continue
		for item in production.get("items", []):
			if item.get("product_type_id", "") == type_id:
				count += 1
	return count


## 兵营产炮兵：开局进攻编组带上对空。
func _enforce_rocketeer_production(own_entities: Array):
	# 【2026-09-17】时间源改用**战局模拟时钟**（暂停不累计），原 `Time.get_ticks_msec()`
	# 是实时时钟，暂停/卡顿会让生产门槛漂移。门槛值来自 `first_wave_delay_s`，
	# 该参数 2026-09-17 起**只门控生产**，三档默认 0（条件合法即生产）。
	if _ai.simulation_msec() - _setup_ticks_ms < int(_ai.first_wave_delay_s * 1000.0):
		return
	# 【2026-09-17 方案：时间源统一】改用模拟时钟（暂停不累计）。
	# 赋值处（下面的 `_queue_full_backoff[...] = ...`）必须同源，否则实时值减模拟值
	# 会算出巨大正数／负差值，退避窗口直接失效。
	if _ai.simulation_msec() < int(_queue_full_backoff.get("rocketeer_unit", 0)):
		return
	if _completed_producers(BARRACKS_TYPE_ID, own_entities).is_empty():
		return
	if _count_owned_and_queued(own_entities, ROCKETEER_TYPE_ID, "rocketeer_unit") >= _rocketeer_cap:
		return
	if _number_of_pending_unit_resource_requests.get("rocketeer_unit", 0) > 0:
		return
	_number_of_pending_unit_resource_requests["rocketeer_unit"] = (
		_number_of_pending_unit_resource_requests.get("rocketeer_unit", 0) + 1
	)
	resources_required.emit(_balance.GetProductionCost(RocketeerScene), "rocketeer_unit")


## 防御响应（AI-plan Part A Phase 5）：基地威胁有效时派最近的非撤退编组回防；
## 威胁解除且满足最短执行时间后停火一拍，交还常规交战逻辑。
func _refresh_defense_response(own_entities: Array):
	var threat: Vector3 = _ai.get_base_threat()
	if threat != Vector3.INF:
		var assigned_valid: bool = (
			_defense_battlegroup != null
			and is_instance_valid(_defense_battlegroup)
			and not _defense_battlegroup.is_queued_for_deletion()
		)
		if not assigned_valid:
			_defense_battlegroup = _nearest_available_battlegroup(own_entities, threat)
			if _defense_battlegroup != null:
				_defense_battlegroup.assume_defense_position(threat)
				_defense_recalled_at_ms = _ai.simulation_msec()
		elif _ai.simulation_msec() - _defense_recalled_at_ms > 5000:
			_defense_battlegroup.assume_defense_position(threat)
			_defense_recalled_at_ms = _ai.simulation_msec()
		return
	if _defense_battlegroup != null and is_instance_valid(_defense_battlegroup):
		if (
			_ai.simulation_msec() - _defense_recalled_at_ms
			>= int(_ai.defense_recall_min_s * 1000.0)
		):
			_defense_battlegroup.resume_offense()
			_defense_battlegroup = null


## 选派距威胁点最近、已出击且未在撤退的编组执行回防。
func _nearest_available_battlegroup(own_entities: Array, threat: Vector3):
	var best = null
	var best_distance := INF
	for battlegroup in _battlegroups:
		if (
			not is_instance_valid(battlegroup)
			or battlegroup.is_queued_for_deletion()
			or battlegroup.is_retreating()
			or battlegroup.size() <= 0
		):
			continue
		var center: Vector3 = battlegroup.center_for(own_entities)
		var distance: float = center.distance_squared_to(threat)
		if distance < best_distance:
			best_distance = distance
			best = battlegroup
	return best


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
		# QueueFull 等拒绝: 5 秒退避后再试(否则每个刷新周期重试, 每秒上百次日志+事务风暴)。
		_queue_full_backoff[metadata] = _ai.simulation_msec() + 5000
		print("规则 AI 生产作战单位被拒绝(5s 退避)：%s" % result)


## 围绕己方 CommandCenter（失去基地时改用 Worker）尝试放置生产建筑。
func _try_construct_structure(structure_type_id: String, own_entities: Array):
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
	var probes := 0
	for position in candidates:
		if probes >= MAX_PLACEMENT_PROBES:
			break
		probes += 1
		last_result = _command_gateway.PlaceStructure(
			structure_type_id,
			Transform3D(Basis.IDENTITY, position)
		)
		if last_result.get("accepted", false):
			return
		if last_result.get("primary_issue", "") == "InsufficientResources":
			break
	_placement_backoff_until_ms = Time.get_ticks_msec() + PLACEMENT_BACKOFF_MS
	print("规则 AI 放置生产建筑被拒绝：%s" % last_result)


## 在己方快照中确保指定生产建筑存在；施工蓝图已经计入数量。
func _enforce_structure_existence(
	structure_type_id: String,
	structure_scene: PackedScene,
	metadata: String,
	own_entities: Array
):
	if Time.get_ticks_msec() < _placement_backoff_until_ms:
		return
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
	# 【2026-09-17】时间源改用**战局模拟时钟**（暂停不累计），原 `Time.get_ticks_msec()`
	# 是实时时钟，暂停/卡顿会让生产门槛漂移。门槛值来自 `first_wave_delay_s`，
	# 该参数 2026-09-17 起**只门控生产**，三档默认 0（条件合法即生产）。
	if _ai.simulation_msec() - _setup_ticks_ms < int(_ai.first_wave_delay_s * 1000.0):
		return
	# 【2026-09-17 方案：时间源统一】改用模拟时钟（暂停不累计）。
	# 赋值处（下面的 `_queue_full_backoff[...] = ...`）必须同源，否则实时值减模拟值
	# 会算出巨大正数／负差值，退避窗口直接失效。
	if _ai.simulation_msec() < int(_queue_full_backoff.get(metadata, 0)):
		return
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
	# 【2026-09-17 修复确定缺陷】兵营请求写入的键是 `barracks_structure`
	# （见 provision() 分支与 _refresh_logistics 的 _enforce_structure_existence 调用），
	# 但原先这里只统计 primary/secondary 两个键 ⇒ 兵营的重复请求不被去重，
	# 会重复挤占预算与施工机会（方案第 1 节："兵营请求写入 barracks_structure，
	# 去重只查另外两种结构键"）。
	if structure_type_id == BARRACKS_TYPE_ID:
		result += _number_of_pending_structure_resource_requests.get("barracks_structure", 0)
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


## 返回当前所有编组（含未创建名额）仍需补充的作战单位总数；
## 这是「打光→补满→再出击」攻击波的生产依据。
func _number_of_additional_units_required() -> int:
	var total_missing := 0
	for battlegroup in _battlegroups:
		if is_instance_valid(battlegroup) and not battlegroup.is_queued_for_deletion():
			total_missing += maxi(0, battlegroup.capacity() - battlegroup.size())
	if _battlegroups.size() < _ai.expected_number_of_battlegroups:
		total_missing += _ai.expected_number_of_units_in_battlegroup
	return total_missing


## 查询生产后勤所需的准确己方位置、类型、施工状态与生产队列。
func _get_own_entities() -> Array:
	var result: Dictionary = _world_query_runtime.GetOwnForces(
		_query_session_id,
		FIELD_POSITION | FIELD_TYPE | FIELD_CONSTRUCTION | FIELD_PRODUCTION | FIELD_ORDER
	)
	if result.get("status", "") != "Accepted":
		push_warning("rule AI offense query was rejected: %s" % result.get("error", "Unknown"))
		return []
	return result["entities"]


## 创建只持有稳定单位 ID、使用公共查询和固定身份命令的作战编组。
func _try_creating_new_battlegroup() -> bool:
	if not _battlegroups.is_empty() and _ai.difficulty != _ai.Difficulty.EASY:
		_secondary_production_enabled = true
	if _battlegroups.size() == _ai.expected_number_of_battlegroups:
		_battlegroup_under_forming = null
		return false
	var battlegroup = AutoAttackingBattlegroup.new()
	var min_launch := 2 if _ai.difficulty == _ai.Difficulty.EASY else 0
	# 首波出击门槛**只约束第一支编组**（方案第 2 节：首波 35–50 / 25–40 / 20–30 模拟秒）。
	# 后续编组建好即可投入，节奏改由"上波结束到再次派出"的间隔控制。
	# 注意：这里用"编组创建时刻"近似对局开始时刻（编组在 setup 阶段创建，误差极小）。
	var earliest_attack_sim_ms := 0
	if _battlegroups.is_empty() and _ai.attack_wave_delay_s > 0.0:
		earliest_attack_sim_ms = _ai.simulation_msec() + int(_ai.attack_wave_delay_s * 1000.0)
	# 【2026-09-21 S2 多线】中等/困难：第二支及以后的编组设为**袭扰组**
	# （工人与落单单位优先、不啃塔），与主力编组（结构优先）形成两条独立战线；
	# 简单档保持单线（节奏更可读；方案 2.D 的袭扰只要求中等+难度）。
	var harasser := false
	if _ai.difficulty != _ai.Difficulty.EASY and not _battlegroups.is_empty():
		harasser = true
	# ⚠ `earliest_attack_sim_ms` 必须真的传进 setup，否则首波门槛只在本地声明、不生效。
	battlegroup.setup(
		_ai.expected_number_of_units_in_battlegroup,
		_world_query_runtime,
		_query_session_id,
		_command_gateway,
		_ai.retreat_threshold,
		_ai.is_passive_test_ai(),
		min_launch,
		earliest_attack_sim_ms,
		harasser
	)
	_battlegroups.append(battlegroup)
	battlegroup.tree_exited.connect(_on_battlegroup_died.bind(battlegroup))
	add_child(battlegroup)
	_battlegroup_under_forming = battlegroup
	return true


## 用己方公共快照维护编组成员，并把尚未分配的作战单位交给第一个未满编的编组
## （撤退回满、战损补充都走同一条增援路径）。
func _refresh_battlegroups(own_entities: Array):
	for battlegroup in _battlegroups.duplicate():
		if is_instance_valid(battlegroup) and not battlegroup.is_queued_for_deletion():
			battlegroup.refresh(own_entities)
	_attach_unassigned_battle_units(own_entities)


## 按稳定 ID 分配 Tank 与 Helicopter：优先补最缺员的既有编组，编组全满且
## 未达编组总数时创建新编组。
func _attach_unassigned_battle_units(own_entities: Array):
	var battle_type_ids := [TANK_TYPE_ID, HELICOPTER_TYPE_ID]
	if _infantry_production_enabled:
		battle_type_ids.append(SOLDIER_TYPE_ID)
	if _rocketeer_cap > 0:
		battle_type_ids.append(ROCKETEER_TYPE_ID)
	var battle_entities: Array = own_entities.filter(
		func(entity): return entity.get("type_id", "") in battle_type_ids
	)
	for entity in battle_entities:
		var unit_id: String = entity.get("id", "")
		if _battlegroups.any(
			func(battlegroup):
				return is_instance_valid(battlegroup) and battlegroup.has_member(unit_id)
		):
			continue
		var target_group = null
		for battlegroup in _battlegroups:
			if (
				is_instance_valid(battlegroup)
				and not battlegroup.is_queued_for_deletion()
				and battlegroup.size() < battlegroup.capacity()
			):
				target_group = battlegroup
				break
		if target_group == null:
			if not _try_creating_new_battlegroup():
				return
			target_group = _battlegroup_under_forming
		target_group.attach_entity(entity)


func _on_battlegroup_died(battlegroup):
	if not is_inside_tree():
		return
	_battlegroups.erase(battlegroup)
	if _defense_battlegroup == battlegroup:
		_defense_battlegroup = null


func _on_refresh_timer_timeout():
	_refresh_logistics()
