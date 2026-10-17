extends Node

## 尺寸口径统一回归（2026-09-29 任务点名断言全覆盖）。
##
## A. 相邻建筑四条：
##    A1 边缘距离在合法 clearance 内 → Accepted
##    A2 边缘距离小于 clearance（圆心距 < 半径和）→ Occupied
##    A3 很远的己方建筑不能被误判为相邻（> 半径和 + 0.75 → NotAdjacent）
##    A4 两栋己方建筑不能重叠落地（Place 同点两次：第二次必须拒）
## B. 碰撞：
##    B1 结构不能互相重叠（A4 覆盖）
##    B2 被建筑驱逐的单位最终距离 > 半径和 + 余量
##    B3 导航 carve 尺寸与碰撞尺寸同源（SizeAuditProbe 之外这里复核运行时值）
## C. 出生点：
##    C1 VehicleFactory 生产 Tank（世界角点口径；矿车已不是车厂的合法产品）
##    C2 Barracks 生产 Infantry
##    C3 OreRefinery 完工赠送 Worker（与生产共用算法 → 距离规律一致）
##    C4 旋转建筑 90° 后出生方向随建筑旋转
##    C5 多个单位连续生产不互相重叠
##    C6 出生点不落在建筑内部 / 原点 / 地图外

const MatchSettings = preload("res://source/data-model/MatchSettings.gd")
const FACTORY := "res://source/match/units/VehicleFactory.tscn"
const BARRACKS := "res://source/match/units/Barracks.tscn"
const REFINERY := "res://source/match/units/OreRefinery.tscn"
const TANK := "res://source/match/units/Tank.tscn"
const INFANTRY := "res://source/match/units/Infantry.tscn"
const WORKER := "res://source/match/units/Worker.tscn"
const MAP_SCENE := "res://source/match/maps/PlainAndSimple.tscn"
const EDGE_CLEARANCE := 0.75

var _failures := 0
var _match: Node = null
var _human: Node = null
var _runtime: Node = null
var _balance: Node = null
var _cc: Node3D = null


func _check(cond: bool, msg: String) -> void:
	if cond:
		print("[PASS] " + msg)
	else:
		_failures += 1
		print("[FAIL] " + msg)


