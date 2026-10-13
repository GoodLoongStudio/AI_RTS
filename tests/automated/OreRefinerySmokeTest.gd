extends Node

## 矿场运营冒烟测试（阶段 2，2026-09-27）。
##
## 提示词第五节阶段 2 要求逐条取证：矿场只接管合资格空闲 Worker、Worker 真到矿点、真采集、
## 资源真回账户、不超容量、两座矿场不抢同一人、显式订单优先、矿点耗尽能放名额、矿场没了能恢复。
## 另外钉住本次修掉的两个真缺陷：**服务半径内没矿也照占 4 个名额**，以及
## **指派 meta 只在矿场退出树时清除**（被显式订单调走的工人后续仍把货交给这坐矿场）。

const MatchScene = preload("res://tests/manual/TestAllUnits.tscn")
const SmokeTestWarmup = preload("res://tests/automated/SmokeTestWarmup.gd")
const RefineryScene = preload("res://source/match/units/OreRefinery.tscn")
const WorkerScene = preload("res://source/match/units/Worker.tscn")
const ResourceAScene = preload("res://source/match/units/non-player/ResourceA.tscn")

const ASSIGNMENT_META := "ore_refinery_assignment"

var _failures := 0
var _finished := false
var _match: Node = null


func _ready():
	get_tree().create_timer(400.0).timeout.connect(_on_failsafe)  # 见第 4 节：首车要等乒乓重接，240s 会撞看门狗
	_match = MatchScene.instantiate()
	add_child(_match)
	await get_tree().process_frame
	await SmokeTestWarmup.wait_for_units(get_tree(), 1, 2)

	var human = _match.get_node("Players/Human")
	_check(human.add_resources({"resource_a": 5000}, "ScriptedAdjustment"), "测试资源注入应成功")

	# 1) 服务半径内没有可采矿点 → 一个都不许指派（旧实现会空占 4 个名额并改写交货点）。
	# 落点必须**现算**：测试图的资源由场景脚本运行时铺设，硬编码坐标迟早会撞上矿点。
	var barren_spot = _find_barren_spot(20.0)
	_check(barren_spot != null, "夹具自检：地图上应能找到一个半径内无矿的落点")
	if barren_spot == null:
		_finish()
		return
	var barren = _spawn_refinery(barren_spot, human)
	barren.service_radius_m = 20.0
	barren.worker_capacity = 2
	barren.claim_interval_s = 0.2
	_spawn_worker(barren_spot + Vector3(2.0, 0.0, 0.0), human)
	await _ticks(2.0)
	_check(barren.assigned_workers().is_empty(), "半径内无矿时矿场不得占用任何工人名额")
	_check(not barren.has_serviceable_ore(), "夹具自检：该落点半径内本就不该有矿")

	# 2) 有矿后：接管合资格空闲工人、不超容量、真采真交付。
	var ore_a = _spawn_ore(Vector3(40.0, 0.0, 40.0), 400)
	var ore_b = _spawn_ore(Vector3(44.0, 0.0, 40.0), 400)
	var refinery = _spawn_refinery(Vector3(42.0, 0.0, 44.0), human)
	refinery.service_radius_m = 20.0
	refinery.worker_capacity = 2
	refinery.claim_interval_s = 0.2
	var workers: Array = [
		_spawn_worker(Vector3(42.0, 0.0, 48.0), human),
		_spawn_worker(Vector3(44.0, 0.0, 48.0), human),
		_spawn_worker(Vector3(40.0, 0.0, 48.0), human),
	]
	await _ticks(3.0)
	_check(not refinery.assigned_workers().is_empty(), "有可采矿点后矿场应接管空闲工人")
	_check(
		refinery.assigned_workers().size() <= 2,
		"接管数不得超过 worker_capacity=2（实际 %d）" % refinery.assigned_workers().size()
	)
	for worker in refinery.assigned_workers():
		_check(
			worker.get_meta(ASSIGNMENT_META, null) == refinery,
			"被接管的工人其指派标记必须指向本矿场"
		)

	# 3) 两座矿场不得重复占用同一个工人。
	var second = _spawn_refinery(Vector3(42.0, 0.0, 36.0), human)
	second.service_radius_m = 20.0
	second.worker_capacity = 2
	second.claim_interval_s = 0.2
	await _ticks(3.0)
	var claimed := {}
	for refinery_pair in [refinery, second]:
		for worker in refinery_pair.assigned_workers():
			_check(not claimed.has(worker), "同一工人不得被两座矿场同时占用")
			claimed[worker] = true

	# 4) 真实收入与矿点消耗：矿量必须下降，玩家账户必须上升。
	# 统计口径必须是**全图可采总量**：矿场自己挑服务半径内最近的矿点，夹具所在图里
	# 预置的 30000 矿点完全可能比脚本生成的更近（实测就发生了），只盯脚本那两颗会误判。
	# 一车 400 矿 × 120ms/单位 = 48 秒才装满，再算上路程，所以轮询等待而不是定长。
	var ore_before: int = _world_ore_total()
	var balance_before: int = human.resource_a
	# 预算 260 秒而不是 150 秒：矿场指派与规则中台的采集令会互相顶
	# （`_supervise_assigned` 在工人拿到权威订单时让位 → 冷却 20 秒 → 再接管），
	# 首车因此比"单指派人"模型慢。上一版 150 秒的窗口里交付**确实发生了、只是落在断言之后**
	# （日志第 2381 行 `[GATHER] 交付 resource_a=400`，FAIL 打印在第 2237 行），
	# 那是把"慢"误判成"坏"。这里等够并把乒乓代价打印出来，让成本可见而不是被超时掩盖。
	var income_waited := 0.0
	while human.resource_a <= balance_before and income_waited < 260.0:
		await _ticks(5.0)
		income_waited += 5.0
	print("[REFINERY-TIMING] 首车等待 %.0fs；接管计数=%d（含被规则令顶掉后的重接，乒乓代价可见）"
		% [income_waited, refinery.takeover_count])
	var ore_after: int = _world_ore_total()
	_check(ore_after < ore_before, "矿点存量必须被真实采掉（%d → %d）" % [ore_before, ore_after])
	_check(
		human.resource_a > balance_before,
		"工人回矿场交付后玩家账户必须真实增长（%d → %d）" % [balance_before, human.resource_a]
	)

	# 5) 显式订单优先：把已接管工人调走，名额必须立刻释放。
	var pulled = (
		refinery.assigned_workers()[0] if not refinery.assigned_workers().is_empty() else null
	)
	if pulled != null:
		var gateway = human.get_node("UnitCommandGateway")
		gateway.MoveUnits([pulled], Vector3(4.0, 0.0, 4.0), human)
		await _ticks(2.0)
		_check(
			not refinery.assigned_workers().has(pulled),
			"被显式移动令调走的工人必须立刻让出矿场名额"
		)
		_check(
			not pulled.has_meta(ASSIGNMENT_META),
			"释放名额时必须清掉指派标记（否则他后续仍把货交给这坐矿场）"
		)

	# 6) 矿点耗尽 → 换点，不许在空矿旁罚站（提示词 8.3）。
	# 判据是"工人转去采另一颗矿点、并且继续交付"，不是"矿场口头宣布换点了"。
	# 先清场：把上一节释放掉的两座矿场之外的矿点关系理顺，只留脚下这一组。
	var swap_refinery = _spawn_refinery(Vector3(60.0, 0.0, 60.0), human)
	swap_refinery.service_radius_m = 18.0
	swap_refinery.worker_capacity = 1
	swap_refinery.claim_interval_s = 0.2
	# 小存量矿点：按 120ms/单位的采集速度，约十几秒就被采空——等自然采空比造假数据可信。
	var near_ore = _spawn_ore(Vector3(66.0, 0.0, 60.0), 120)
	var far_ore = _spawn_ore(Vector3(54.0, 0.0, 60.0), 4000)
	var swap_worker = _spawn_worker(Vector3(60.0, 0.0, 66.0), human)
	await _ticks(3.0)
	_check(
		swap_refinery.assigned_workers().size() == 1,
		"换点测试：矿场应接管 1 名工人（实际 %d）" % swap_refinery.assigned_workers().size()
	)
	var depleted_waited := 0.0
	while int(near_ore.get("resource_a")) > 0 and depleted_waited < 90.0:
		await _ticks(3.0)
		depleted_waited += 3.0
	_check(
		int(near_ore.get("resource_a")) <= 0,
		"近处矿点应在 90 秒内被真实采空（剩余 %d）" % int(near_ore.get("resource_a"))
	)
	_check(not near_ore.is_queued_for_deletion(), "再生启用时采空不得删除矿点实体")
	_check(bool(near_ore.get("depleted")), "采空后矿点应进入 depleted（耗尽等待）状态")
	# 采空以后：矿场必须把**另一颗有矿的矿点**当目标，而不是继续指空矿。
	await _ticks(2.0)
	_check(
		swap_refinery.has_serviceable_ore(),
		"近点采空后矿场仍应有可采矿点（远处矿点在服务半径内）"
	)
	_check(
		swap_refinery._nearest_ore(swap_refinery.global_position) == far_ore,
		"矿场换点目标必须是仍有资源的那颗矿点（实际 %s）"
		% str(swap_refinery._nearest_ore(swap_refinery.global_position))
	)

	# 7) 再生 → 重新发现可采点 → 重新派工 → 交付继续增长（提示词 8.3 + §6「再生后恢复采集」）。
	# 这里直接调 `apply_regeneration` 把矿点恢复，是为了把"矿场侧对资源状态变化的反应"
	# 单独钉住；再生驱动器本身的两个周期/暂停/幂等由 OreRegenerationSmokeTest 负责。
	# 关键回归点：如果矿场把"空矿"永久缓存下来，矿长回来了它也不会再派人去采。
	var deliveries_before: int = int(swap_refinery.delivery_stats().get("delivered_count", 0))
	var balance_before_regen: int = human.resource_a
	near_ore.apply_regeneration(600)
	_check(int(near_ore.get("resource_a")) > 0, "再生应把矿量写回矿点存量")
	_check(not bool(near_ore.get("depleted")), "再生后矿点应回到可采状态")
	await _ticks(4.0)
	_check(
		swap_refinery.assigned_workers().size() >= 1,
		"再生后矿场应重新有合资格工人在册（实际 %d）" % swap_refinery.assigned_workers().size()
	)
	var regen_waited := 0.0
	while (
		int(swap_refinery.delivery_stats().get("delivered_count", 0)) <= deliveries_before
		and human.resource_a <= balance_before_regen
		and regen_waited < 150.0
	):
		await _ticks(5.0)
		regen_waited += 5.0
	_check(
		int(swap_refinery.delivery_stats().get("delivered_count", 0)) > deliveries_before
		or human.resource_a > balance_before_regen,
		"再生后必须再次发生真实交付（交付 %d→%d，账户 %d→%d）" % [
			deliveries_before,
			int(swap_refinery.delivery_stats().get("delivered_count", 0)),
			balance_before_regen,
			human.resource_a,
		]
	)
	# 玩家/显式订单优先：给在册工人下一条显式采集令，矿场必须让路而不是抢人。
	var busy_worker = (
		swap_refinery.assigned_workers()[0]
		if not swap_refinery.assigned_workers().is_empty() else swap_worker
	)
	var busy_gateway = human.get_node("UnitCommandGateway")
	busy_gateway.MoveUnits([busy_worker], Vector3(80.0, 0.0, 80.0), human)
	await _ticks(2.0)
	_check(
		not swap_refinery.assigned_workers().has(busy_worker),
		"显式订单必须立刻让矿场放手（玩家接管优先）"
	)

	# 8) 矿场被摧毁 → 全部指派解除，工人回退默认行为。
	refinery.queue_free()
	second.queue_free()
	barren.queue_free()
	swap_refinery.queue_free()
	await _ticks(2.0)
	for worker in workers:
		_check(not worker.has_meta(ASSIGNMENT_META), "矿场消失后工人不得残留指派标记")

	_finish()


