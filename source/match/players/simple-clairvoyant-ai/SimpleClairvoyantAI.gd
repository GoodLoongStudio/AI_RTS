extends "res://source/match/players/Player.gd"

const AiCadence = preload("res://source/match/players/simple-clairvoyant-ai/AiCadence.gd")

## 战场扫描的字段位与半径（与 `AutoAttackingBattlegroup` 的观察需求一致）。
const FIELD_POSITION := 1 << 0
const FIELD_TYPE := 1 << 1
const FIELD_RELATION := 1 << 2
const GLOBAL_DEMO_SCAN_RADIUS_M := 100000.0

enum ResourceRequestPriority { LOW, MEDIUM, HIGH }
enum OffensiveStructure { VEHICLE_FACTORY, AIRCRAFT_FACTORY }
enum Difficulty { EASY, NORMAL, HARD }

## 旧参数（保留兼容既有测试与场景）；实际工人目标由 CC 数 × workers_per_command_center 推导。
@export var expected_number_of_workers = 3
@export var expected_number_of_ccs = 1
## 防御塔数量（2026-09-15 用户口径："优先建到基地外围，基地内保留少量"）：
## 每类 2 座 ⇒ 1 座在外围把火力线推出去、1 座留在基地内补门户。
@export var expected_number_of_ag_turrets = 2
@export var expected_number_of_aa_turrets = 2
@export var primary_offensive_structure = OffensiveStructure.VEHICLE_FACTORY
@export var secondary_offensive_structure = OffensiveStructure.AIRCRAFT_FACTORY
@export var expected_number_of_battlegroups = 3
@export var expected_number_of_units_in_battlegroup = 6

## —— 智能化改造新增参数（见 docs/plan/AI-plan.md Part A）——
## 条件扩张：CC 数上限（0 = 永不扩张，保持旧口径 expected_number_of_ccs）。
@export var max_command_centers = 3
## 每座 CommandCenter 的目标工人数（实际目标 = 现有 CC 数 × 该值）。
@export var workers_per_command_center = 6
## 扩张门槛：resource_a 余额 ≥ 此值才请求开分矿（占位值，按实测标定）。
## 统一货币（2026-09-14）：B 已移除，门槛只看 A。
@export var expansion_resource_threshold = 10
## 编组存活低于 满编 × retreat_threshold 时整编撤退回主基地。
@export var retreat_threshold = 0.5
## 【2026-09-17 语义收敛】`first_wave_delay_s` 现在**只门控战斗单位的生产**，
## 且三档默认 0.0 —— 条件合法（有完工产线、资源够、角色有缺口）就立即生产，
## 不能到"首波时间"才开始造。困难档原先的 120 会让它前两分钟比中等还消极。
@export var first_wave_delay_s = 0.0
## **首次主动出击门槛**（模拟秒，从对局开始计）。与生产门槛分离：兵可以先造好等着，
## 到点再出击。首版设计值（方案第 2 节，待 S0 校准）：EASY 42 / NORMAL 32 / HARD 25。
## 只约束**首波**；后续波的节奏由 `re_dispatch_interval_s` 控制。
@export var attack_wave_delay_s = 32.0
## 【2026-09-19 三档校准】上波进攻结束（编组进入重整）到**再次派出**的最短间隔
## （模拟秒）。首版设计值取方案第 2 节区间的中值：
##   EASY 32（25–40）/ NORMAL 17（12–22）/ HARD 8（5–12）。
## 与 `attack_wave_delay_s` 的区别：后者只约束**首波**的绝对开火时间；
## 前者约束**每两波之间**的节奏 ⇒ 决定"压迫是否连续"。
@export var re_dispatch_interval_s = 17.0
## 防御威胁扫描半径（以主基地为中心一次大半径扫描，避免逐建筑扫描线性膨胀）。
@export var defense_scan_radius = 40.0
## 回防最短执行时间（秒），防止威胁抖动导致编组来回拉扯。
@export var defense_recall_min_s = 30.0
## 主工厂:副工厂 出兵配比（primary_to_secondary_unit_ratio:1）。
@export var primary_to_secondary_unit_ratio = 2
## 难度档位；EASY/HARD 会覆写上述部分参数，NORMAL 沿用当前 @export 值。
@export var difficulty: Difficulty = Difficulty.NORMAL