# ---------------- B. 碰撞 / 驱逐 ----------------
func _test_displacement(cc_r: float) -> void:
	# A4 放的兵营若仍在施工，"一次一个工地"会拒后续放置 → 等它完工再测驱逐
	var a4_deadline := Time.get_ticks_msec() + 90000
	while Time.get_ticks_msec() < a4_deadline:
		var busy := false
		for child in _human.get_children():
			if child is Node3D and "Barracks" in str(child.get_script().resource_path):
				if child.has_method("is_constructed") and not child.is_constructed():
					busy = true
		if not busy:
			break
		await get_tree().physics_frame
	await get_tree().physics_frame

	var turret_r := _radius_of("res://source/match/units/AntiGroundTurret.tscn")
	var worker_r := _radius_of(WORKER)
	var turret_cost := _cost("res://source/match/units/AntiGroundTurret.tscn")
	var stand_off: float = cc_r + turret_r + 0.6
	var placed: Dictionary = {}
	var worker: Node3D = null
	# 12 个方位里找一个地形可建的点，把工人**直接生成在那里**（不用搬 global_position）
	for k in range(12):
		var a := TAU * float(k) / 12.0
		var cand: Vector3 = _cc.global_position + Vector3(cos(a) * stand_off, 0, sin(a) * stand_off)
		var probe_turret = load("res://source/match/units/AntiGroundTurret.tscn").instantiate()
		_match.call("_setup_and_spawn_unit", probe_turret,
			Transform3D(Basis.IDENTITY, cand), _human, false)
		var e = _runtime.Evaluate(_human, load("res://source/match/units/AntiGroundTurret.tscn"),
			Transform3D(Basis.IDENTITY, cand), turret_cost)
		probe_turret.queue_free()
		if e is Dictionary and not bool(e.get("accepted", false)):
			continue
		worker = load(WORKER).instantiate()
		_match.call("_setup_and_spawn_unit", worker,
			Transform3D(Basis.IDENTITY, cand), _human, false)
		await get_tree().physics_frame
		await get_tree().physics_frame
		# 现在工人就在 cand（若吸附离开，用工人真实位置当落点）
		var real_spot: Vector3 = worker.global_position
		placed = _runtime.Place(_human, load("res://source/match/units/AntiGroundTurret.tscn"),
			Transform3D(Basis.IDENTITY, real_spot), turret_cost)
		if bool(placed.get("accepted", false)):
			break
		worker.queue_free()
		worker = null
	if not bool(placed.get("accepted", false)):
		print("[DIAG] B0 12 方位均不可建（最后 issues=%s）" % str(placed.get("issues", [])))
	_check(bool(placed.get("accepted", false)), "B0 炮塔应能落在工人身上（驱逐场景）")
	# B2 等驱逐执行完，量最终间距
	var far_enough := false
	var turret_node: Node3D = null
	for _frame in range(300):
		await get_tree().physics_frame
		for child in _human.get_children():
			if child is Node3D and "Turret" in str(child.get_script().resource_path):
				turret_node = child
		if turret_node != null and worker != null and is_instance_valid(worker):
			var d: float = Vector2(worker.global_position.x - turret_node.global_position.x,
				worker.global_position.z - turret_node.global_position.z).length()
			if d > turret_r + worker_r + 0.05:
				far_enough = true
				print("[INFO] B2 驱逐后工人距炮塔 %.2fm（半径和 %.2f）" % [d, turret_r + worker_r])
				break
	_check(far_enough, "B2 被驱逐单位最终距离应 > 半径和（%0.2f）" % (turret_r + worker_r))



func _ready():
	var settings = MatchSettings.new()
	var human = load("res://source/data-model/PlayerSettings.gd").new()
	human.controller = Constants.PlayerType.HUMAN
	human.color = Constants.Player.COLORS[0]
	settings.players.append(human)
	settings.visible_player = 0
	settings.visibility = MatchSettings.Visibility.PER_PLAYER
	_match = load("res://source/match/Match.tscn").instantiate()
	_match.settings = settings
	_match.map = load(MAP_SCENE).instantiate()
	add_child(_match)
	get_tree().current_scene = _match
	var terrain_map = _match.navigation.get_navigation_map_rid_by_domain(
		Constants.Match.Navigation.Domain.TERRAIN
	)
	var deadline := Time.get_ticks_msec() + 90000
	while Time.get_ticks_msec() < deadline:
		await get_tree().physics_frame
		var pn: Node = _match.get_node_or_null("Players")
		if pn != null and pn.get_child_count() >= 1:
			for sub in pn.get_child(0).get_children():
				if sub is Node3D and sub.get_script() != null 						and "CommandCenter" in str(sub.get_script().resource_path):
					_cc = sub
			if _cc != null and NavigationServer3D.map_get_closest_point_owner(
				terrain_map, _cc.global_position).is_valid():
				break
	_check(_cc != null, "对局应就绪且有指挥中心")
	if _cc == null:
		_finish()
		return
	_human = _match.get_node("Players").get_children()[0]
	_runtime = _match.get_node("StructurePlacementRuntime")
	_balance = _match.get_node("BalanceConfigRuntime")
	_human.add_resources({"resource_a": 90000}, "Regression")
	await get_tree().physics_frame
	var cc_r: float = float(_cc.get("radius"))
	await _test_displacement(cc_r)
	await _test_spawn_points()
	_finish()


## 把一个建筑以"已完工"身份放到世界里（不走放置运行时，避开 ConstructionInProgress）。
func _spawn_structure(scene_path: String, position: Vector3, yaw: float) -> Node3D:
	var node: Node3D = load(scene_path).instantiate()
	var transform := Transform3D(Basis(), position)
	if not is_zero_approx(yaw):
		transform.basis = Basis.from_euler(Vector3(0, yaw, 0))
	_match.call("_setup_and_spawn_unit", node, transform, _human, false)
	await get_tree().physics_frame
	await get_tree().physics_frame
	await _wait_navmesh_settled()
	return node


