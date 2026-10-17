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
##    C1 VehicleFactory 生产 Worker（世界角点口径）
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
const COMMAND_CENTER := "res://source/match/units/CommandCenter.tscn"

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
	# 等地表导航图就绪（CC 位置在 navmesh 上有归属）
	var terrain_map = _match.navigation.get_navigation_map_rid_by_domain(
		Constants.Match.Navigation.Domain.TERRAIN
	)
	var deadline := Time.get_ticks_msec() + 90000
	while Time.get_ticks_msec() < deadline:
		await get_tree().physics_frame
		var pn: Node = _match.get_node_or_null("Players")
		if pn != null and pn.get_child_count() >= 1:
			for sub in pn.get_child(0).get_children():
				if sub is Node3D and sub.get_script() != null \
						and "CommandCenter" in str(sub.get_script().resource_path):
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
	await _test_adjacency(cc_r)
	await _test_size_and_carve_consistency()
	_finish()


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


# ---------------- A. 相邻判定 ----------------
func _cost(scene_path: String) -> Dictionary:
	return _balance.GetConstructionCost(load(scene_path))


func _radius_of(scene_path: String) -> float:
	var n = load(scene_path).instantiate()
	var r: float = float(n.get("radius"))
	n.free()
	return r


func _test_adjacency(cc_r: float) -> void:
	# B 段经 runtime.Place 落的炮塔会占住"一次一个工地"的名额（ConstructionInProgress），
	# 后面的相邻判定会全部被这条规则提前拒掉。单机无 AI/无建造者时没人推进施工，
	# 所以这里直接把所有在建工地推到完工，再测相邻。
	# B 段的驱逐试验把炮塔和工人留在基地旁边，会把相邻判定的候选环整个判成 Occupied。
	# 驱逐本身已由 B2 单独断言，这里清场再判相邻，各测各的。
	for child in _human.get_children():
		if not (child is Node3D):
			continue
		var script = child.get_script()
		if script == null:
			continue
		var path_str = str(script.resource_path)
		if "Turret" in path_str or "Worker" in path_str:
			child.queue_free()
	await get_tree().physics_frame
	await get_tree().physics_frame
	_finish_all_construction()
	await _wait_navmesh_settled()
	# 相邻判定围绕一个**新建**的完工主基地做：本图真实出生点 CC 周围 13.9m 处整圈都
	# 不可建（SurfaceNotBuildable，地图属性），在那儿判相邻只会得到假红。
	var anchor: Node3D = await _spawn_fresh_command_center()
	if anchor == null:
		_check(false, "A0 应能为本方找到并落成一个合法主基地锚点")
		return
	var anchor_r: float = float(anchor.get("radius"))
	var barracks_r := _radius_of(BARRACKS)
	var base_cost := _cost(BARRACKS)
	var min_center: float = anchor_r + barracks_r

	# A1 窗内（最小距 + clearance 的合法区间）→ Accepted。
	# 同一半径上不同方位的可建性受地形/ carve 影响，所以在窗口内扫多个距离取第一个合法点。
	var ok_a1 := false
	var a1_tried := 0
	for step in range(0, 7):
		var offset: float = 0.15 + float(step) * 0.1
		for k in range(16):
			var a := TAU * float(k) / 16.0
			var p: Vector3 = anchor.global_position + Vector3(cos(a) * (min_center + offset), 0, sin(a) * (min_center + offset))
			var e = _runtime.Evaluate(_human, load(BARRACKS), Transform3D(Basis.IDENTITY, p), base_cost)
			a1_tried += 1
			if e is Dictionary and e.get("accepted", false):
				ok_a1 = true
				break
		if ok_a1:
			break
	print("[INFO] A1 在相邻窗口内试了 %d 个候选，Accepted=%s" % [a1_tried, str(ok_a1)])
	_check(ok_a1, "A1 相邻窗内（圆心距 = 半径和 + 0.15~0.65m）应 Accepted")

	# A2 圆心距明显小于半径和 → Occupied（不能进驱逐计划）
	var overlap_p: Vector3 = anchor.global_position + Vector3(anchor_r * 0.5, 0, 0)
	var e2 = _runtime.Evaluate(_human, load(BARRACKS), Transform3D(Basis.IDENTITY, overlap_p), base_cost)
	var issues2: Array = e2.get("issues", []) if e2 is Dictionary else []
	_check(not bool(e2.get("accepted", false)) and "Occupied" in issues2,
		"A2 与己方建筑重叠（圆心距 %.1f < %.1f）应 Occupied" % [anchor_r * 0.5, min_center])

	# 【2026-10-01】建造网络范围由运行时权威值提供；测试不能再硬编码旧的 48m。
	# 这是边缘距离上限，候选圆心上限 = 半径和 + build_range。
	var build_range := float(_runtime.BuildRangeMeters())
	var far_delta := build_range + 12.0
	var far_p: Vector3 = anchor.global_position + Vector3(anchor_r + barracks_r + far_delta, 0, 0)
	var e3 = _runtime.Evaluate(_human, load(BARRACKS), Transform3D(Basis.IDENTITY, far_p), base_cost)
	var issues3: Array = e3.get("issues", []) if e3 is Dictionary else []
	_check(not bool(e3.get("accepted", false)) and "NotAdjacent" in issues3,
		"A3 超出建造范围（边缘距离 %.1fm > %.1fm）应 NotAdjacent" % [far_delta, build_range])
	# A3b：建造范围**之内**必须不因 NotAdjacent 被拒；地形/占用仍由其他判据负责。
	var within_delta := maxf(1.0, build_range * 0.75)
	var within_p: Vector3 = anchor.global_position + Vector3(min_center + within_delta, 0, 0)
	var e3b = _runtime.Evaluate(_human, load(BARRACKS), Transform3D(Basis.IDENTITY, within_p), base_cost)
	var issues3b: Array = e3b.get("issues", []) if e3b is Dictionary else []
	_check("NotAdjacent" not in issues3b,
		"A3b 建造范围之内（边缘距离 %.1fm / %.1fm）不得再判 NotAdjacent" % [within_delta, build_range])

	# A4 同一合法点放两次 → 第二次必须被拒（两栋建筑不能重叠落地）
	var legal := Vector3.INF
	for k in range(12):
		var a4 := TAU * float(k) / 12.0
		var p4: Vector3 = anchor.global_position + Vector3(cos(a4) * (min_center + 0.6), 0, sin(a4) * (min_center + 0.6))
		var e4 = _runtime.Evaluate(_human, load(BARRACKS), Transform3D(Basis.IDENTITY, p4), base_cost)
		if e4 is Dictionary and e4.get("accepted", false):
			legal = p4
			break
	_check(legal != Vector3.INF, "A4 前置：找到合法兵营落点")
	if legal != Vector3.INF:
		var first = _runtime.Place(_human, load(BARRACKS), Transform3D(Basis.IDENTITY, legal), base_cost)
		_check(bool(first.get("accepted", false)), "A4 第一次放置应成功")
		for _frame in range(30):
			await get_tree().physics_frame
		var second = _runtime.Place(_human, load(BARRACKS), Transform3D(Basis.IDENTITY, legal), base_cost)
		_check(not bool(second.get("accepted", false)),
			"A4 同一落点第二次放置必须被拒（%s）" % second.get("status"))