var _provisioning_ongoing = false
var _resource_requests = {
	ResourceRequestPriority.LOW: [],
	ResourceRequestPriority.MEDIUM: [],
	ResourceRequestPriority.HIGH: [],
}
## 全局战场扫描的按帧缓存（见 `battlefield_scan`）。
var _battlefield_scan_frame := -1
var _battlefield_scan_result: Array = []
var _call_to_perform_during_process = null
var _world_query_runtime = null
var _query_session_id := ""

# —— 基地威胁中枢（DefenseController 上报 → OffenseController 消费）——
var _base_threat_position := Vector3.INF
var _base_threat_until_ms := 0

@onready var _match = find_parent("Match")

@onready var _economy_controller = find_child("EconomyController")
@onready var _defense_controller = find_child("DefenseController")
@onready var _offense_controller = find_child("OffenseController")
@onready var _intelligence_controller = find_child("IntelligenceController")
@onready var _construction_works_controller = find_child("ConstructionWorksController")


## 接收 Match 组合根签发的本玩家标准查询会话；规则 AI 不得自行选择观察者身份。
func setup_world_query(world_query_runtime, query_session_id: String):
	assert(_world_query_runtime == null, "world query session can only be configured once")
	assert(not query_session_id.is_empty(), "rule AI requires a standard query session")
	_world_query_runtime = world_query_runtime
	_query_session_id = query_session_id


func _ready():
	# 【2026-09-17 方案 2.A：移除隐式降档】旧实现在这里做了两件"静默改难度"的事：
	#   1) 专用服把 NORMAL 静默改成 EASY；
	#   2) 联机 NORMAL 再叠加 120 秒生产门槛 + 缩小编组。
	# 结果是玩家在菜单选了"中等"，实际对手却是被改过的配置，同一个档位在
	# 单机/联机/专用服下含义不一致。方案要求覆盖顺序为：
	#   **玩家选择 → 合法对局规则 → 显式测试模式**，隐式降级一律移除。
	# 需要更弱的对手请在菜单里选难度，不要在这里改。
	_apply_difficulty_profile()
	# 显式 peaceful 测试模式：独立保留并标记，不得泄漏到普通对局。
	if NetSession.e2e_peaceful_server:
		first_wave_delay_s = 600.0
		attack_wave_delay_s = 600.0
	# wait for match to be ready
	if not _match.is_node_ready():
		await _match.ready
	if NetSession.is_client_puppet():
		set_process(false)
		return
	# wait additional frame to make sure other players are in place
	await get_tree().physics_frame
	# ready 信号可能在 Match._ready 首次挂起（导航烘焙 await）时即已发射，
	# 早于 BindRuleAiSessions 的会话绑定——轮询等待会话就绪而非依赖 ready 时序。
	var wait_frames := 0
	while _world_query_runtime == null:
		wait_frames += 1
		if wait_frames > 600:
			assert(false, "rule AI world query session was never bound by Match")
			return
		await get_tree().process_frame

	# 决策节奏：一局里的电脑玩家越多，单个 AI 的决策拍越长（用户 2026-09-15 批准）。
	# 必须在各 Controller 的 setup() 之前注入 —— 它们是在 setup() 里建 Timer 并起拍的。
	_apply_refresh_cadence()
	changed.connect(_on_player_data_changed)
	_economy_controller.resources_required.connect(
		_on_resource_request.bind(_economy_controller, ResourceRequestPriority.HIGH)
	)
	_economy_controller.setup(
		_world_query_runtime,
		_query_session_id,
		get_node("RuleAiCommandGateway")
	)
	_defense_controller.resources_required.connect(
		_on_resource_request.bind(_defense_controller, ResourceRequestPriority.MEDIUM)
	)
	_defense_controller.setup(
		_world_query_runtime,
		_query_session_id,
		get_node("RuleAiCommandGateway")
	)
	_offense_controller.resources_required.connect(
		_on_resource_request.bind(_offense_controller, ResourceRequestPriority.LOW)
	)
	_offense_controller.setup(
		self,
		_world_query_runtime,
		_query_session_id,
		get_node("RuleAiCommandGateway")
	)
	_intelligence_controller.setup(
		_world_query_runtime,
		_query_session_id,
		get_node("RuleAiCommandGateway")
	)
	_construction_works_controller.setup(
		_world_query_runtime,
		_query_session_id,
		get_node("RuleAiCommandGateway")
	)


func _process(_delta):
	if _call_to_perform_during_process != null:
		var call_to_perform = _call_to_perform_during_process
		_call_to_perform_during_process = null
		call_to_perform.call()


func _provision(controller, resources, metadata):
	_provisioning_ongoing = true
	controller.provision(resources, metadata)
	_provisioning_ongoing = false