## 等导航图烘焙稳定（map_iteration_id 连续 3 帧不变）。
## 【2026-09-29 关键】新建筑入树会 schedule 一次重烘；重烘进行中
## `map_get_closest_point` 返回的还是半成品网格，出生点搜索会把合法落点全判成
## NOT_NAVIGABLE 而逐环外扩（实测矿车被推到 24.45m 外，比模型外缘远 16m）。
## 诊断报告第 6 条同样要求"测试放置前等待导航图完成"。
func _wait_navmesh_settled() -> void:
	if _match.navigation == null:
		return
	var rid: RID = _match.navigation.get_navigation_map_rid_by_domain(1)
	if not rid.is_valid():
		return
	# 重烘是 schedule + 去抖触发的：开烘前 iteration_id 一直不变，"等 id 稳定"会立刻
	# 放行，然后搜索正好撞上烘焙进行中的半成品网格。所以这里固定等满一帧窗口，
	# 再叠加 id 稳定性检查（双保险）。
	for _warmup in range(600):
		await get_tree().physics_frame
	var previous := NavigationServer3D.map_get_iteration_id(rid)
	var stable_frames := 0
	for _frame in range(900):
		await get_tree().physics_frame
		var current := NavigationServer3D.map_get_iteration_id(rid)
		if current == previous:
			stable_frames += 1
			if stable_frames >= 3:
				return
		else:
			stable_frames = 0
			previous = current


