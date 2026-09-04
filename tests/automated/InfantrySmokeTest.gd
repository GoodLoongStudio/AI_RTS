extends Node

const MatchScene = preload("res://tests/manual/TestAllUnits.tscn")
const InfantryScene = preload("res://source/match/units/Infantry.tscn")
const InfantryScript = preload("res://source/match/units/Infantry.gd")
const BarracksScene = preload("res://source/match/units/Barracks.tscn")

var _failures := 0
var _produced_units := []


## 验证步兵生产入队、按平衡部署、单位配置与移动命令链路。
func _ready():
	MatchSignals.unit_production_finished.connect(_on_unit_production_finished)
	var match_instance = MatchScene.instantiate()
	add_child(match_instance)
	await get_tree().process_frame
	await get_tree().process_frame

	var human = match_instance.get_node("Players/Human")
	var command_center = human.get_node("CommandCenter")
	# 期 2：步兵生产迁移到兵营——现场部署一座已完工兵营
	var barracks = BarracksScene.instantiate()
	barracks.global_transform = Transform3D(
		Basis(), command_center.global_position + Vector3(4, 0, 0)
	)
	human.add_child(barracks)
	MatchSignals.setup_and_spawn_unit.emit(barracks, barracks.global_transform, human)
	barracks._construction_progress = 1.0
	var queue = barracks.production_queue
	var runtime = match_instance.get_node("ProductionRuntime")
	_check(
		human.add_resources({"resource_a": 3000, "resource_b": 3000}, "ScriptedAdjustment"),
		"测试资源注入应成功"
	)

	var soldier_cost = match_instance.get_node("BalanceConfigRuntime").GetProductionCost(
		InfantryScene
	)
	_check(soldier_cost != null and int(soldier_cost.get("resource_a", 0)) == 150,
		"步兵生产成本应从平衡配置读到 A×150")

	_check(queue.produce(InfantryScene) != null, "步兵应成功进入指挥中心生产队列")
	var first = queue.get_elements()[0] if queue.size() > 0 else null
	_check(first != null, "队首应为步兵生产项")

	var elapsed_seconds := 0.0
	while _produced_units.is_empty() and elapsed_seconds < 22.0:
		await get_tree().create_timer(0.1).timeout
		elapsed_seconds += 0.1
	_check(_produced_units.size() == 1, "步兵应在有限时间内只部署一次")
	if _produced_units.is_empty():
		print("Infantry deployment diagnostic: ", runtime.GetQueue(barracks))
		print("Infantry queue smoke test completed: %d failure(s)" % _failures)
		match_instance.queue_free()
		await get_tree().process_frame
		SmokeTestExit.request(get_tree(), 1)
		return

	var soldier = _produced_units[0]
	print("INFANTRY_DEBUG produced=", _produced_units, " valid=", is_instance_valid(soldier))
	_check(is_instance_valid(soldier), "部署的步兵引用应有效")
	_check(soldier.get_script() == InfantryScript, "部署单位应挂 Infantry 脚本")
	_check(soldier.is_in_group("units"), "部署步兵应加入 units 分组")
	_check(soldier.find_child("Movement") != null, "步兵应具备 Movement trait")
	_check(soldier.get_node_or_null("Geometry/ProjectileOrigin") != null, "步兵应有弹道锚点")

	var destination = soldier.global_position + Vector3(3, 0, 0)
	var gateway = human.get_node("UnitCommandGateway")
	var move_result = gateway.ForceMoveUnits([soldier], destination, human)
	var move_accepted: bool = move_result.get("unit_results", []).any(
		func(item): return item.get("accepted", false)
	)
	_check(move_accepted, "步兵应接受移动命令")
	await get_tree().create_timer(1.5).timeout
	_check(
		soldier.global_position.distance_to(destination) < 1.5,
		"步兵应移动接近目标点"
	)

	print("Infantry smoke test completed: %d failure(s)" % _failures)
	match_instance.queue_free()
	await get_tree().process_frame
	SmokeTestExit.request(get_tree(), 0 if _failures == 0 else 1)


func _on_unit_production_finished(unit, _producer):
	# 生产者节点在部署时会被 Match 重命名（Unit_N），按产品脚本判定更可靠
	if unit.get_script() == InfantryScript:
		_produced_units.append(unit)


func _check(condition: bool, message: String):
	if condition:
		return
	_failures += 1
	push_error("Infantry assertion failed: %s" % message)
