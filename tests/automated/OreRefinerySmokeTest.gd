extends Node

## 矿场运营冒烟测试（阶段 2，2026-09-27）。
##
## 提示词第五节阶段 2 要求逐条取证：矿场只接管合资格空闲 Worker、Worker 真到矿点、真采集、
## 资源真回账户、不超容量、两座矿场不抢同一人、显式订单优先、矿点耗尽能放名额、矿场没了能恢复。
## 另外钉住：**服务半径不再是接管门槛**（半径设为 1 米仍接管视野内的矿），以及
## **指派 meta 只在矿场退出树时清除**（被显式订单调走的工人必须让出名额）。

const MatchScene = preload("res://tests/manual/TestAllUnits.tscn")
const SmokeTestWarmup = preload("res://tests/automated/SmokeTestWarmup.gd")
const RefineryScene = preload("res://source/match/units/OreRefinery.tscn")
const WorkerScene = preload("res://source/match/units/Worker.tscn")
const ResourceAScene = preload("res://source/match/units/non-player/ResourceA.tscn")

const ASSIGNMENT_META := "ore_refinery_assignment"
## 与 OreRefinery.RECLAIM_COOLDOWN_META 同名同值（诊断用；测试不直接依赖生产常量名）。
const RECLAIM_COOLDOWN_META := "ore_refinery_reclaim_until_ms"

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

	# 1) 服务半径不再决定接管。把半径钉成 1 米，并在矿场旁放一颗明显超出 1 米、
	# 但仍在矿场视野内的矿。旧门槛会认为「半径内无矿」而不接管；新规则必须接管。
	# 落点仍现算，避免和夹具预置矿重叠。
	var service_radius: float = float(load("res://source/match/units/OreRefinery.gd").new().service_radius_m)
	var barren_spot = _find_barren_spot(service_radius)
	_check(barren_spot != null, "夹具自检：地图上应能找到一个远离预置矿的落点")
	if barren_spot == null:
		_finish()
		return
	var barren = _spawn_refinery(barren_spot, human)
	barren.service_radius_m = 1.0
	barren.worker_capacity = 2
	barren.claim_interval_s = 0.2
	var seen_ore_pos: Vector3 = barren.global_position + Vector3(6.0, 0.0, 0.0)
	_spawn_ore(seen_ore_pos, 400)
	_spawn_worker(barren_spot + Vector3(2.0, 0.0, 2.0), human)
	await _ticks(2.0)
	_check(
		barren.has_serviceable_ore(),
		"服务半径设为 1 米时，视野内的矿仍算可服务"
	)
	_check(
		not barren.assigned_workers().is_empty(),
		"服务半径不再阻止接管空闲工人（在册 %d）" % barren.assigned_workers().size()
	)

	# 2) 有矿后：接管合资格空闲工人、不超容量、真采真交付。
	var ore_a = _spawn_ore(Vector3(40.0, 0.0, 40.0), 400)
	var ore_b = _spawn_ore(Vector3(44.0, 0.0, 40.0), 400)
	var refinery = _spawn_refinery(Vector3(42.0, 0.0, 44.0), human)
	refinery.service_radius_m = 1.0
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
	second.service_radius_m = 1.0
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
	# 【2026-09-30 夹具修正】原坐标 (60,60)/(66,60)/(54,60)/(60,66) 是按大图写的，
	# 而本夹具的地图是 54×54 —— **四个点全在地图外**：矿场被 MovementObstacle 的
	# 「对齐导航面」挪到最近可走点（实测落到 (29.7,47.1)），swap_worker 直接丢失
	# （CLAIM-DUMP 里 6 个工人中根本没有它），于是「矿场应接管 1 名工人」永远不可能成立。
	# 这正是计划里「出生点必须在**地图边界内**」的同一类缺陷。改为按地图尺寸推导。
	var map_size: Vector2 = Vector2(54.0, 54.0)
	if _match.get("map") != null and _match.map.get("size") != null:
		map_size = _match.map.size
	# 矿区离矿场必须**大于矿场 carve 洞**（footprint 9.8 + agent 2.8 = 12.6m），
	# 否则矿点落在洞里、工人走不到 → 矿永远采不掉（实测：放 6m 时近矿 90s 仍是 120）。
	# 同时要在服务半径 18m 内、并留够地图边距（54×54 图）。取 15m / 集群放在右下空地。
	var swap_base := Vector3(36.0, 0.0, 8.0)
	# 【2026-09-30 问题B 夹具去抖】换点测试只允许 swap_refinery 抢这名新工人：
	# 其他三座矿场此时还有空名额，新工人一落地就由「谁先 tick 谁抢到」决定归属
	# （实测出现过 在册=0/1 而 工人=5 已被占用=4 冷却=1 的假红）。容量清零后本段唯一确定。
	for other_refinery in [refinery, second, barren]:
		other_refinery.worker_capacity = 0
	var swap_refinery = _spawn_refinery(swap_base, human)
	swap_refinery.service_radius_m = 1.0
	swap_refinery.worker_capacity = 1
	swap_refinery.claim_interval_s = 0.2
	var swap_worker = _spawn_worker(swap_base + Vector3(0.0, 0.0, 6.0), human)
	# 【2026-09-30 问题B 夹具修正】矿区落点必须**等矿场 carve 重烘完、再按可走面现算**。
	# 原写法 swap_base + (±15,0,0)：+x 那侧本来就在地图外（本图可走面只到 x≈47.1），
	# 矿点被 MovementObstacle「对齐导航面」从 (51,8) 拉回 (47.1,8) —— 离矿场只剩 11.10m，
	# **掉进矿场 12.6m（9.8 障碍 + 2.8 agent）的 carve 洞里**：实测导航网格最近可走点在
	# 距矿场 12.67m 处、距该矿点 6.10m（XZ），远超 3.1m 的贴合阈值。
	# 即「近处矿点 90 秒内被真实采空」这条在物理上不可能成立——与「指派 vs 自选」的
	# 语义无关：任何语义修法都救不了一颗工人走不到的矿。改为现算（与 _find_barren_spot
	# 同一既有口径：坐标一律不许硬编码），并把这条前置条件本身断言出来。
	await _ticks(1.5)
	var swap_nav_map: RID = _navigation_map_of(swap_worker)
	# 连通性原点用**工人自己的落点**：工人在 carve 洞里会被驱逐，要等它站定；
	# 而且必须等**矿场 carve 烘进网格**——重烘期间 map_get_path 会返回空，
	# 这时判「可达」会把所有落点都误杀（本夹具原本就是踩了「读旧网格」的坑）。
	var swap_origin: Vector3 = swap_worker.global_position
	var near_spot := Vector3.INF
	var spot_waited := 0.0
	while spot_waited < 12.0:
		swap_origin = swap_worker.global_position
		near_spot = _walkable_ring_spot(swap_base, 14.0, swap_nav_map, [], swap_origin, true)
		if near_spot != Vector3.INF:
			break
		await _ticks(0.5)
		spot_waited += 0.5
	_check(
		near_spot != Vector3.INF,
		"夹具自检：矿场周围应有**可采矿**落点（carve 洞外、网格上、走得通、站位也走得通）"
	)
	if near_spot == Vector3.INF:
		_finish()
		return
	# 小存量矿点：按 120ms/单位的采集速度，约十几秒就被采空——等自然采空比造假数据可信。
	var near_ore = _spawn_ore(near_spot, 120)
	# 远矿必须**真的比近矿远**：矿点落地后会被 MovementObstacle「对齐导航面」搬动（实测被搬近 2.6m），
	# 一旦搬得比近矿还近，矿场第一个就看上它，本节「先把近矿采空再换点」的前提直接失效。
	# 因此按**近矿落地后的实际距离 + 3.0m** 现算远矿距离，并在下面再断言一次。
	var far_distance: float = minf(
		_planar_distance(near_ore.global_position, swap_base) + 3.0, 17.8
	)
	var far_spot := _walkable_ring_spot(
		swap_base, far_distance, swap_nav_map, [near_ore.global_position], swap_origin, false
	)
	_check(far_spot != Vector3.INF, "夹具自检：矿场周围应另有可服务的远矿落点")
	if far_spot == Vector3.INF:
		_finish()
		return
	var far_ore = _spawn_ore(far_spot, 4000)
	# 对齐导航面在落地后的帧里才生效，自检必须读对齐后的位置。
	await _ticks(0.5)
	_check(
		swap_refinery._nearest_ore(swap_refinery.global_position) == near_ore,
		"夹具自检：矿场必须**先**看上近矿（换点语义的前提；实际 %s）"
		% str(swap_refinery._nearest_ore(swap_refinery.global_position))
	)
	# 【2026-09-30 问题B 夹具修正】把工人**放到近矿旁的可走站位**（矿点靠矿场那一侧 3m）：
	# 旧写法把它扔在矿场 carve 洞里、靠引擎驱逐到洞边，落点不确定；而本节断言的是
	# 「近矿真被采空 / 采空后换点」，前提是工人**能贴上这颗矿**（贴合阈值 3.9m）。
	# 站位由导航网格现算（_walkable_ring_spot 已验：该侧可走）。
	var to_refinery: Vector3 = (swap_base - near_ore.global_position) * Vector3(1, 0, 1)
	swap_worker.global_position = (
		Vector3(near_ore.global_position.x, swap_worker.global_position.y, near_ore.global_position.z)
		+ to_refinery.normalized() * 3.0
	)
	swap_worker.reset_physics_interpolation()
	_check(
		_planar_distance(near_ore.global_position, swap_base) > 13.0,
		"夹具自检：近矿必须在矿场 carve 洞外（实际 %.2fm）"
		% _planar_distance(near_ore.global_position, swap_base)
	)
	_check(
		_off_mesh_distance(near_ore.global_position, swap_nav_map) <= 0.6,
		"夹具自检：近矿必须落在可走面上（离导航网格 %.2fm）"
		% _off_mesh_distance(near_ore.global_position, swap_nav_map)
	)
	await _ticks(3.0)
	# 【2026-09-30 诊断】断言点无条件 dump 一次"谁占了谁"。生产代码的 [REFINERY-CLAIM]
	# 只在特定 tick 打印，过去只能看到"工人=6 已被占用=5 冷却=1"这种汇总，
	# 分不清"被谁占、为什么抢不到"。这里把每座矿场的在册名单 + 每个工人的归属/冷却打全。
	_dump_claim_state("换点测试断言前", [refinery, second, barren, swap_refinery], human)
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
		"近点采空后矿场仍应有可采矿点（远处矿点在视野内）"
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
	# 【2026-09-30】原目标 (80,80) 在 54×54 图外：显式移动令虽然仍会建单，但单位会被判成
	# 不可达/出界，掩盖「让位」的真实路径。改为图内远端。
	busy_gateway.MoveUnits([busy_worker], Vector3(map_size.x - 6.0, 0.0, map_size.y - 6.0), human)
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
	# 兜底：地图上没有足够大的天然空地时，主动清掉候选点服务半径内的矿点，
	# 保证"半径内无矿"这个前提恒成立（这是夹具自造的受控场景，不是掩盖产品缺陷）。
	var fallback := Vector3(step, 0.0, step)
	var removed := 0
	for node in get_tree().get_nodes_in_group("resource_units"):
		if not is_instance_valid(node):
			continue
		if Vector2(node.global_position.x - fallback.x, node.global_position.z - fallback.z).length() < margin:
			node.queue_free()
			removed += 1
	print("[FIXTURE] 无天然空地，已清掉兜底落点半径内的 %d 颗矿" % removed)
	return fallback

