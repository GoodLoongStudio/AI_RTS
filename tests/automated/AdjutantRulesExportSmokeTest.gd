extends Node

## 副官双层改造第一阶段：动态规则导出冒烟测试。
## 验证规则视图完全来自当前 Match 实际加载的 Catalog：
## 稳定 ID、显示名关联、实际能力、移动/攻击域、成本、动态生产关系、
## 施工定义、受信任场景映射、来源指纹；未知机制显式 unsupported。

const MatchScene = preload("res://tests/manual/TestAllUnits.tscn")

var _failures := 0


func _ready():
	var match_instance = MatchScene.instantiate()
	add_child(match_instance)
	await get_tree().process_frame
	await get_tree().process_frame

	# 动态挂载 C# 观测运行时（与 DebugControlServer._mount_adjutant_observation 同路径）。
	var observation = _mount_observation()
	_check(observation != null, "AdjutantObservationRuntime 应可动态挂载")

	var match_id: String = str(observation.ResolveMatchId(match_instance))
	_check(not match_id.is_empty(), "统一经济运行时应提供稳定 match_id")

	var rules: Dictionary = observation.ExportRules(match_instance)
	_check(not rules.has("error"), "正常配置下规则视图不应报错")
	_check(rules.get("schema_version", 0) == 1, "规则视图 schema_version 应为 1")

	var rules_version: Dictionary = rules.get("rules_version", {})
	_check(
		rules_version.get("schema_version", 0) == 1
		and str(rules_version.get("content_version", "")) == "demo-baseline-2026-08-12"
		and str(rules_version.get("content_hash", "")).length() >= 8,
		"规则版本应携带 schema/content version 与内容指纹"
	)
	_check(
		str(rules.get("balance_config_path", "")) == "res://config/balance/demo.balance.v1.json",
		"来源指纹应指向实际加载的平衡配置路径"
	)

	var types := _index_by_id(rules.get("unit_types", []))
	_check(types.has("worker") and types.has("tank") and types.has("command_center"),
		"规则视图应包含 Demo 稳定类型 ID")
	_check(types.size() == 11, "Demo 配置应导出全部 11 种实体类型")

	var tank: Dictionary = types.get("tank", {})
	_check(str(tank.get("display_name", "")) == "tank",
		"当前工程无本地化资源时 display_name 暂等于稳定 ID（偏差已记录）")
	_check(float(tank.get("max_hp", 0.0)) == 10.0 and float(tank.get("sight_range", 0.0)) == 8.0,
		"tank 数值应来自当前 Catalog")
	var tank_caps: Dictionary = tank.get("capabilities", {})
	_check(
		bool(tank_caps.get("move", false)) and bool(tank_caps.get("attack", false))
		and not bool(tank_caps.get("gather", false)) and bool(tank_caps.get("force_fire_ground", false)),
		"tank 实际能力应按 Catalog 导出（可移动/可攻击/不可采集/可强制攻击地面）"
	)
	var tank_movement: Dictionary = tank.get("movement", {})
	_check(str(tank_movement.get("domain", "")) == "terrain",
		"tank 移动域应为 terrain（协议字符串）")
	_check(not str(tank.get("scene_path", "")).is_empty()
		and str(tank.get("scene_path", "")).begins_with("res://"),
		"场景路径必须来自受信任 manifest 映射，模型不得构造任意资源路径")

	var worker: Dictionary = types.get("worker", {})
	var worker_caps: Dictionary = worker.get("capabilities", {})
	_check(
		bool(worker_caps.get("gather", false)) and bool(worker_caps.get("construct", false))
		and not bool(worker_caps.get("attack", false)),
		"worker 应导出采集+施工能力且无攻击能力"
	)
	_check(int(worker.get("gatherer_carry_capacity", 0)) == 100,
		"worker 载荷应来自 Catalog")
	var command_center: Dictionary = types.get("command_center", {})
	_check(
		bool((command_center.get("capabilities", {}) as Dictionary).get("produce", false))
		and int(command_center.get("producer_queue_limit", 0)) == 5,
		"command_center 应导出生产能力与队列容量"
	)

	# 动态生产关系：产品 → 成本 → 允许生产者（不硬编码名单）。
	var productions := _index_by_id(rules.get("productions", []))
	_check(productions.size() == 5, "Demo 应导出 5 条生产定义")
	var tank_production: Dictionary = productions.get("tank", {})
	_check(
		str(tank_production.get("product_type_id", "")) == "tank"
		and _cost_amount(tank_production.get("cost", []), "A") == 500,
		"tank 生产成本应来自当前对局 Catalog（A×500）"
	)
	var tank_producers: Array = tank_production.get("allowed_producer_type_ids", [])
	_check(
		tank_producers.size() == 1 and str(tank_producers[0]) == "vehicle_factory",
		"tank 生产关系应动态解析为 vehicle_factory"
	)

	var constructions := _index_by_id(rules.get("constructions", []))
	_check(constructions.size() == 6, "Demo 应导出 6 条施工定义")
	var factory_construction: Dictionary = constructions.get("vehicle_factory", {})
	_check(
		_cost_amount(factory_construction.get("cost", []), "A") == 600
		and float(factory_construction.get("footprint_radius_meters", 0.0)) == 1.5
		and str(factory_construction.get("blueprint_scene_path", "")).begins_with("res://"),
		"vehicle_factory 施工定义应带成本/占地/受信任蓝图场景"
	)

	var resources := {}
	for resource in rules.get("resources", []):
		resources[str((resource as Dictionary).get("kind", ""))] = resource
	_check(resources.has("A") and resources.has("B"), "资源定义应导出 A/B 两种")

	var skills: Array = rules.get("skills", [])
	var all_uncallable := true
	for skill in skills:
		if bool((skill as Dictionary).get("adjutant_callable", true)):
			all_uncallable = false
	_check(not skills.is_empty() and all_uncallable,
		"第一阶段命令协议未实现技能动作：全部技能应显式标记副官不可调用")

	# 未知机制 unsupported：不存在于 Catalog 的类型不得伪造出现。
	_check(not types.has("future_mechanism"),
		"规则视图只表达 Catalog 实际存在的内容，未知机制显式缺失")

	print("Adjutant rules export smoke test completed: %d failure(s)" % _failures)
	match_instance.queue_free()
	await get_tree().process_frame
	SmokeTestExit.request(get_tree(), 0 if _failures == 0 else 1)


func _mount_observation():
	var script: Script = load(
		"res://source/csharp/GodotAdapter/Adjutant/AdjutantObservationRuntime.cs"
	) as Script
	if script == null:
		return null
	var node := Node.new()
	node.set_script(script)
	add_child(node)
	return node


func _index_by_id(items: Array) -> Dictionary:
	var result := {}
	for item in items:
		if item is Dictionary:
			result[str((item as Dictionary).get("id", ""))] = item
	return result


func _cost_amount(costs: Array, kind: String) -> int:
	for cost in costs:
		var entry := cost as Dictionary
		if str(entry.get("kind", "")) == kind:
			return int(entry.get("amount", 0))
	return -1


func _check(condition: bool, message: String):
	if condition:
		return
	_failures += 1
	push_error("Adjutant rules export assertion failed: %s" % message)