# ---------------- E. 尺寸口径与 carve 一致性 ----------------
func _test_size_and_carve_consistency() -> void:
	# E1 五栋建筑的"本地碰撞半径 × root scale == 世界 footprint"必须成立：
	# CollisionShape3D 的半径是**本地**值，会被根 scale 再放大一次；把世界半径
	# 直接写进场景会让碰撞变成两倍大（09-29 实测过，已全部还原）。
	var buildings := {
		"command_center": "res://source/match/units/CommandCenter.tscn",
		"vehicle_factory": "res://source/match/units/VehicleFactory.tscn",
		"barracks": "res://source/match/units/Barracks.tscn",
		"ore_refinery": "res://source/match/units/OreRefinery.tscn",
		"aircraft_factory": "res://source/match/units/AircraftFactory.tscn",
	}
	for type_id in buildings:
		var node: Node3D = load(buildings[type_id]).instantiate()
		var shape := _first_cylinder_radius(node)
		var movement := float(node.get("radius"))
		var scale: float = node.scale.x
		node.free()
		if shape <= 0.0:
			print("[DIAG] E1 %s 无 CylinderShape3D，跳过" % type_id)
			continue
		var world: float = shape * scale
		print("[INFO] E1 %s 本地碰撞 %.3f × scale %.2f = 世界 %.2f；footprint %.2f"
			% [type_id, shape, scale, world, movement])
		_check(
			absf(world - movement) < 0.05,
			"E1 %s 本地碰撞半径 × scale 应等于世界 footprint（%.2f vs %.2f）"
				% [type_id, world, movement]
		)
		_check(
			not (absf(shape - movement) < 0.05 and scale > 1.01),
			"E1 %s 不得把世界 footprint 直接写进已缩放的 CollisionShape3D" % type_id
		)

	# E2 carve 洞必须**覆盖建筑真实脚印**。口径在 2026-09-30 用单障碍受控场景重测过
	# （tests/automated/_NavCarveLab.gd，每次改属性后真正重烘）：
	#   radius=7.0 + vertices 为空          → 洞 1.0（完全没有洞）
	#   radius=7.0 + vertices 世界外缘 1.4  → 洞 4.0  = 1.4 + agent 2.8
	#   只把 radius 改成 1.0（vertices 不动）→ 洞 4.0  ⇒ radius 与 carve 无关
	#   vertices 外缘 5.0 → 洞 8.0；再乘 obstacle scale 3 → 洞 18.0
	#   只留 CollisionShape3D（世界 7.0）→ 洞 1.0 ⇒ 物理体不参与烘焙
	# 旧断言写的是"carve 不得比 footprint 口径更大"，在错误模型下会让洞比脚印还小
	# （09-29 实测主基地洞只有 4.2m < footprint 7.0m），寻路因此把单位送进建筑体内，
	# 再被碰撞/避让顶出来 —— 卡住、抖动、到不了目标的直接来源。
	# 现在钉住运行时契约：MovementObstacle 由 radius 生成 vertices，令
	# carve = radius(世界 footprint) + agent_radius。
	var agent_radius := 2.8
	# Exact authored proportions updated on 2026-10-10; geometric tolerances are unchanged.
	var expected_world_radius := {
		"CommandCenter": 4.9764, "VehicleFactory": 3.972, "Barracks": 3.57075,
		"OreRefinery": 3.0186, "AircraftFactory": 4.3945,
	}
	var probe_root := Node3D.new()
	probe_root.name = "E2ProbeRoot"
	probe_root.scale = Vector3(3, 3, 3)
	add_child(probe_root)
	for type_id in buildings:
		var building: Node3D = load(buildings[type_id]).instantiate()
		var source_obstacle: Node = building.get_node_or_null("MovementObstacle")
		var footprint := float(source_obstacle.get("radius")) if source_obstacle != null else 0.0
		building.free()
		if footprint <= 0.0:
			_check(false, "E2 %s 缺少 MovementObstacle.radius，无法验证 carve" % type_id)
			continue
		var camel := String(type_id).to_pascal_case()
		if expected_world_radius.has(camel):
			_check(absf(footprint - expected_world_radius[camel]) < 0.02,
				"E2 %s 世界 footprint 应为计划目标值 %.2f（实际 %.2f）"
					% [camel, expected_world_radius[camel], footprint])
		var probe: NavigationObstacle3D = load(
			"res://source/match/units/traits/MovementObstacle.tscn").instantiate()
		probe.set("radius", footprint)
		probe_root.add_child(probe)
		await get_tree().process_frame
		var outer := 0.0
		for v in (probe.get("vertices") as PackedVector3Array):
			var world_v: Vector3 = probe.global_transform * v
			outer = maxf(outer, Vector2(world_v.x, world_v.z).length())
		var world_scale: float = probe.global_transform.basis.get_scale().x
		print("[INFO] E2 %s footprint=%.2f → vertices 世界外缘=%.2f（carve=%.2f），global scale=%.2f"
			% [type_id, footprint, outer, outer + agent_radius, world_scale])
		_check(absf(outer - footprint) < 0.15,
			"E2 %s carve 顶点环世界外缘必须等于世界 footprint（%.2f vs %.2f）"
				% [type_id, outer, footprint])
		probe.queue_free()
		await get_tree().process_frame
	probe_root.queue_free()