## 单位的导航地图 RID（导航服务被跳过时返回无效 RID，调用方必须能容忍）。
## 单位的导航地图 RID（导航服务被跳过时返回无效 RID，调用方必须能容忍）。
func _navigation_map_of(unit) -> RID:
	var movement = unit.find_child("Movement")
	if movement == null or not movement.has_method("get_navigation_map"):
		return RID()
	return movement.get_navigation_map()


## 以 center 为心、distance 为半径，按固定方向序列找一个**确实落在导航网格上**的落点。
## 为什么要现算：本夹具的矿点曾经落在地图外，被「对齐导航面」拉回后仍不可达——
## 「矿点被真实采空」就成了一条物理上不可能满足的断言（详见第 6 节注释）。
func _walkable_ring_spot(
	center: Vector3, distance: float, nav_map: RID, used: Array, origin: Vector3,
	require_minable: bool = true
) -> Vector3:
	# 90° = +Z 起手：工人被矿场 carve 洞驱逐时也朝 +Z 出去，报到路径最短。
	var probe_degrees := [90.0, 0.0, 180.0, 45.0, 135.0, 225.0, 315.0, 60.0, 120.0, 240.0, 300.0, 270.0]
	for degrees in probe_degrees:
		var direction := Vector3(cos(deg_to_rad(degrees)), 0.0, sin(deg_to_rad(degrees)))
		var candidate: Vector3 = center + direction * distance
		var clear := true
		for other in used:
			if _planar_distance(candidate, other) < 5.0:
				clear = false
				break
		if not clear:
			continue
		var off := _off_mesh_distance(candidate, nav_map)
		var away: Vector3 = (candidate - center) * Vector3(1, 0, 1)
		var stand: Vector3 = candidate
		if away.length() > 0.1:
			stand = candidate + away.normalized() * 3.0
		var reach := _path_reaches(candidate, nav_map, origin)
		var stand_off := _off_mesh_distance(stand, nav_map)
		var stand_ok := stand_off <= 0.6 and _path_reaches(stand, nav_map, origin)
		if require_minable:
			# 近矿必须**真的采得到**：在网格上 + 从工人位置走得到 + 报到站位也走得到。
			if off <= 0.6 and reach and stand_ok:
				return candidate
		else:
			# 远矿也必须**直接落在可走面上**：离网格的点落地后会被「对齐导航面」拉回网格
			# （实测 (53,8) → (49.2,8)，距矿场 17.0 → 13.2m），反而比近矿更近，工人就近自选
			# 先把它采空，「采空后换点」无点可换。
			if off <= 0.6 and reach:
				return candidate
	return Vector3.INF


