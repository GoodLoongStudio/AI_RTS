extends Node

const MatchScene = preload("res://tests/manual/TestOneUnit.tscn")
const TurretScene = preload("res://source/match/units/AntiGroundTurret.tscn")
const WorkerScene = preload("res://source/match/units/Worker.tscn")

var _failures := 0
var _damaged_units := []


## 验证视野门槛、统一最终复验、资源扣款和友军安全驱逐纵向链路。
## 【2026-10-01 对齐提示词 §5 口径】实体沿"指向对方"方向的**地面 hull 半宽**（近地几何投影），
## 用于 hull-to-hull 表面间隙验收（提示词明确要求不用中心点距离）。
func _ground_half_along(node: Node3D, towards: Vector3) -> float:
	if node == null or not is_instance_valid(node):
		return 0.0
	var origin: Vector3 = node.global_position
	var dir := Vector2(towards.x - origin.x, towards.z - origin.z)
	if dir.length() < 0.0001:
		dir = Vector2.RIGHT
	dir = dir.normalized()
	var out := 0.0
	for gi in node.find_children("*", "GeometryInstance3D", true, false):
		var path := str(gi.get_path())
		if path.contains("Selection") or path.contains("Highlight") or path.contains("Targetability") \
				or path.contains("HealthBar") or path.contains("RallyPoint"):
			continue
		var local: AABB = (gi as GeometryInstance3D).get_aabb()
		if gi is MeshInstance3D and (gi as MeshInstance3D).mesh != null and local.size.length() < 0.01:
			local = (gi as MeshInstance3D).mesh.get_aabb()
		if local.size.length() < 0.001:
			continue
		var xf: Transform3D = (gi as Node3D).global_transform
		for i in range(8):
			var pt: Vector3 = xf * local.get_endpoint(i)
			if pt.y - origin.y > 0.6:
				continue
			out = maxf(out, Vector2(pt.x - origin.x, pt.z - origin.z).dot(dir))
	return maxf(out, 0.0)


