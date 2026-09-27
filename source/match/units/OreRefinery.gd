extends "res://source/match/units/Structure.gd"

## 矿场（2026-09-23 用户口径"专门造矿场指派工人去采矿"，红警2 式）。
##
## 行为契约（游戏侧权威，副官不再逐工人下采集令）：
## ① 建成后每隔 claim_interval_s 把**空闲工人**指派到本矿场（带容量上限）；
##    指派 = 设 meta + 下一个"到矿场报到"的移动；到了以后自动采集恢复，
##    采的是矿场服务半径内的矿、交货回本矿场（见 CollectingResourcesSequentially）；
## ② 绝不抢有显式订单的工人（施工/玩家或副官命令/交火一律不碰）；
## ③ 矿场没了 → 解除全部指派，工人回退"基地采集"既有行为；
## ④ 指派是软约束：被显式订单打断后不反抗，等下一次空闲再接管，并立刻腾出名额；
## ⑤ 服务半径内没有可采矿点时**一个都不指派**——名额不许空占，工人也不许被改派交货点。

## 真实数值由 BalanceConfigRuntime 从 balance 目录写进来（与 construction_work_per_tick /
## resources_max 同一套口径），不留在脚本里当唯一事实来源。配置可能在本节点 _ready 之后
## 才写入，所以三个 setter 都要能作用到已经跑起来的定时器上。
@export var claim_interval_s := 2.0:
	set(value):
		claim_interval_s = value
		if _claim_timer != null:
			_claim_timer.wait_time = value
## 每座矿场同时指派的工人上限（红警2 一台精炼厂 2~4 个 harvest 的经济节奏）。
@export var worker_capacity := 4
## 服务半径：只统计距矿场这么近的矿点（工人到矿场附近干活，不四散）。
@export var service_radius_m := 30.0
## 指派标记写在工人节点上的 meta 键（值是本矿场节点）。
const ASSIGNMENT_META := "ore_refinery_assignment"

var _claim_timer: Timer = null
var _assigned: Array = []


func _ready():
	super()
	_claim_timer = Timer.new()
	_claim_timer.wait_time = claim_interval_s
	_claim_timer.timeout.connect(_claim_tick)
	add_child(_claim_timer)
	if has_signal("constructed") and not constructed.is_connected(_on_constructed):
		constructed.connect(_on_constructed)
	if is_constructed():
		# 直接以完工态放置（脚本化对局/测试）：_ready 时就已经就绪。
		_claim_timer.start()


func _on_constructed():
	_claim_timer.start()


## 交付点标记：CollectingResourcesSequentially 据此把交货目标从指挥中心扩展到矿场。
func is_drop_off() -> bool:
	return true


func service_radius() -> float:
	return service_radius_m


func assigned_workers() -> Array:
	return _assigned


## 运营结果账（阶段 3 的矿场里程碑与阶段 6 的对局报告都读这里，不看"发过命令"）：
## takeover_count = 累计接管过多少个工人；delivered_* = 实际回本矿场交付的次数与矿量。
var takeover_count := 0
var delivered_count := 0
var delivered_amount := 0


## 由 CollectingResourcesSequentially 在**权威入账成功之后**回调。
func record_delivery(worker, amount: int):
	if amount <= 0:
		return
	delivered_count += 1
	delivered_amount += amount
	print("[REFINERY] %s 收到交付 worker=%s amount=%d（累计 %d 次 / %d 矿）" % [
		name, str(worker.name) if worker != null else "?", amount, delivered_count,
		delivered_amount])


func delivery_stats() -> Dictionary:
	return {
		"constructed": is_constructed(),
		"assigned": _assigned.size(),
		"takeovers": takeover_count,
		"delivered_count": delivered_count,
		"delivered_amount": delivered_amount,
		"service_radius_m": service_radius_m,
		"worker_capacity": worker_capacity,
		"has_ore": has_serviceable_ore(),
	}


func _exit_tree():
	_release_all()


## 解除全部指派（矿场被卖/被打掉、或半径内矿点全部采空时工人回退基地采集）。
func _release_all():
	for worker in _assigned:
		if is_instance_valid(worker) and worker.has_meta(ASSIGNMENT_META):
			worker.remove_meta(ASSIGNMENT_META)
	_assigned.clear()


func _claim_tick():
	if not is_inside_tree() or not is_constructed():
		return
	_assigned = _assigned.filter(func(worker): return is_instance_valid(worker))
	_supervise_assigned()
	# 半径内已经没有可采的矿：先把人全部放回去，别再占名额、也别把人派到没矿的地方。
	if not has_serviceable_ore():
		_release_all()
		return
	if _assigned.size() >= worker_capacity:
		return
	var player := get_parent()
	if player == null:
		return
	var candidates: Array = []
	for unit in get_tree().get_nodes_in_group("units"):
		if unit == null or not is_instance_valid(unit) or unit.get_parent() != player:
			continue
		if str(unit.get("unit_type_id")) != "worker":
			continue
		if unit.has_meta(ASSIGNMENT_META):
			continue
		if not _is_claimable(unit):
			continue
		candidates.append(unit)
	# 近的优先：先把离家近的工人拉过来，别让基地的工人长途奔袭。
	candidates.sort_custom(func(a, b):
		return (a.global_position.distance_squared_to(global_position)
			< b.global_position.distance_squared_to(global_position)))
	for worker in candidates:
		if _assigned.size() >= worker_capacity:
			return
		_assign(worker)


## 服务半径内是否还有**有剩余资源**的矿点。矿点身份由 ResourceUnit 持有，采空即出组。
func has_serviceable_ore() -> bool:
	return _nearest_ore(global_position) != null


