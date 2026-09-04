extends "res://source/match/players/Player.gd"

enum ResourceRequestPriority { LOW, MEDIUM, HIGH }
enum OffensiveStructure { VEHICLE_FACTORY, AIRCRAFT_FACTORY }
enum Difficulty { EASY, NORMAL, HARD }

## 旧参数（保留兼容既有测试与场景）；实际工人目标由 CC 数 × workers_per_command_center 推导。
@export var expected_number_of_workers = 3
@export var expected_number_of_ccs = 1
@export var expected_number_of_ag_turrets = 1
@export var expected_number_of_aa_turrets = 1
@export var primary_offensive_structure = OffensiveStructure.VEHICLE_FACTORY
@export var secondary_offensive_structure = OffensiveStructure.AIRCRAFT_FACTORY
@export var expected_number_of_battlegroups = 3
@export var expected_number_of_units_in_battlegroup = 6

## —— 智能化改造新增参数（见 docs/plan/AI-plan.md Part A）——
## 条件扩张：CC 数上限（0 = 永不扩张，保持旧口径 expected_number_of_ccs）。
@export var max_command_centers = 3
## 每座 CommandCenter 的目标工人数（实际目标 = 现有 CC 数 × 该值）。
@export var workers_per_command_center = 6
## 扩张门槛：resource_a（钱）余额 ≥ 此值才请求开分矿（占位值，按实测标定）。
@export var expansion_resource_threshold = 10
## 编组存活低于 满编 × retreat_threshold 时整编撤退回主基地。
@export var retreat_threshold = 0.5
## 第一波出击延迟（秒）；0 = 满编即出击（旧口径）。难度分级会覆盖。
@export var first_wave_delay_s = 0.0
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
	# 专用服默认 EASY: NORMAL 档首波太凶且经济碾压, 新手对局必输(2026-08-31 实测)。
	if NetSession.dedicated_server and difficulty == Difficulty.NORMAL:
		difficulty = Difficulty.EASY
	_apply_difficulty_profile()
	if NetSession.e2e_peaceful_server:
		first_wave_delay_s = 600.0
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
		while (
			not _resource_requests[priority].is_empty()
			and _has_resources(_resource_requests[priority].front()["resources"])
		):
			var resource_request = _resource_requests[priority].pop_front()
			_provision(
				resource_request["controller"],
				resource_request["resources"],
				resource_request["metadata"]
			)
		if (
			not _resource_requests[priority].is_empty()
			and not _has_resources(_resource_requests[priority].front()["resources"])
		):
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
			first_wave_delay_s = 240.0
		Difficulty.HARD:
			workers_per_command_center = 8
			expected_number_of_battlegroups = 3
			expected_number_of_units_in_battlegroup = 6
			retreat_threshold = 0.6
			first_wave_delay_s = 120.0
		_:
			pass


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