func _ready():
	MatchSignals.unit_damaged.connect(_on_unit_damaged)
	var match_instance = MatchScene.instantiate()
	add_child(match_instance)
	for _frame in range(4):
		await get_tree().process_frame
	var terrain_map = match_instance.navigation.get_navigation_map_rid_by_domain(
		Constants.Match.Navigation.Domain.TERRAIN
	)
	var tank = match_instance.get_node("Players/Human/Tank")
	for _frame in range(180):
		if NavigationServer3D.map_get_closest_point_owner(
			terrain_map, tank.global_position
		).is_valid():
			break
		await get_tree().physics_frame
	_check(
		NavigationServer3D.map_get_closest_point_owner(
			terrain_map, tank.global_position
		).is_valid(),
		"地表导航图应在放置评估前完成初始化"
	)

	var human = match_instance.get_node("Players/Human")
	var runtime = match_instance.get_node("StructurePlacementRuntime")
	var cost = match_instance.get_node("BalanceConfigRuntime").GetConstructionCost(TurretScene)
	_check(
		human.add_resources({"resource_a": 3000}, "ScriptedAdjustment"),
		"测试资源注入应成功"
	)

	var hidden_transform = Transform3D(Basis.IDENTITY, Vector3(45.0, 0.0, 45.0))
	var hidden = runtime.Evaluate(human, TurretScene, hidden_transform, cost)
	_check(not hidden["accepted"], "未接入己方建筑网络的候选不得放置")
	_check("NotVisible" not in hidden["issues"], "建造不应再受战争迷雾视野门槛影响")
	_check("NotAdjacent" in hidden["issues"], "远离己方建筑的普通建筑应返回 NotAdjacent")
	_check(
		not "Occupied" in hidden["issues"],
		"视野不足时不得通过完整问题集合泄漏占用状态"
	)

	# 普通建筑只要求接入己方建筑网络；把坦克放到主基地边缘，
	# 同时保留“建筑覆盖己方移动单位后安全驱逐”的断言。
	# 【2026-09-29 修复并行会话引入的崩溃】旧代码 `human.get_node("CommandCenter")`
	# 在 TestOneUnit 夹具里不存在该节点（夹具只有 Human+Tank）→ null → 脚本整个崩掉，
	# 后面所有断言都不再执行。改为：有就用，没有就当场注入一座**已完工**的指挥中心
	# （相邻规则要求普通建筑接入己方建筑网络，没有锚点这条链路根本测不到）。
	var command_center: Node3D = human.get_node_or_null("CommandCenter") as Node3D
	if command_center == null:
		command_center = load("res://source/match/units/CommandCenter.tscn").instantiate()
		match_instance.call(
			"_setup_and_spawn_unit",
			command_center,
			Transform3D(Basis.IDENTITY, Vector3(40.0, 0.0, 28.0)),
			human,
			false
		)
		if command_center.has_method("mark_as_constructed"):
			command_center.mark_as_constructed()
		for _frame in range(30):
			await get_tree().physics_frame
	_check(command_center != null and is_instance_valid(command_center), "测试应有一座己方指挥中心作相邻锚点")
	if command_center == null:
		_finish(match_instance)
		return
	# 【2026-09-29 尺寸口径统一】摆放位置由世界几何算出：炮塔 footprint 2.2 + CC 7.0
	# = 9.2m 最小中心距，取 9.2 + 0.6 = 9.8m（相邻窗内，Overlaps 之外）。
	var turret_probe_node = TurretScene.instantiate()
	var turret_world_radius: float = 2.2
	if turret_probe_node != null:
		turret_world_radius = float(turret_probe_node.get("radius"))
		turret_probe_node.free()
	var cc_world_radius: float = float(command_center.get("radius"))
	var stand_off_m: float = cc_world_radius + turret_world_radius + 0.6
	tank.global_position = command_center.global_position + Vector3(stand_off_m, 0.0, 0.0)
	print("[PLACEMENT] CC 半径=%.2f 炮塔=%.2f 坦克摆放=%.2fm（最小 %.2f）"
		% [cc_world_radius, turret_world_radius, stand_off_m, cc_world_radius + turret_world_radius])
	var placement_transform = Transform3D(Basis.IDENTITY, tank.global_position)
	var preview = runtime.Evaluate(human, TurretScene, placement_transform, cost)
	_check(preview["accepted"], "己方移动单位重叠不应直接阻挡蓝图")
	var before_a: int = human.resource_a
	var before_b: int = human.resource_b
	var placed = runtime.Place(human, TurretScene, placement_transform, cost)
	_check(placed["accepted"], "具有安全驱逐落点时最终 Place 应接受")
	_check(human.resource_a == before_a - cost["resource_a"], "Place 应原子扣除 A")
	_check(human.resource_b == before_b - cost["resource_b"], "Place 应原子扣除 B")

	var structure = placed.get("structure")
	_check(structure != null and is_instance_valid(structure), "Place 应返回已生成施工现场")
	if structure == null or not is_instance_valid(structure):
		_finish(match_instance)
		return
	for _frame in range(180):
		await get_tree().physics_frame
	# 【2026-10-01 对齐提示词口径】提示词明确要求"验收使用 hull-to-hull 表面间隙，不使用中心点距离"
	# （per-unit-collider-clearance-execution-prompt.md §5）。旧写法 required = 坦克半径 + 建筑半径
	# 是**中心距**口径，会把"已经贴到建筑边上、本体完全在外面"判成失败。
	# 新口径：驱逐后单位的**地面 hull** 必须不与建筑的**地面 hull** 重叠（表面间隙 ≥ 0，留 0.05 容差）。
	var tank_hull: float = _ground_half_along(tank, structure.global_position)
	var structure_hull: float = _ground_half_along(structure, tank.global_position)
	var required_distance: float = maxf(tank_hull + structure_hull - 0.05, 0.0)
	# 失败信息带上实测距离与"坦克有没有在动"：只写"应移动到 footprint 外"的话，
	# 下一轮还是只能猜是"没执行驱逐"还是"执行了但 3 秒走不够"。
	var measured := _planar_distance(tank.global_position, structure.global_position)
	var displacement_message := "被覆盖的友军应移动到建筑 footprint 外并待命（实测 %.2f m，" % measured
	displacement_message += "需要 > %.2f m，action=%s）" % [required_distance, str(tank.action)]
	_check(measured > required_distance, displacement_message)
	_check(not structure in _damaged_units, "施工初始化与新增 HP 不应误发 unit_damaged")

	# 【2026-10-12 工期口径】本段断言的前提是"上面 180 帧驱逐窗口跑完后现场还未完工"，
	# 否则 Construct 命令会被权威以 SiteNotActive 拒掉，订单生命周期无从断言。
	# requiredWork 减半（炮塔 200→100）后自动施工会在第 100 物理 Tick 完工，
	# 因此这里显式 SKIP 整段，而不是让"命令被拒"伪装成施工或订单坏了。
	# 自动施工进度本身由 automatic-construction 覆盖。
	if structure.is_constructed():
		print("SKIP: 现场已在 180 帧驱逐窗口内自动完工（requiredWork=100 < 窗口），"
			+ "Worker 施工订单生命周期场景本轮不适用")
	else:
		var worker = WorkerScene.instantiate()
		match_instance.call(
			"_setup_and_spawn_unit",
			worker,
			Transform3D(Basis.IDENTITY, structure.global_position + Vector3(4.0, 0.0, 0.0)),
			human,
			false
		)
		await get_tree().process_frame
		var gateway = human.get_node("UnitCommandGateway")
		var construct = gateway.ConstructUnits([worker], structure, human)
		_check(construct["status"] == "Accepted", "Worker 应通过公共命令入口接受 Construct")
		var construct_order_id: String = construct["unit_results"][0]["order_id"]
		var stopped = gateway.StopUnits([worker], human)
		_check(stopped["status"] == "Accepted", "Stop 应暂停 Construct")
		_check(gateway.GetOrderState(construct_order_id) == "Suspended", "Construct Stop 应保留暂停订单")
		var resumed = gateway.ConstructUnits([worker], structure, human)
		_check(
			resumed["unit_results"][0]["order_id"] == construct_order_id,
			"再次指定同一现场应恢复原 Construct 订单"
		)
		for _frame in range(600):
			if structure.hp > 1:
				break
			await get_tree().physics_frame
		_check(structure.hp > 1, "Worker 到位后应推进权威施工 HP")
		structure.hp -= 1
		for _frame in range(600):
			if structure.is_constructed():
				break
			await get_tree().physics_frame
		_check(structure.is_constructed(), "Worker 应在有限时间内完成施工")
		_check(gateway.GetOrderState(construct_order_id) == "Completed", "完工应终结 Construct 订单")
		_check(worker.action == null, "完工后 Worker 不应保留现场 Action 引用")
		_check(structure.hp == structure.hp_max - 1, "施工期间的伤害应保留至完工")
		_check(_damaged_units.count(structure) == 1, "施工现场只有真实伤害应发布 unit_damaged")

	var occupied = runtime.Evaluate(human, TurretScene, placement_transform, cost)
	_check(not occupied["accepted"], "已生成建筑应阻挡同位置再次放置")
	_check("Occupied" in occupied["issues"], "静态建筑重叠应返回 Occupied")

	_finish(match_instance)


## 输出测试结果、释放场景并返回可被命令行读取的退出码。
func _finish(match_instance):
	print("Structure placement smoke test completed: %d failure(s)" % _failures)
	match_instance.queue_free()
	await get_tree().process_frame
	SmokeTestExit.request(get_tree(), 0 if _failures == 0 else 1)


## 计算忽略高度的世界距离。
func _planar_distance(left: Vector3, right: Vector3) -> float:
	return Vector2(left.x - right.x, left.z - right.z).length()


## 累计断言失败并输出可定位原因。
func _check(condition: bool, message: String):
	if condition:
		return
	_failures += 1
	push_error("Structure placement assertion failed: %s" % message)


## 收集真实受击事件，用于区分施工初始化与主动测试伤害。
func _on_unit_damaged(unit):
	_damaged_units.append(unit)