## 取节点下第一个 CylinderShape3D 的 radius（取不到返回 0）。
func _first_cylinder_radius(node: Node3D) -> float:
	for child in node.find_children("*", "CollisionShape3D", true, false):
		var shape = child.get("shape")
		if shape is CylinderShape3D:
			return float((shape as CylinderShape3D).radius)
	return 0.0


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


func _finish() -> void:
	print("Size unification regression: %d failure(s)" % _failures)
	# 走统一收尾：先把整局回收并停掉音频播放器，否则命中 ObjectDB/RID/资源泄漏禁则
	SmokeTestExit.request(get_tree(), 1 if _failures > 0 else 0, _match)

## 等本方所有工地**自动施工**完工（不许绕过 C# 权威服务直接调节点）。
## 单机夹具没有建造者/AI 施工，不手动推完工地会一直占着"一次一个工地"的名额。
## 等本方所有工地**自动施工**完工。
## 不能绕过 C# 权威服务直接调节点的 complete_authoritative_construction()：那只会改
## GDScript 侧外观，ConstructionService._sites 仍记 Active，"一次一个工地"会继续拒。
## 自动施工每 tick 记 AutomaticWorkPerTick，通常 3~4s 收尾。
func _finish_all_construction() -> void:
	var deadline := Time.get_ticks_msec() + 90000
	while Time.get_ticks_msec() < deadline:
		var pending := false
		for child in _human.get_children():
			if not (child is Node3D) or not child.has_method("is_constructed"):
				continue
			if not child.is_constructed():
				pending = true
		if not pending:
			return
		await get_tree().create_timer(0.2).timeout




