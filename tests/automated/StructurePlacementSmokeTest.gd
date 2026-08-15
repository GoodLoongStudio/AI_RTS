extends Node

const MatchScene = preload("res://tests/manual/TestOneUnit.tscn")
const TurretScene = preload("res://source/match/units/AntiGroundTurret.tscn")
const WorkerScene = preload("res://source/match/units/Worker.tscn")

var _failures := 0
var _damaged_units := []


## 验证视野门槛、统一最终复验、资源扣款和友军安全驱逐纵向链路。
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
		human.add_resources({"resource_a": 10, "resource_b": 10}, "ScriptedAdjustment"),
		"测试资源注入应成功"
	)

	var hidden_transform = Transform3D(Basis.IDENTITY, Vector3(45.0, 0.0, 45.0))
	var hidden = runtime.Evaluate(human, TurretScene, hidden_transform, cost)
	_check(not hidden["accepted"], "视野外 footprint 不得允许放置")
	_check("NotVisible" in hidden["issues"], "视野外候选应返回 NotVisible")
	_check(
		not "Occupied" in hidden["issues"],
		"视野不足时不得通过完整问题集合泄漏占用状态"
	)

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
	var required_distance: float = tank.radius + structure.radius
	_check(
		_planar_distance(tank.global_position, structure.global_position) > required_distance,
		"被覆盖的友军应移动到建筑 footprint 外并待命"
	)
	_check(not structure in _damaged_units, "施工初始化与新增 HP 不应误发 unit_damaged")

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
	get_tree().quit(0 if _failures == 0 else 1)


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