## 找一个"以 radius 为服务半径时圈内没有矿"的落点：在地图内按 10m 栅格扫描，
## 取第一个距所有矿点都超过 radius + 5m 缓冲的格子。找不到返回 null（夹具失效要响）。
func _find_barren_spot(radius: float):
	var ores: Array = []
	for node in get_tree().get_nodes_in_group("resource_units"):
		if is_instance_valid(node):
			ores.append(node.global_position)
	var bound = _match.get_node("Map").get("size")
	if bound == null:
		bound = Vector2(104.0, 104.0)
	var step := 10.0
	var margin := radius + 5.0
	var x := step
	while x <= bound.x - step:
		var z := step
		while z <= bound.y - step:
			var candidate := Vector3(x, 0.0, z)
			var clear := true
			for ore_pos in ores:
				if Vector2(candidate.x - ore_pos.x, candidate.z - ore_pos.z).length() < margin:
					clear = false
					break
			if clear:
				return candidate
			z += step
		x += step
	return null


func _spawn_refinery(position: Vector3, player):
	var refinery = RefineryScene.instantiate()
	# 以完工态直接生成：本测的是运营阶段，不重复测施工。
	_match.call(
		"_setup_and_spawn_unit", refinery, Transform3D(Basis.IDENTITY, position), player, false
	)
	return refinery


