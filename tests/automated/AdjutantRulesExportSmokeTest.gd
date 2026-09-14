extends Node

## 副官双层改造第一阶段：动态规则导出冒烟测试。
## 验证规则视图完全来自当前 Match 实际加载的 Catalog：
## 稳定 ID、显示名关联、实际能力、移动/攻击域、成本、动态生产关系、
## 施工定义、受信任场景映射、来源指纹；未知机制显式 unsupported。

const MatchScene = preload("res://tests/manual/TestAllUnits.tscn")
## 本冒烟对着的实际配置（断言里的期望值一律从这里派生，不硬编码条数）。
const DEMO_BALANCE := "res://config/balance/demo.balance.v1.json"

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
	# 【不许硬编码条数】期望值必须从**实际加载的配置**派生。
	# 2026-09-13 收工自检发现：这里原写死 `== 11`，而 `demo.balance.v1.json` 在 09-12 已扩到
	# 14 种实体（新增 transport_truck / apc / heavy_tank）→ 断言长期为红，与"配置驱动"的本意相反。
	var expected_types := _config_count(DEMO_BALANCE, "unitTypes")
	_check(expected_types > 0, "应能读到 Demo 平衡配置（否则断言无意义）")
	_check(types.size() == expected_types,
		"规则视图应导出配置里的全部 %d 种实体类型（实际 %d）" % [expected_types, types.size()])

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
	var expected_productions := _config_count(DEMO_BALANCE, "productions")
	_check(expected_productions > 0, "应能读到 Demo 平衡配置里的生产定义")
	# 导出口径本来就按"生产者类型在本局可用"过滤，所以允许**少于**配置条数，
	# 但**任何一条都不许凭空多出来**（多于配置 = 伪造）。
	_check(productions.size() <= expected_productions and productions.size() > 0,
		"生产定义条数应在 (0, %d] 之间（实际 %d）" % [expected_productions, productions.size()])
	print("[rules-smoke] 实体类型 %d/%d，生产定义 %d/%d（期望来自配置）"
		% [types.size(), expected_types, productions.size(), expected_productions])

	# 作战单位口径的**输入自证**：副官的"作战单位"= 这里有 `attack` 能力的类型
	# （唯一实现 `rules_fallback.combat_types_from_rules`，它要求**能力字段齐全**才派生，
	# 缺一个就回退硬编码常量 —— 那种回退是隐蔽的退化，所以这里钉死"一个都不许缺"）。
	var armed: Array = []
	var mobile_armed: Array = []
	var immobile_armed: Array = []
	var missing_caps: Array = []
	for id in types.keys():
		var caps = (types[id] as Dictionary).get("capabilities")
		if not (caps is Dictionary):
			missing_caps.append(id)
			continue
		if not bool((caps as Dictionary).get("attack", false)):
			continue
		armed.append(id)
		# "能打" ≠ "是兵力"：固定炮塔也能打，但它不占兵力上限、也不该被派去行军。
		if bool((caps as Dictionary).get("move", false)):
			mobile_armed.append(id)
		else:
			immobile_armed.append(id)
	print("[rules-smoke] 能打的类型=%s" % [armed])
	print("[rules-smoke] 其中可机动（占兵力上限）=%s；不可机动（固定防御，不算兵力）=%s"
		% [mobile_armed, immobile_armed])
	_check(missing_caps.is_empty(),
		# ⚠️ 这里**不能用 `% missing_caps`**：GDScript 把数组当作参数表，
		# 空数组 ⇒ "not enough arguments for format string"（测试越是通过越报错）。
		"导出必须给**每个**单位类型带 capabilities，否则作战单位口径只能回退常量：" + str(missing_caps))
	_check(mobile_armed.size() > 0, "至少应有一种**可机动**的作战单位类型")
	_check(immobile_armed.size() > 0,
		"固定防御（炮塔）应存在且**不带** move 能力——否则它会被当成兵力、还会被派去行军")
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
	# 【不许硬编码条数】与上面的实体类型同口径：期望值从实际加载的配置派生。
	# 2026-09-14 收工自检发现：这里原写死 `== 6`，而配置在 `1463d9b`（机枪塔）后已变 7 条施工定义
	# ⇒ 断言长期为红。导出口径遍历 `catalog.Constructions` 不过滤，故应与配置**逐条相等**。
	var expected_constructions := _config_count(DEMO_BALANCE, "constructions")
	_check(expected_constructions > 0, "应能读到 Demo 平衡配置里的施工定义")
	_check(constructions.size() == expected_constructions,
		"应导出配置里的全部 %d 条施工定义（实际 %d）" % [expected_constructions, constructions.size()])
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


## 读配置里某个数组的条数（**期望值的唯一来源**；读不到返回 -1 让断言明确失败）。
func _config_count(path: String, key: String) -> int:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return -1
	var parsed = JSON.parse_string(file.get_as_text())
	file.close()
	if not (parsed is Dictionary):
		return -1
	var items = (parsed as Dictionary).get(key)
	return (items as Array).size() if items is Array else -1


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
