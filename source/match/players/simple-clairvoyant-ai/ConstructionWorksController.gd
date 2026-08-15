extends Node

const FIELD_TYPE := 1 << 1
const FIELD_CONSTRUCTION := 1 << 4
const REFRESH_INTERVAL_S := 1.0 / 60.0 * 30.0

var _world_query_runtime = null
var _query_session_id := ""
var _command_gateway = null


## 绑定只读观察会话和固定玩家身份的规则 AI 命令适配器。
func setup(world_query_runtime, query_session_id: String, command_gateway):
	_world_query_runtime = world_query_runtime
	_query_session_id = query_session_id
	_command_gateway = command_gateway
	_setup_refresh_timer()


func _setup_refresh_timer():
	var timer = Timer.new()
	add_child(timer)
	timer.timeout.connect(_on_refresh_timer_timeout)
	timer.start(REFRESH_INTERVAL_S)


## 为尚无活动建造者的随机己方蓝图分配一名随机 Worker。
func _on_refresh_timer_timeout():
	var result: Dictionary = _world_query_runtime.GetOwnForces(
		_query_session_id,
		FIELD_TYPE | FIELD_CONSTRUCTION
	)
	if result.get("status", "") != "Accepted":
		push_warning("rule AI force query was rejected: %s" % result.get("error", "Unknown"))
		return
	var workers: Array = result["entities"].filter(
		func(entity): return entity.get("type_id", "") == "worker"
	)
	var construction_sites: Array = result["entities"].filter(
		func(entity):
			var construction = entity.get("construction", null)
			return (
				construction != null
				and construction.get("state", "") == "UnderConstruction"
			)
	)
	if construction_sites.any(
		func(entity): return entity["construction"].get("active_builder_count", 0) > 0
	):
		return
	var unattended_sites: Array = construction_sites.filter(
		func(entity): return entity["construction"].get("active_builder_count", 0) == 0
	)
	if workers.is_empty() or unattended_sites.is_empty():
		return
	var worker: Dictionary = workers.pick_random()
	var construction_site: Dictionary = unattended_sites.pick_random()
	var command_result: Dictionary = _command_gateway.Construct(
		[worker["id"]],
		construction_site["id"]
	)
	if command_result.get("status", "Rejected") == "Rejected":
		push_warning("规则 AI 分配施工任务被拒绝：%s" % command_result)