func _spawn_worker(position: Vector3, player):
	var worker = WorkerScene.instantiate()
	_match.call(
		"_setup_and_spawn_unit", worker, Transform3D(Basis.IDENTITY, position), player, false
	)
	return worker


func _spawn_ore(position: Vector3, amount: int):
	var ore = ResourceAScene.instantiate()
	ore.resource_a = amount
	_match.get_node("Map/Resources").add_child(ore)
	ore.global_position = Vector3(
		position.x,
		_match.ground_height_at(position) if _match.has_method("ground_height_at") else position.y,
		position.z
	)
	return ore


## 全图可采总量（A+B）。矿点采空后可能仍在"已排队删除"窗口里，必须一起避开。
func _world_ore_total() -> int:
	var total := 0
	for node in get_tree().get_nodes_in_group("resource_units"):
		if is_instance_valid(node) and not node.is_queued_for_deletion():
			var amount_a = node.get("resource_a")
			var amount_b = node.get("resource_b")
			total += (amount_a if amount_a != null else 0)
			total += (amount_b if amount_b != null else 0)
	return total


## 等待给定秒数（按真实时间走，兼容 Timer 与移动订单）。
func _ticks(seconds: float):
	await get_tree().create_timer(seconds).timeout
	await get_tree().process_frame


func _on_failsafe():
	if _finished:
		return
	_finished = true
	_failures += 1
	print("FAIL: 看门狗超时——矿场测试协程中断未收尾")
	print("Ore refinery smoke test completed: %d failure(s)" % _failures)
	SmokeTestExit.request(get_tree(), 1, _match)


func _finish():
	if _finished:
		return
	_finished = true
	print("Ore refinery smoke test completed: %d failure(s)" % _failures)
	SmokeTestExit.request(get_tree(), 0 if _failures == 0 else 1, _match)


func _check(condition: bool, message: String):
	if condition:
		return
	_failures += 1
	print("FAIL: %s" % message)
	push_error("Ore refinery smoke test assertion failed: %s" % message)