# ---------------- C. 出生点 ----------------
func _test_spawn_points() -> void:
	# C1 车厂（旋转 90°）生产坦克：几何断言与原先的矿车相同。
	# 矿车已改回车厂生产，但这组断言继续用坦克，避免把出生点夹具再绑回矿车。
	# 距离、正脸方向、连续不重叠的数值断言不放宽。
	var factory: Node3D = await _spawn_structure(
		FACTORY, _cc.global_position + Vector3(18.0, 0, 0), PI * 0.5
	)
	var f_edge := _world_edge_of(factory)
	var c1: Dictionary = await _produce_and_wait(factory, TANK, "C1")
	var miner: Node3D = c1.get("unit", null)
	var m_r: float = float(miner.get("radius")) if miner != null else 0.0
	# 任务口径：distance(producer_center, spawn) > producer_world_radius
	#   + produced_unit_world_radius + spacing（这是**下限**，不是"必须贴近"）。
	var f_min: float = float(factory.get("radius")) + m_r + 0.1
	if miner != null:
		var d: float = _xz_distance(miner.global_position, factory.global_position)
		print("[INFO] C1 矿车距车厂 %.2fm（模型外缘 %.2f；任务下限 %.2f = footprint %.2f + 半径 %.2f + 0.1）"
			% [d, f_edge, f_min, float(factory.get("radius")), m_r])
		_check(
			d > f_min,
			"C6 矿车不得出生在建筑内部/过近（%.2fm > %.2fm）" % [d, f_min]
		)
		_check(
			_xz_distance(miner.global_position, Vector3.ZERO) >= 1.0,
			"C6 矿车不得出生在原点"
		)
		_check(
			not miner.global_position.is_equal_approx(factory.global_position),
			"C6 矿车不得与建筑中心重合"
		)
		# C4 方向随建筑旋转：建筑转 90° 后局部 +Z 的世界朝向 = +X
		var facing: Vector3 = (factory.global_transform.basis * Vector3(0, 0, 1)).normalized()
		facing.y = 0.0
		var dir_len := Vector2(
			miner.global_position.x - factory.global_position.x,
			miner.global_position.z - factory.global_position.z
		).length()
		var dot: float = (facing.x * (miner.global_position.x - factory.global_position.x)
			+ facing.z * (miner.global_position.z - factory.global_position.z)) \
			/ maxf(dir_len, 0.0001)
		print("[INFO] C4 建筑正脸 XZ=(%.2f,%.2f) 矿车方向 dot=%.2f" % [facing.x, facing.z, dot])
		_check(dot > 0.5, "C4 旋转 90° 后矿车应从建筑正脸方向出生（dot=%.2f）" % dot)

		# C5 同一车厂连续生产第二辆坦克：两个单位不得互相重叠
		var c5: Dictionary = await _produce_and_wait(factory, TANK, "C5")
		var second: Node3D = c5.get("unit", null)
		if second != null:
			var separation: float = _xz_distance(miner.global_position, second.global_position)
			var r_sum: float = m_r + float(second.get("radius"))
			print("[INFO] C5 连续两台矿车圆心距 %.2fm（半径和 %.2f）" % [separation, r_sum])
			_check(
				separation > r_sum,
				"C5 连续生产的单位不得互相重叠（%.2fm > %.2fm）" % [separation, r_sum]
			)

	# C2 兵营生产步兵（放远一点，避免和车厂/矿场抢同一块合法落点）
	var barracks: Node3D = await _spawn_structure(
		BARRACKS, _cc.global_position + Vector3(-20.0, 0, 0), 0.0
	)
	var b_edge := _world_edge_of(barracks)
	var c2: Dictionary = await _produce_and_wait(barracks, INFANTRY, "C2")
	var infantry: Node3D = c2.get("unit", null)
	if infantry != null:
		var i_r: float = float(infantry.get("radius"))
		var b_min: float = float(barracks.get("radius")) + i_r + 0.1
		var db: float = _xz_distance(infantry.global_position, barracks.global_position)
		print("[INFO] C2 步兵距兵营 %.2fm（模型外缘 %.2f；任务下限 %.2f）" % [db, b_edge, b_min])
		_check(db > b_min, "C6 步兵不得出生在兵营内部/过近（%.2fm > %.2fm）" % [db, b_min])
	else:
		_check(false, "C2 兵营应真的产出步兵")

	# C3 矿场完工赠送矿车：必须走同一条 world-corner 共享算法，距离规律与 C1 一致
	var refinery: Node3D = load(REFINERY).instantiate()
	_match.call(
		"_setup_and_spawn_unit",
		refinery,
		Transform3D(Basis(), _cc.global_position + Vector3(0, 0, 20.0)),
		_human,
		true
	)
	# 触发真实完工链路：mirror 权威整数进度 → 完工表现 → constructed 信号 → 赠车
	var before: Array = _human.get_children()
	var advanced: bool = refinery.apply_authoritative_construction_work(1, 1)
	var finished: bool = refinery.complete_authoritative_construction()
	_check(
		advanced and finished,
		"C3 矿场应能进入完工链路（work=%s finish=%s）" % [str(advanced), str(finished)]
	)
	var r_edge := _world_edge_of(refinery)
	# 快照必须在触发完工**之前**：赠车是同步发生的
	var free_miner: Node3D = await _await_new_worker(before, 1200)
	if free_miner != null:
		var w_r: float = float(free_miner.get("radius"))
		var r_min: float = float(refinery.get("radius")) + w_r + 0.1
		var d3: float = _xz_distance(free_miner.global_position, refinery.global_position)
		print("[INFO] C3 赠车距矿场 %.2fm（模型外缘 %.2f；任务下限 %.2f = footprint %.2f + 半径 %.2f + 0.1）"
			% [d3, r_edge, r_min, float(refinery.get("radius")), w_r])
		_check(
			d3 > r_min,
			"C3 赠车不得出生在矿场内部/过近（%.2fm > %.2fm）" % [d3, r_min]
		)
	else:
		_check(false, "C3 矿场完工应赠送矿车")

	# D root scale 变体：同一栋车厂 scale=2 / scale=3 时，世界外缘与出生点圆心距必须
	# 随 scale 等比变化（证明算法读的是**世界**几何外缘，而非被 root scale 抵消的本地外缘）。
	await _test_scale_variants()


