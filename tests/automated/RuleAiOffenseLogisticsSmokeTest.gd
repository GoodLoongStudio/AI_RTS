extends Node

const MatchScene = preload("res://tests/manual/TestPlayerVsAI.tscn")
const VehicleFactoryScene = preload("res://source/match/units/VehicleFactory.tscn")
const ManagedGcTestHook = preload("res://tests/automated/ManagedGcTestHook.cs")
const FIELD_POSITION := 1 << 0
const FIELD_TYPE := 1 << 1
const FIELD_CONSTRUCTION := 1 << 4
const FIELD_PRODUCTION := 1 << 5
const VEHICLE_FACTORY_TYPE_ID := "vehicle_factory"
const TANK_TYPE_ID := "tank"

var _failures := 0


## 验证规则 AI 通过公共查询、放置与生产边界建立并补充进攻生产后勤。
func _ready():
	var match_instance = MatchScene.instantiate()
	var rule_ai = match_instance.get_node("Players/SimpleClairvoyantAI")
	rule_ai.expected_number_of_workers = 2
	rule_ai.expected_number_of_ag_turrets = 0
	rule_ai.expected_number_of_aa_turrets = 0
	rule_ai.expected_number_of_battlegroups = 1
	rule_ai.expected_number_of_units_in_battlegroup = 1
	rule_ai.primary_offensive_structure = 0
	rule_ai.secondary_offensive_structure = 1
	add_child(match_instance)
	await get_tree().process_frame
	await get_tree().physics_frame
	await get_tree().process_frame

	var income_applied: bool = rule_ai.add_resources(
		{"resource_a": 10000, "resource_b": 10000},
		"ScriptedAdjustment"
	)
	_check(income_applied,
		"测试资源应通过权威账户成功注入")

	var factory_blueprint: Dictionary = {}
	for _attempt in range(120):
		await get_tree().physics_frame
		await get_tree().physics_frame
		var own_entities := _get_own_entities(rule_ai)
		var factories: Array = own_entities.filter(
			func(entity): return entity.get("type_id", "") == VEHICLE_FACTORY_TYPE_ID
		)
		if factories.is_empty():
			continue
		factory_blueprint = factories[0]
		break

	_check(not factory_blueprint.is_empty(),
		"OffenseController 应通过稳定类型放置 VehicleFactory")
	if not factory_blueprint.is_empty():
		var blueprint_node = _find_owned_node_by_id(rule_ai, factory_blueprint["id"])
		_check(blueprint_node != null, "测试应能按稳定 ID 定位生产建筑蓝图")
		if blueprint_node != null:
			blueprint_node.queue_free()
			await get_tree().process_frame

	var own_before_injection := _get_own_entities(rule_ai)
	var command_centers: Array = own_before_injection.filter(
		func(entity): return entity.get("type_id", "") == "command_center"
	)
	_check(not command_centers.is_empty(), "测试需要规则 AI 的初始 CommandCenter")
	var completed_factory = VehicleFactoryScene.instantiate()
	var factory_transform := Transform3D(
		Basis.IDENTITY,
		command_centers[0]["position"] + Vector3(6.0, 0.0, 0.0)
	)
	MatchSignals.setup_and_spawn_unit.emit(
		completed_factory,
		factory_transform,
		rule_ai,
		false
	)
	await get_tree().process_frame
	await get_tree().physics_frame

	var completed_factory_id := ""
	var production_planned := false
	for _attempt in range(120):
		await get_tree().physics_frame
		await get_tree().physics_frame
		var factories: Array = _get_own_entities(rule_ai).filter(
			func(entity):
				return (
					entity.get("type_id", "") == VEHICLE_FACTORY_TYPE_ID
					and entity.get("construction", null) != null
					and entity["construction"].get("state", "") == "Completed"
				)
		)
		if factories.is_empty():
			continue
		completed_factory_id = factories[0]["id"]
		production_planned = factories[0]["production"].get("items", []).any(
			func(item): return item.get("product_type_id", "") == TANK_TYPE_ID
		)
		if production_planned:
			break
	_check(production_planned,
		"OffenseController 应只向完工工厂按稳定 Producer ID 加入 Tank")

	if not completed_factory_id.is_empty():
		var completed_factory_node = _find_owned_node_by_id(rule_ai, completed_factory_id)
		_check(completed_factory_node != null, "测试应能按稳定 ID 定位已完工工厂")
		if completed_factory_node != null:
			completed_factory_node.queue_free()
			await get_tree().process_frame
			var replacement_found := false
			for _attempt in range(120):
				await get_tree().physics_frame
				await get_tree().physics_frame
				var replacements: Array = _get_own_entities(rule_ai).filter(
					func(entity):
						return (
							entity.get("type_id", "") == VEHICLE_FACTORY_TYPE_ID
							and entity.get("id", "") != completed_factory_id
						)
				)
				if not replacements.is_empty():
					replacement_found = true
					break
			_check(replacement_found,
				"生产建筑损失后应由定时己方查询发现缺口并重新放置")

	print("Rule AI offense logistics smoke test completed: %d failure(s)" % _failures)
	match_instance.queue_free()
	await get_tree().process_frame
	await get_tree().process_frame
	var managed_gc_hook = ManagedGcTestHook.new()
	managed_gc_hook.CollectPendingFinalizers()
	SmokeTestExit.request(get_tree(), 0 if _failures == 0 else 1)


## 返回规则 AI 当前生产后勤所需的己方观察字段。
func _get_own_entities(rule_ai) -> Array:
	var result: Dictionary = rule_ai.get("_world_query_runtime").GetOwnForces(
		rule_ai.get("_query_session_id"),
		FIELD_POSITION | FIELD_TYPE | FIELD_CONSTRUCTION | FIELD_PRODUCTION
	)
	if result.get("status", "") != "Accepted":
		return []
	return result["entities"]


## 仅供自动测试把公开稳定 ID 对应回场景节点，以模拟建筑损失。
func _find_owned_node_by_id(rule_ai, entity_id: String):
	for unit in get_tree().get_nodes_in_group("units"):
		var reference: Dictionary = (
			rule_ai
			. get("_world_query_runtime")
			. GetOwnEntityReferenceForTests(unit, rule_ai)
		)
		if reference.get("id", "") == entity_id:
			return unit
	return null


## 累计断言失败并输出可定位原因。
func _check(condition: bool, message: String):
	if condition:
		return
	_failures += 1
	print("FAIL: %s" % message)
	push_error(message)
