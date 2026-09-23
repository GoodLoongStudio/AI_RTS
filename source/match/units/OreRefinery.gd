extends "res://source/match/units/Structure.gd"

## 矿场（2026-09-23 用户口径"专门造矿场指派工人去采矿"，红警2 式）。
##
## 行为契约（游戏侧权威，副官不再逐工人下采集令）：
## ① 建成后每隔 CLAIM_INTERVAL_S 把**空闲工人**指派到本矿场（带容量上限）；
##    指派 = 设 meta + 下一个"到矿场报到"的移动；到了以后自动采集恢复，
##    采的是矿场服务半径内的矿、交货回本矿场（见 CollectingResourcesSequentially）；
## ② 绝不抢有显式订单的工人（施工/玩家或副官命令/交火一律不碰）；
## ③ 矿场没了 → 解除全部指派，工人回退"基地采集"既有行为；
## ④ 指派是软约束：被显式订单打断后不反抗，等下一次空闲再接管。

const CLAIM_INTERVAL_S := 2.0
## 每座矿场同时指派的工人上限（红警2 一台精炼厂 2~4 个 harvest 的经济节奏）。
const CAPACITY := 4
## 服务半径：只统计距矿场这么近的矿点（工人到矿场附近干活，不四散）。
const SERVICE_RADIUS_M := 30.0
## 指派标记写在工人节点上的 meta 键（值是本矿场节点）。
const ASSIGNMENT_META := "ore_refinery_assignment"

var _claim_timer: Timer = null
var _assigned: Array = []


func _ready():
	super()
	_claim_timer = Timer.new()
	_claim_timer.wait_time = CLAIM_INTERVAL_S
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
	return SERVICE_RADIUS_M


func assigned_workers() -> Array:
	return _assigned


func _exit_tree():
	_release_all()


## 解除全部指派（矿场被卖/被打掉时工人回退基地采集）。
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
	if _assigned.size() >= CAPACITY:
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
		if _assigned.size() >= CAPACITY:
			return
		_assign(worker)


## 已指派工人的监护：到了矿场附近若闲住，就恢复自动采集（移动订单结束后
## AutoGathering 不会自己回来，必须有人重新挂上）。
func _supervise_assigned():
	for worker in _assigned:
		if not is_instance_valid(worker):
			continue
		var action = worker.get("action")
		if action == null:
			if worker.has_method("request_legacy_start_auto_gather"):
				worker.request_legacy_start_auto_gather()
			continue
		var action_name := ""
		if action.get_script() != null:
			action_name = str(action.get_script().resource_path).get_file()
		if action_name == "AutoGatheringResources.gd":
			continue  # 已在本地采集循环里
		if action_name == "Moving.gd":
			continue  # 正在走来矿场的路上
		# 其它（施工/显式采集/交战）：显式订单优先，不干预。


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


func _assign(worker):
	worker.set_meta(ASSIGNMENT_META, self)
	_assigned.append(worker)
	# "到矿场报到"：派到**服务半径内最近的可用矿点**旁边（站在矿点外侧一点），
	# 不是矿场旁边——贴着建筑避让圈站会被每帧推回、原地抖（2026-09-23 实测），
	# 而矿点外侧是稳定落点；到了以后 AutoGathering 自然会采这块矿。
	var target: Variant = _nearest_ore_stand(worker)
	if target != null and worker.has_method("request_legacy_move"):
		worker.request_legacy_move(target)
	print("[REFINERY] %s 指派工人 %s 到矿场采矿（%d/%d） ore=%s" % [
		name, worker.name, _assigned.size(), CAPACITY, target])


## 服务半径内最近的可用矿点 + 站在它外侧的偏移点；没有可用矿返回 null。
func _nearest_ore_stand(worker) -> Variant:
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
			global_position * Vector3(1, 0, 1))
		if distance > SERVICE_RADIUS_M or distance >= best_distance:
			continue
		best_distance = distance
		best = resource
	if best == null:
		return null
	# 站在**矿点背向矿场的一侧**：朝矿场那一侧是建筑避让圈，站过去会被每帧
	# 推回（2026-09-23 实测工人在圈界原地抖）；背向一侧既贴近可采又稳定。
	var away: Vector3 = (best.global_position - global_position) * Vector3(1, 0, 1)
	if away.length() < 0.1:
		away = (worker.global_position - best.global_position) * Vector3(1, 0, 1)
	if away.length() < 0.1:
		away = Vector3.FORWARD
	var stand_off: float = float(best.get("radius")) + float(worker.get("radius")) + 0.4
	var stand: Vector3 = best.global_position + away.normalized() * stand_off
	stand.y = best.global_position.y
	return stand