func _try_fulfilling_resource_requests_according_to_priorities_next_frame():
	"""This function defers call so that:
	1. 'add_child() from tree_exited signal handler' bug is avoided
	2. high level loop of signals triggering each other is avoided"""
	_call_to_perform_during_process = _try_fulfilling_resource_requests_according_to_priorities


func _try_fulfilling_resource_requests_according_to_priorities():
	if _provisioning_ongoing:
		return
	for priority in [
		ResourceRequestPriority.HIGH, ResourceRequestPriority.MEDIUM, ResourceRequestPriority.LOW
	]:
		# 【2026-09-17 方案 3.B.5】同档内**扫描第一个付得起的请求**，不再只看队首。
		# 历史演进：最初是 `break`（队首付不起 ⇒ 低优先级整轮拿不到钱，表现为
		# "一直攒钱，什么都不造"）→ 改成 `continue`（档与档之间不再互相阻塞）→
		# 现在补上**档内**阻塞：同一档的队首若挂着一个昂贵计划（例如 2400 的分矿 CC），
		# 后面更便宜的急需项会被它永久挡住。
		# 注意这不是"忽略昂贵请求"：它仍留在队列里，钱够了自然会被扫到；
		# `_has_resources()` 依旧逐条校验，不会超支、不会作弊。
		var progressed := true
		while progressed:
			progressed = false
			for index in range(_resource_requests[priority].size()):
				var candidate = _resource_requests[priority][index]
				if not _has_resources(candidate["resources"]):
					continue
				_resource_requests[priority].remove_at(index)
				_provision(
					candidate["controller"],
					candidate["resources"],
					candidate["metadata"]
				)
				# `_provision` 可能新增请求或改变余额，重新从头扫描。
				progressed = true
				break


## 通过己方标准查询会话检查资源请求能否进入执行阶段。
func _has_resources(resources: Dictionary) -> bool:
	var result: Dictionary = _world_query_runtime.GetOwnEconomy(_query_session_id)
	if result.get("status", "") != "Accepted":
		push_warning("rule AI economy query was rejected: %s" % result.get("error", "Unknown"))
		return false
	var balances: Dictionary = result.get("economy", {}).get("balances", {})
	for resource_name in resources:
		if not balances.has(resource_name) or balances[resource_name] < resources[resource_name]:
			return false
	return true


func _on_player_data_changed():
	_try_fulfilling_resource_requests_according_to_priorities_next_frame()


func _on_resource_request(resources, metadata, controller, priority):
	assert(not _provisioning_ongoing, "resource request received during provisioning")
	_resource_requests[priority].append(
		{"controller": controller, "resources": resources, "metadata": metadata}
	)
	_try_fulfilling_resource_requests_according_to_priorities_next_frame()


## 应用难度档位。NORMAL 不覆写任何参数：直接沿用 @export 默认值，
## 避免破坏测试与场景在实例化后对参数的外部设定（难度表见 AI-plan Part A Phase 7）。
func _apply_difficulty_profile():
	match difficulty:
		Difficulty.EASY:
			workers_per_command_center = 4
			expected_number_of_battlegroups = 2
			expected_number_of_units_in_battlegroup = 4
			retreat_threshold = 0.35
			# 【2026-09-15 用户口径两次更新，**当前口径 = 半分钟（30s）**】
			# `first_wave_delay_s` 的门控在 OffenseController 出现三处（主产线/步兵/炮兵），
			# 效果是延迟内**不生产任何作战单位**：30s 前只有无人机沿网格巡逻探路
			# （IntelligenceController，不受此参数影响）与工人造建筑；
			# 30s 后开始造兵，凑够出击人数（min_launch=2）即前压。
			# 历史：原 0.0（开局就出兵）→ 60.0（用户"1 分钟"）→ **30.0（用户"半分钟"）**。
			# ⚠ 别再往上调：延迟越长，"简单电脑不会进攻"的观感越强（用户已反馈过一次）。
			# 历史：**240.0（HEAD 口径 = 4 分钟不产兵，用户抱怨"不会进攻"）** → 60.0 → 30.0
			# → **0.0（2026-09-17：该参数已收敛为"只门控生产"，三档都不该延迟生产）**。
			# 用户要的"半分钟后才打"由 `attack_wave_delay_s` 承担（下方），不是靠不造兵。
			first_wave_delay_s = 0.0
			attack_wave_delay_s = 42.0
			re_dispatch_interval_s = 32.0
			# 【2026-09-15 已回滚，勿再收小】此处曾把简单档的塔收成 1+1、CC 上限收成 2、
			# 开矿门槛抬到 2500，想让开局的钱优先落到产线上。用户实测后果是
			# 「简单电脑变得智障了，不会造建筑了」—— 塔少、不开分矿，观感就是 AI 不会建设。
			# 现恢复为与普通档同口径（塔沿 @export 2+2、CC 上限 3、开矿门槛 10），
			# **不要再动这几项**：难度弱化只能靠产兵节奏（first_wave_delay_s / 编组规模），
			# 不能靠"不建东西"来实现，否则玩家看到的就是"AI 坏了"。
		Difficulty.HARD:
			workers_per_command_center = 8
			expected_number_of_battlegroups = 3
			expected_number_of_units_in_battlegroup = 6
			retreat_threshold = 0.6
			# 【2026-09-17 修复确定缺陷】`first_wave_delay_s = 120.0` 会**阻止战斗单位生产**，
			# 导致困难档前两分钟比中等档还消极（方案第 1 节表）。
			# 生产改为条件合法即开始；困难档的"更快"体现在 `attack_wave_delay_s` 更短
			# （首波更早出击）和后续再派间隔更短，而不是先躺两分钟。
			first_wave_delay_s = 0.0
			attack_wave_delay_s = 25.0
			re_dispatch_interval_s = 8.0
		_:
			pass


