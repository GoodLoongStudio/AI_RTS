extends Node

const FIELD_POSITION := 1 << 0
const FIELD_TYPE := 1 << 1
const FIELD_CONSTRUCTION := 1 << 4
const REFRESH_INTERVAL_S := 1.0 / 60.0 * 30.0
## 每座工地目标的在岗工人数。1 = 先保证每座工地都有人（修复"有人就全局退出"的关键），
## 后续可按工地优先级/紧迫度提高到 2。
const BUILDERS_PER_SITE_TARGET := 1

## 决策节奏倍率：由 SimpleClairvoyantAI 按"本局电脑玩家人数"注入（唯一实现见 AiCadence）。
## 默认 1.0 = 原始节奏；3 个电脑时为 2.0（0.5s → 1.0s）。
var refresh_scale := 1.0

var _world_query_runtime = null
var _query_session_id := ""
var _command_gateway = null
## worker_id → site_id：**跨拍持久**的派工记忆（2026-09-21 修"工人永远建不完"）。
var _assignments := {}


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
	timer.start(REFRESH_INTERVAL_S * refresh_scale)


## 为尚无活动建造者的随机己方蓝图分配一名随机 Worker。
func _on_refresh_timer_timeout():
	var result: Dictionary = _world_query_runtime.GetOwnForces(
		_query_session_id,
		FIELD_POSITION | FIELD_TYPE | FIELD_CONSTRUCTION
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
	# 【2026-09-17 修复确定缺陷】原实现：只要**任意一个**工地已有工人在建，就 `return`
	# 退出**整个**分配 ⇒ 第二座及以后的工地永远排不到人，产能迟迟建不起来
	# （方案第 1 节表）。改为逐工地独立派工：每座工地各自判断在岗缺口，
	# 取**最近**且本拍尚未派出的工人；已派出的工人不再重复派（避免反复改任务）。
	#
	# 【2026-09-21 修复"工人永远建不完"】`dispatched` 原先只在**本轮**有效：上一拍派给
	# 工地 A 的工人，下一拍会被缺人的工地 B 当"空闲工人"抢走（A 的在岗数随即归零，
	# 再下一拍又抢回 A）⇒ 两座工地互相抢同一个工人，谁都在路上、谁都不建成
	# （实测工人 30 秒内被改派 20+ 次，位移只有几米）。改为**跨拍记住**每个工人的工地，
	# 且仅在该工地确实仍有在岗工人时继续保护；工地消失或在岗归零（被别的控制器抽走）
	# 时立即释放记忆，让工人可被重新派工——既不抢，也不永久占死。
	if workers.is_empty() or construction_sites.is_empty():
		return
	var active_by_site := {}
	for site in construction_sites:
		active_by_site[str(site["id"])] = int(site["construction"].get("active_builder_count", 0))
	for worker_id in _assignments.keys():
		var held_site: String = _assignments[worker_id]
		if not active_by_site.has(held_site) or active_by_site[held_site] < 1:
			_assignments.erase(worker_id)
	var dispatched := {}
	for site in construction_sites:
		var active: int = active_by_site[str(site["id"])]
		if active >= BUILDERS_PER_SITE_TARGET:
			continue
		var best_worker: Dictionary = {}
		var best_distance := INF
		for candidate in workers:
			var candidate_id := str(candidate["id"])
			if dispatched.has(candidate_id):
				continue
			if _assignments.has(candidate_id):
				continue
			var pa: Vector3 = candidate.get("position", Vector3.INF)
			var pb: Vector3 = site.get("position", Vector3.INF)
			var distance := (
				pa.distance_squared_to(pb) if (pa != Vector3.INF and pb != Vector3.INF) else 0.0
			)
			if distance < best_distance:
				best_distance = distance
				best_worker = candidate
		if best_worker.is_empty():
			break
		dispatched[str(best_worker["id"])] = true
		_assignments[str(best_worker["id"])] = str(site["id"])
		var command_result: Dictionary = _command_gateway.Construct(
			[best_worker["id"]],
			site["id"]
		)
		if command_result.get("status", "Rejected") == "Rejected":
			push_warning("规则 AI 分配施工任务被拒绝：%s" % command_result)