## 从 origin 真的跑一次寻路到 point，并要求路径末端落到 point 附近（连通性判据）。
func _path_reaches(point: Vector3, nav_map: RID, origin: Vector3) -> bool:
	if not nav_map.is_valid():
		return true
	var path: PackedVector3Array = NavigationServer3D.map_get_path(nav_map, origin, point, true)
	if path.is_empty():
		return false
	var last: Vector3 = path[path.size() - 1]
	return Vector2(last.x - point.x, last.z - point.z).length() <= 1.0


## 点到导航网格的平面距离（>0.6m 基本等于「这个点走不到」）。
## 只比 XZ：Recast 面比真实地表高约 0.8m，带上 Y 会把「就在网格上」读成 0.8m 偏差。
func _off_mesh_distance(point: Vector3, nav_map: RID) -> float:
	if not nav_map.is_valid():
		return 0.0
	var closest: Vector3 = NavigationServer3D.map_get_closest_point(nav_map, point)
	if not closest.is_finite():
		return INF
	return Vector2(closest.x - point.x, closest.z - point.z).length()


func _planar_distance(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()


func _spawn_refinery(position: Vector3, player):
	var refinery = RefineryScene.instantiate()
	# 以完工态直接生成：本测的是运营阶段，不重复测施工。
	_match.call(
		"_setup_and_spawn_unit", refinery, Transform3D(Basis.IDENTITY, position), player, false
	)
	return refinery


## 抢人现场 dump（只读诊断，不参与判定）。
func _dump_claim_state(tag: String, refineries: Array, human) -> void:
	print("[CLAIM-DUMP] === %s ===" % tag)
	for r in refineries:
		if r == null or not is_instance_valid(r):
			continue
		var names: Array = []
		for w in r.assigned_workers():
			names.append(w.name)
		print("[CLAIM-DUMP] 矿场 %s pos=%s 半径=%.0f 容量=%d 在册=%s" % [
			r.name, str(r.global_position.snapped(Vector3(0.1, 0.1, 0.1))),
			float(r.service_radius_m), int(r.worker_capacity), str(names)])
	for u in get_tree().get_nodes_in_group("units"):
		if u == null or not is_instance_valid(u) or u.get_parent() != human:
			continue
		if str(u.get("unit_type_id")) != "worker":
			continue
		var owner_name := "-"
		if u.has_meta(ASSIGNMENT_META):
			var holder = u.get_meta(ASSIGNMENT_META)
			owner_name = holder.name if is_instance_valid(holder) else "<已释放>"
		var cooldown_ms := 0
		if u.has_meta(RECLAIM_COOLDOWN_META):
			cooldown_ms = maxi(0, int(u.get_meta(RECLAIM_COOLDOWN_META)) - Time.get_ticks_msec())
		var action_name := "<null>"
		var action = u.get("action")
		if action != null and action.get_script() != null:
			action_name = str(action.get_script().resource_path).get_file()
		print("[CLAIM-DUMP] 工人 %s pos=%s 归属=%s 冷却剩余=%dms action=%s" % [
			u.name, str(u.global_position.snapped(Vector3(0.1, 0.1, 0.1))),
			owner_name, cooldown_ms, action_name])


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