## 已指派工人的监护：到了矿场附近若闲住，就恢复自动采集（移动订单结束后
## AutoGathering 不会自己回来，必须有人重新挂上）。
func _supervise_assigned():
	var still_ours: Array = []
	for worker in _assigned:
		if not is_instance_valid(worker):
			continue
		# meta 已被别的矿场或显式命令改走 → 这个名额不再属于我们。
		if not worker.has_meta(ASSIGNMENT_META) or worker.get_meta(ASSIGNMENT_META) != self:
			continue
		var action = worker.get("action")
		var action_name := ""
		if action != null and action.get_script() != null:
			action_name = str(action.get_script().resource_path).get_file()
		if action_name == "AutoGatheringResources.gd":
			still_ours.append(worker)
			continue
		if action_name == "Moving.gd":
			# 矿场自己的报到移动走 `request_legacy_move`，**不建权威订单**；玩家/副官的
			# 显式移动令会建一条。据此区分"正在走来矿场"与"被显式订单调走"——
			# 比对目的地坐标可靠得多（目的地会被导航吸附，误差可达数米，
			# 用目的地判会每轮误释放、反复重派，工人一步都走不到矿点）。
			if _has_authoritative_order(worker):
				worker.remove_meta(ASSIGNMENT_META)
			else:
				still_ours.append(worker)
			continue
		if action == null:
			still_ours.append(worker)
			if worker.has_method("request_legacy_start_auto_gather"):
				worker.request_legacy_start_auto_gather()
			continue
		# 其它（施工/显式采集/交战）：显式订单优先，不干预，但**立刻腾出名额**。
		worker.remove_meta(ASSIGNMENT_META)
	_assigned = still_ours


## 工人身上是否挂着权威订单（显式命令的标志）。取不到网关时按"没有订单"处理：
## 宁可多留一个指派，也不要误释放后反复重派把工人钉在原地。
func _has_authoritative_order(worker) -> bool:
	var owner = worker.get_parent()
	if owner == null:
		return false
	var gateway = owner.get_node_or_null("UnitCommandGateway")
	if gateway == null or not gateway.has_method("GetActiveOrderState"):
		return false
	return not str(gateway.GetActiveOrderState(worker)).is_empty()


## 可指派判据：只在**自动行为**中的工人才拉走（采集循环/空闲），
## 显式订单（Moving/Constructing/Collecting…/交火）一律不碰。
func _is_claimable(unit) -> bool:
	var action = unit.get("action")
	if action == null:
		return true
	if action.get_script() == null:
		return true
	var action_name := str(action.get_script().resource_path).get_file()
	return action_name == "AutoGatheringResources.gd"


## 指派一名工人；**只有真的找到可采的矿点才算占一个名额**（旧实现无矿也占，
## 4 个槽位被空挂，还把这些工人的交货点改指到远处矿场）。
func _assign(worker):
	var target: Variant = _nearest_ore_stand(worker)
	if target == null:
		return
	worker.set_meta(ASSIGNMENT_META, self)
	_assigned.append(worker)
	# "到矿场报到"：派到**服务半径内最近的可用矿点**旁边（站在矿点外侧一点），
	# 不是矿场旁边——贴着建筑避让圈站会被每帧推回、原地抖（2026-09-23 实测），
	# 而矿点外侧是稳定落点；到了以后 AutoGathering 自然会采这块矿。
	if worker.has_method("request_legacy_move"):
		worker.request_legacy_move(target)
	print("[REFINERY] %s 指派工人 %s 到矿场采矿（%d/%d） ore=%s" % [
		name, worker.name, _assigned.size(), worker_capacity, target])


## 服务半径内距 from 最近的可用矿点；没有可用矿返回 null。
func _nearest_ore(from: Vector3) -> Variant:
	var best = null
	var best_distance := INF
	for resource in get_tree().get_nodes_in_group("resource_units"):
		if not is_instance_valid(resource):
			continue
		var a = resource.get("resource_a")
		var b = resource.get("resource_b")
		var has_a: bool = a != null and int(a) > 0
		var has_b: bool = b != null and int(b) > 0
		if not (has_a or has_b):
			continue
		var distance: float = (resource.global_position * Vector3(1, 0, 1)).distance_to(
			from * Vector3(1, 0, 1))
		if distance > service_radius_m or distance >= best_distance:
			continue
		best_distance = distance
		best = resource
	return best


## 最近的可用矿点 + 站在它外侧的偏移点；没有可用矿返回 null。
func _nearest_ore_stand(worker) -> Variant:
	var best = _nearest_ore(global_position)
	if best == null:
		return null
	# 站在**矿点背向矿场的一侧**：朝矿场那一侧是建筑避让圈，站过去会被每帧
	# 推回（2026-09-23 实测工人在圈界原地抖）；背向一侧既贴近可采又稳定。
	var away: Vector3 = (best.global_position - global_position) * Vector3(1, 0, 1)
	if away.length() < 0.1:
		away = (worker.global_position - best.global_position) * Vector3(1, 0, 1)
	if away.length() < 0.1:
		away = Vector3.FORWARD
	var direction := away.normalized()
	var stand_off: float = float(best.get("radius")) + float(worker.get("radius")) + 0.4
	var stand: Vector3 = best.global_position + direction * stand_off
	# 报到点还必须**走出矿场自己的避让圈**：只按矿点半径算时，矿点离矿场比矿场 footprint
	# 更近（OreRefinery 的 MovementObstacle radius=6.0）会让工人永远走不进去、被每帧推回
	# 原地抖，实测表现为"指派了、也在 Moving，但一百多秒都到不了矿点"。
	var clearance := float(radius) + float(worker.get("radius")) + 0.6
	var pushes := 0
	while stand.distance_squared_to(global_position) < clearance * clearance and pushes < 32:
		stand += direction * 0.5
		pushes += 1
	stand.y = best.global_position.y
	return stand