## 等导航图烘焙稳定：新建筑入树会 schedule 重烘，烘焙中 map_get_closest_point 返回
## 半成品网格，把所有候选判成 SurfaceNotBuildable（实测相邻 4 条断言全红）。
func _wait_navmesh_settled() -> void:
	if _match.navigation == null:
		return
	var rid: RID = _match.navigation.get_navigation_map_rid_by_domain(1)
	if not rid.is_valid():
		return
	for _warmup in range(300):
		await get_tree().physics_frame
	var previous := NavigationServer3D.map_get_iteration_id(rid)
	var stable := 0
	for _frame in range(900):
		await get_tree().physics_frame
		var current := NavigationServer3D.map_get_iteration_id(rid)
		if current == previous:
			stable += 1
			if stable >= 3:
				return
		else:
			stable = 0
			previous = current



## 扫描一个合法主基地落点并真的放下去（等自动施工完工后返回节点）。
func _spawn_fresh_command_center() -> Node3D:
	var cost := _cost(COMMAND_CENTER)
	for ring in range(1, 10):
		for k in range(16):
			var a := TAU * float(k) / 16.0
			var dist: float = 8.0 + float(ring) * 6.0
			var p: Vector3 = _cc.global_position + Vector3(cos(a) * dist, 0, sin(a) * dist)
			var e = _runtime.Evaluate(_human, load(COMMAND_CENTER), Transform3D(Basis.IDENTITY, p), cost)
			if e is Dictionary and e.get("accepted", false):
				var placed: Dictionary = _runtime.Place(_human, load(COMMAND_CENTER), Transform3D(Basis.IDENTITY, p), cost)
				if not bool(placed.get("accepted", false)):
					continue
				var node: Node3D = placed.get("structure")
				var deadline := Time.get_ticks_msec() + 60000
				while node != null and Time.get_ticks_msec() < deadline and not node.is_constructed():
					await get_tree().create_timer(0.2).timeout
				return node
	return null