## 同一栋车厂以**不同 Visual 缩放**各放一个实例（2026-09-30 世界米制归一化后：
## UnitRoot scale 恒为 1、实例化只接受世界位置与旋转，美术缩放只存在于 Visual 分支），
## 比较 production_spawn_spot 的落点距离：世界外缘必须随 Visual 缩放等比变化，
## 落点也必须贴各自的世界外缘 —— 证明算法读的是**世界**几何外缘，
## 而不是与缩放无关的本地外缘或纯逻辑半径。
func _test_scale_variants() -> void:
	var produced = load(WORKER).instantiate()
	var produced_radius: float = float(produced.get("radius"))
	produced.free()
	var nav_map := RID()
	if _match.navigation != null:
		nav_map = _match.navigation.get_navigation_map_rid_by_domain(1)
	var small: Node3D = load(FACTORY).instantiate()
	var big: Node3D = load(FACTORY).instantiate()
	# 归一化后：把尺寸差异放进 Visual（根节点 scale 恒为 1，写了也会被实例化路径按契约忽略）。
	var small_visual: Node3D = small.get_node_or_null("Geometry")
	var big_visual: Node3D = big.get_node_or_null("Geometry")
	if small_visual != null and big_visual != null:
		big_visual.scale = big_visual.scale * 1.5
	var base := _cc.global_position + Vector3(0, 0, 26.0)
	for probe in [small, big]:
		_match.call("_setup_and_spawn_unit", probe, Transform3D(Basis(), base), _human, false)
	await get_tree().physics_frame
	await get_tree().physics_frame
	var spot_small: Vector3 = Utils.Match.Unit.Placement.production_spawn_spot(
		small, load(WORKER).instantiate(), 0.1, nav_map, get_tree(), 24, null
	)
	var spot_big: Vector3 = Utils.Match.Unit.Placement.production_spawn_spot(
		big, load(WORKER).instantiate(), 0.1, nav_map, get_tree(), 24, null
	)
	var edge_small := _world_edge_of(small)
	var edge_big := _world_edge_of(big)
	var d_small: float = _xz_distance(spot_small, small.global_position)
	var d_big: float = _xz_distance(spot_big, big.global_position)
	print("[INFO] D scale=2 外缘 %.2f → 落点 %.2f；scale=3 外缘 %.2f → 落点 %.2f"
		% [edge_small, d_small, edge_big, d_big])
	# 落点距圆心 = 外缘 + 单位半径 + spacing（±径向搜索外扩），两者都应贴各自外缘
	_check(
		d_small > edge_small + produced_radius - 0.5 and d_small <= edge_small + produced_radius + 6.0,
		"D scale=2 出生点应贴各自世界外缘（%.2fm vs 外缘 %.2f）" % [d_small, edge_small]
	)
	_check(
		d_big > edge_big + produced_radius - 0.5 and d_big <= edge_big + produced_radius + 6.0,
		"D scale=3 出生点应贴各自世界外缘（%.2fm vs 外缘 %.2f）" % [d_big, edge_big]
	)
	# 关键：外缘必须随 Visual 缩放等比放大（1.5×），否则算法读的是被抵消的本地外缘
	if edge_small > 0.5 and edge_big > 0.5:
		var ratio: float = edge_big / edge_small
		print("[INFO] D 世界外缘比（1.5×）：%.2f" % ratio)
		_check(
			ratio > 1.25 and ratio < 1.75,
			"D Visual 缩放必须真实进入世界外缘（比值 %.2f，期望约 1.50）" % ratio
		)
	for probe in [small, big]:
		probe.queue_free()