## 战局模拟毫秒（**树暂停时不增加**）。
## AI 的所有时间门槛都必须走这里，不能用 `Time.get_ticks_msec()`：后者是实时时钟，
## 暂停、卡顿、断点调试都会让门槛漂移，导致"同一局在不同机器上首波时间不同"。
func simulation_msec() -> int:
	if _match != null and is_instance_valid(_match) and _match.has_method("get_simulation_msec"):
		return int(_match.get_simulation_msec())
	return Time.get_ticks_msec()


## 把"本局电脑玩家人数 → 决策倍率"注入 5 个 Controller（唯一实现见 `AiCadence`）。
## 1 个电脑时倍率 = 1.0，行为与从前完全一致。
func _apply_refresh_cadence():
	var cadence := AiCadence.scale(self)
	for controller in [
		_economy_controller,
		_defense_controller,
		_offense_controller,
		_intelligence_controller,
		_construction_works_controller,
	]:
		controller.refresh_scale = cadence


## 全局战场扫描（按物理帧缓存，唯一实现）。
## 半径取 `GLOBAL_DEMO_SCAN_RADIUS_M` 时结果与"以谁为中心"无关 —— 就是全场可见实体，
## 所以同一物理帧内的所有消费者（每个作战编组）共用一次查询。
## 用户 2026-09-15 批准：一局 3 个电脑时"每个编组各扫一次全场"是每拍最贵的重复开销。
func battlefield_scan() -> Array:
	var frame := Engine.get_physics_frames()
	if frame == _battlefield_scan_frame:
		return _battlefield_scan_result
	_battlefield_scan_frame = frame
	_battlefield_scan_result = []
	if _world_query_runtime == null:
		return _battlefield_scan_result
	var result: Dictionary = _world_query_runtime.ScanCircle(
		_query_session_id,
		Vector3.ZERO,
		GLOBAL_DEMO_SCAN_RADIUS_M,
		FIELD_POSITION | FIELD_TYPE | FIELD_RELATION
	)
	if result.get("status", "") != "Accepted":
		push_warning("rule AI battlefield scan was rejected: %s" % result)
		return _battlefield_scan_result
	_battlefield_scan_result = result.get("entities", [])
	return _battlefield_scan_result


## DefenseController 上报基地威胁；30s 内视为持续有效（防抖动）。
func notify_base_threat(position: Vector3):
	_base_threat_position = position
	_base_threat_until_ms = Time.get_ticks_msec() + int(defense_recall_min_s * 1000.0)


## DefenseController 连续多轮未发现敌人后解除威胁。
func clear_base_threat():
	_base_threat_position = Vector3.INF
	_base_threat_until_ms = 0


## 当前有效威胁位置；无威胁返回 Vector3.INF。
func get_base_threat() -> Vector3:
	if _base_threat_position != Vector3.INF and Time.get_ticks_msec() < _base_threat_until_ms:
		return _base_threat_position
	return Vector3.INF


## 单人测试局中，AI 只执行经济/建造/生产，不主动发动攻击。
func is_passive_test_ai() -> bool:
	return NetSession.passive_ai_test_server or NetSession.passive_ai_test