## 让生产建筑入队 unit_scene，等它真的部署出来；返回 {unit=, accepted=}。
func _produce_and_wait(producer: Node, unit_scene: String, label: String) -> Dictionary:
	var queue = producer.find_child("ProductionQueue", false, false)
	if queue == null or not queue.has_method("produce"):
		_check(false, "%s 应有生产队列" % label)
		return {}
	var element = queue.produce(load(unit_scene))
	var last: Dictionary = queue.get_last_result()
	if element == null:
		print("[DIAG] %s produce 被拒：%s" % [label, str(last)])
	_check(element != null, "%s 入队生产 %s 应被接受" % [label, unit_scene.get_file()])
	var unit: Node3D = await _await_produced(producer, unit_scene, 3600)
	_check(unit != null, "%s 应真的产出单位" % label)
	if unit != null:
		return {"unit": unit}
	return {}


## 轮询等待 producer 产出 scene_path 类型的单位（用权威完成信号，不再扫子节点名）。
func _await_produced(producer: Node, scene_path: String, timeout_frames: int) -> Node3D:
	var worker = _ProducedWatch.new()
	worker.wanted_producer = producer
	worker.wanted_scene = scene_path
	MatchSignals.unit_production_finished.connect(worker._on_finished)
	for _frame in range(timeout_frames):
		await get_tree().physics_frame
		if worker.found != null:
			break
	MatchSignals.unit_production_finished.disconnect(worker._on_finished)
	var found: Node3D = worker.found
	if found != null:
		# 等位移/贴地稳定再量坐标
		for _settle in range(30):
			await get_tree().physics_frame
	return found


class _ProducedWatch:
	extends RefCounted
	var wanted_producer: Node = null
	var wanted_scene: String = ""
	var found: Node3D = null
	func _on_finished(unit, producer) -> void:
		if producer != wanted_producer or found != null:
			return
		if unit == null or not (unit is Node3D):
			return
		if str(unit.scene_file_path) != wanted_scene:
			return
		found = unit


func _xz_distance(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()


## 轮询等待一个**新出现**的 Worker 子节点（矿场赠车走 setup_and_spawn_unit，
## 不发光 production_finished 信号，只能扫子节点；before 是历史快照）。
func _await_new_worker(before: Array, timeout_frames: int) -> Node3D:
	var found: Node3D = null
	for _frame in range(timeout_frames):
		await get_tree().physics_frame
		for child in _human.get_children():
			if not (child is Node3D) or child in before:
				continue
			var script = child.get_script()
			if script == null:
				continue
			if "Worker" not in str(script.resource_path):
				continue
			found = child
			break
		if found != null:
			break
	if found != null:
		for _settle in range(30):
			await get_tree().physics_frame
	return found


func _world_edge_of(node: Node3D) -> float:
	var origin: Vector3 = node.global_position
	var edge := 0.0
	for mi in node.find_children("*", "GeometryInstance3D", true, false):
		var g: GeometryInstance3D = mi
		var aabb: AABB = g.get_aabb()
		var to_world: Transform3D = g.global_transform
		for index in 8:
			var corner := Vector3(
				aabb.position.x + (aabb.size.x if index & 1 else 0.0),
				aabb.position.y + (aabb.size.y if index & 2 else 0.0),
				aabb.position.z + (aabb.size.z if index & 4 else 0.0))
			var w: Vector3 = to_world * corner
			edge = maxf(edge, Vector2(w.x - origin.x, w.z - origin.z).length())
	if edge <= 0.0:
		var physical = node.get("radius")
		edge = float(physical) if physical != null else 0.0
	return edge





func _cost(scene_path: String) -> Dictionary:
	return _balance.GetConstructionCost(load(scene_path))


func _radius_of(scene_path: String) -> float:
	var n = load(scene_path).instantiate()
	var r: float = float(n.get("radius"))
	n.free()
	return r


func _finish() -> void:
	print("Spawn point + displacement regression: %d failure(s)" % _failures)
	# 走统一收尾：先把整局回收并停掉音频播放器，否则命中 ObjectDB/RID/资源泄漏禁则。
	# 先让几帧把测试期间 queue_free 的建筑/单位真正删掉，再回收整局。
	for _frame in range(6):
		await get_tree().physics_frame
	SmokeTestExit.request(get_tree(), 1 if _failures > 0 else 0, _match)
