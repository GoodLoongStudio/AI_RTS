class_name ProductionCatalog
extends RefCounted

## 生产面板数据适配层：把「单位 / 建筑配置」规范化为生产 UI 可直接消费的统一结构。
##
## 本文件是**只读适配层**：不新增玩法数据、不写任何状态、不注册 autoload、不用 get_node。
## 全部入口都是 static，调用方可以是任意 UI 脚本。
## 返回值一律是深拷贝（与 GrowthStore.get_profile_snapshot 同约定），UI 改它不会污染缓存。
##
## ============================ 数据来源与推导依据 ============================
##
## 1) 结构骨架（有哪些条目、条目叫什么、归哪个页签）
##    ← source/match/hud/ra3/Ra3Sidebar.gd:31-74 常量 TABS（**UI 侧唯一权威清单**）
##      运行期用 load(SIDEBAR_SCRIPT)。get_script_constant_map()["TABS"] 读取，
##      刻意**不在本文件复制第二份 TABS**：清单一旦分叉，
##      tests/automated/NetInfantrySmokeTest.gd 与 UnitRegistrationConsistencySmokeTest.gd
##      依赖的 id/items 结构就会与生产面板对不上（同类问题仓库里已有前科）。
##      display_name ← TABS[].items[].caption；category ← TABS[].id；
##      页签级 place/producer/producer_caption 下放合并进每个条目，
##      **完全复刻 Ra3Sidebar.gd:459-465 的合并规则**（item 自带 producer 时不被页签默认值覆盖，
##      例如"工人"走主基地而非车厂）。
##
## 2) unit_id（稳定标识）
##    ← config/godot/demo.assets.v1.json:4-80 unitAssets[].unitTypeId
##      （scenePath → 稳定 UnitTypeId，与 C# GodotAssetManifest 读同一份文件）。
##      查不到时退化为场景文件名 to_snake_case()，并在 missing_fields 登记 "unit_id"。
##    scene_path ← TABS 条目的 scene；blueprint_scene_path ← 同文件的 blueprintScenePath。
##
## 3) cost
##    ← config/balance/demo.balance.v1.json
##        生产的单位：productions[]（:386-527）的 cost[]
##        建造的建筑：constructions[]（:528-620）的 cost[]
##      形状与 C# BalanceConfigRuntime.cs:286-299 ToLegacyCosts 完全一致：{"resource_a","resource_b"}。
##      ⚠ demo 配置只有 kind=A；resource_b 恒 0 是**真实的"无 B 成本"**，不是缺失——
##        Ra3Sidebar.gd:600 注释已说明"历史 B 成本已折算并入"。
##      （C# 公开接口 BalanceConfigRuntime.cs:150 GetProductionCost / :158 GetConstructionCost
##        是同一份数据的运行时版本；本文件直接读 JSON，因为 static 函数拿不到 Match 节点。）
##
## 4) stats（真实单位属性，读不到就是 null，绝不填 0）
##    stats.hp             ← unitTypes[].maxHp（:137-385）
##    stats.sight          ← unitTypes[].sightRangeMeters
##    stats.speed          ← unitTypes[].movement.speedMetersPerSecond
##                            （无 movement 的建筑天然没有该数据 → null + missing）
##    stats.range          ← unitTypes[].weaponIds[0] → weapons[]（:24-136）rangeMeters
##    stats.damage         ← 同上 baseDamage
##    stats.attack_interval← 同上 cooldownMilliseconds / 1000
##                            （与 BalanceConfigRuntime.cs:142-144 同口径）
##    stats.armor          ← **不存在**。全仓库（config/balance + C# Domain + config/growth_definitions.json）
##                            没有任何单位护甲概念，只有一条名叫 construction_armor 的成长升级。
##                            → 恒为 null + missing_fields "stats.armor"。
##
## 5) 推导字段 derived_fields（公式写在代码里，可逐条复核）
##    build_time = requiredWork / 60.0  （秒）
##      依据是**项目自身的既有换算**，不是新造的常数：
##        · source/match/units/traits/ProductionQueue.gd:15-17 `time_total = required_work / 60.0`
##        · C# ProductionService.cs:222 每个仿真 tick 只 +1 工作量；
##          ProductionRuntime.cs:272 `CurrentTick() = Engine.GetPhysicsFrames()`；
##          project.godot [physics] 未覆盖 physics_ticks_per_second → Godot 默认 60 Hz
##    role      = 由**结构性事实**机械映射（见 _derive_role 的优先级表）；无任何信号 → null
##    counters  = 主武器 weapons[].targetDomains（"terrain"/"air"）。
##                这是本项目**真实存在**的"能打什么"字段；无武器 → 空数组（真的什么都克制不了）。
##                ⚠ 它是"可打击域"，**不等于**完整克制矩阵（克制还要看护甲/伤害类型，本项目没有）。
##
## 6) 缺失概念 missing_fields（值一律 null，**绝不填 0**，让 UI 能画出"未知"而不是假数据）
##    description / energy_cost / tech_level / unlock_condition / max_count / adjutant_tags
##    stats.armor / 该条目确实没有的 stats.* / 图标文件不存在的 icon
##    已按仓库范围确认**不存在**：科技等级、数量上限、能源消耗、维护费、单位护甲、
##    单位文字描述、副官标签。
##    ⚠ 唯一**真实存在**的"解锁 / 门槛"数据是 productions[].allowedProducerUnitTypeIds
##      （:397-399 等）= 「必须拥有该生产建筑」，它被放在 production_source.producer_unit_type_ids 里，
##      **不冒充** tech_level / unlock_condition（本项目没有科技树）。
##
## 7) state_of 是 **UI 侧粗判**，权威判定永远在 C#（ProductionService.cs:73 的
##    `queue.Count >= producer.QueueLimit`、EconomyRuntime 的资源账户等）。
##    本项目**没有**数量上限、也没有"受损影响生产"的语义，对应状态不会假装判定成功。
##
## 8) hermes_advice 的数据源是 GrowthStore 的画像快照
##    （source/growth/GrowthStore.gd:132 get_profile_snapshot()；GrowthStore 在 project.godot [autoload] 注册）。
##    画像由 source/growth/MatchReportAdapter.gd 生成：:44 generated_at、:47 preferred_strategies、
##    :49 recommended_adjutants、:52 model_version="local-baseline-1"（**本地基线适配器，不是 LLM 实时推理**）。
##    **硬约束：建议只出现在 recommendations 里，绝不混进 stats。**
## ==========================================================================

## 与 C# BalanceConfigRuntime.cs:15-22 的默认路径保持一致。
const BALANCE_CONFIG_DEFAULT := "res://config/balance/demo.balance.v1.json"
const ASSET_MANIFEST_DEFAULT := "res://config/godot/demo.assets.v1.json"
## UI 侧权威清单的宿主脚本（只读，绝不修改它）。
const SIDEBAR_SCRIPT_PATH := "res://source/match/hud/ra3/Ra3Sidebar.gd"

## 队列容量兜底值：与 C# Domain/Production/Production.cs:74 的默认值 5 一致。
const QUEUE_LIMIT_DEFAULT := 5
## 工作量 → 时间的换算基准（见文件头第 5 条）。
const PHYSICS_TICKS_PER_SECOND := 60.0

## 图标查找顺序：先 Ra3Sidebar 自己在用的目录，再 assets/ui/icons（PascalCase）。
const ICON_DIR_RA3 := "res://source/match/hud/ra3/icons"
const ICON_DIR_UI := "res://assets/ui/icons"

## state_of 允许返回的状态（与 UI 契约一致）。用 Array 而不是 PackedStringArray：
## const 只接受常量表达式，Packed* 构造器不保证可常量折叠。
const STATES := [
	"ready", "insufficient_resource", "queue_full", "unlocked_off", "producing", "maxed", "damaged",
]

## 构建结果缓存：{"entries", "by_id", "categories", "queue_limits"}。
static var _cache: Dictionary = {}


# ------------------------------------------------------------------ 公开 API

## 全部生产分类（当前 4 个：建筑 / 步兵 / 载具 / 飞机）。
## 每个分类：{ id, name, place, producer_caption, producer_unit_type_id,
##            producer_scene_path, item_ids, item_count }
static func categories() -> Array[Dictionary]:
	_ensure_built()
	var out: Array[Dictionary] = []
	for row in _cache.get("categories", []):
		out.append((row as Dictionary).duplicate(true))
	return out


## 某分类下的全部条目（完整 schema，见文件头）。
static func entries(category_id: String) -> Array[Dictionary]:
	_ensure_built()
	var out: Array[Dictionary] = []
	for row in _cache.get("entries", []):
		if str((row as Dictionary).get("category", "")) == category_id:
			out.append((row as Dictionary).duplicate(true))
	return out


## 按 unit_id 查单个条目；未知 id 返回空 Dictionary（调用方用 is_empty() 判）。
static func entry(item_id: String) -> Dictionary:
	_ensure_built()
	var index: Dictionary = _cache.get("by_id", {})
	if not index.has(item_id):
		return {}
	var rows: Array = _cache.get("entries", [])
	var position: int = int(index[item_id])
	if position < 0 or position >= rows.size():
		return {}
	return (rows[position] as Dictionary).duplicate(true)


## 只取 stats 子字典；未知 id 返回空 Dictionary。
## 读不到的属性是 null（不是 0），对应 key 同时登记在 missing_fields 里。
static func stats_of(item_id: String) -> Dictionary:
	var row := entry(item_id)
	if row.is_empty():
		return {}
	return row["stats"]


## UI 侧**粗判**生产状态 → { state, reason, available_actions }。
## context 约定字段：{ player: Node, producer: Node, queue_items: Array }；
## 另外支持两个可选字段：has_worker: bool（建造页签用）、queue_limit: int（覆盖配置上限）。
##
## 容错规则：**用 context.has(key) 区分「调用方没给」和「真的没有」**。
##   · 没给 → 不做该判定，reason 里明确写"未知"，宁可返回 ready 也不假装判定成功；
##   · 给了但为 null/失效 → 那是真的没有生产建筑，返回 unlocked_off。
static func state_of(item_id: String, context: Dictionary) -> Dictionary:
	var row := entry(item_id)
	if row.is_empty():
		return _state_result("ready", "未知条目 %s：无该状态数据" % item_id, [])

	var source: Dictionary = row["production_source"]
	var place := str(source.get("mode", "produce")) == "place"
	var primary_action := "place" if place else "produce"

	var has_producer_key := context.has("producer")
	var producer = context.get("producer", null)
	var producer_valid := _is_valid_node(producer)

	var has_queue_key := context.has("queue_items")
	var has_player_key := context.has("player")

	# 1) 该项是否已在当前生产队列里 → producing（可取消）。
	#    **必须排在"没有生产建筑"之前**：队列里已经有它，是"正在生产"的正面证据；
	#    若调用方给的 producer 与实际排队的那座建筑不一致（多座同型建筑/传错引用），
	#    报 producing 比报 unlocked_off 更接近事实，也才给得出"取消"这个真实可用动作。
	if has_queue_key and _queue_contains(row, context.get("queue_items", null)):
		return _state_result(
			"producing", "该单位已在生产队列中（可取消排队）", [primary_action, "cancel"]
		)

	# 2) 生产建筑真的不存在（≠ 调用方没给）→ unlocked_off。
	#    判据与 Ra3Sidebar.gd:860-897 的页签/格子禁用逻辑同源。
	if has_producer_key and not producer_valid:
		if place:
			# 结构物走蓝图放置，不需要生产建筑；改看工人。工人数据只有调用方知道。
			if context.has("has_worker") and not bool(context.get("has_worker")):
				return _state_result("unlocked_off", "没有可用的工人：无法开工建造", [])
		else:
			var caption := str(source.get("producer_caption", "生产建筑"))
			return _state_result(
				"unlocked_off", "没有可用的%s：需先拥有该生产建筑" % caption, []
			)

	# 3) 队列容量 → queue_full。上限来自配置，最终判定仍在 C#（ProductionService.cs:73）。
	if producer_valid:
		var queue_limit := _queue_limit_for(row, producer, context)
		var queue_size := _live_queue_size(producer)
		if queue_size >= 0 and queue_size >= queue_limit:
			return _state_result(
				"queue_full", "生产队列已满（%d/%d）" % [queue_size, queue_limit], []
			)

	# 4) 资源 → insufficient_resource（只比 resource_a，与 Ra3Sidebar.gd:903 同口径）。
	if has_player_key:
		var player = context.get("player", null)
		var cost = row["cost"]
		if _is_valid_node(player) and "resource_a" in player and cost is Dictionary:
			var have := int(player.get("resource_a"))
			var need := int((cost as Dictionary).get("resource_a", 0))
			if need > have:
				return _state_result(
					"insufficient_resource", "资源不足：需要 %d，当前 %d" % [need, have], []
				)

	# 5) 生产建筑受损 → damaged。数据是真的（Unit.gd:60-63 的 hp / hp_max），
	#    但本项目**没有**"受损影响生产效率"的规则，所以 reason 里必须写明这只是提示。
	if producer_valid:
		var damage_note := _damage_note(producer)
		if not damage_note.is_empty():
			return _state_result(
				"damaged",
				("%s；注：本项目未实现受损对生产的影响，此处仅作提示" % damage_note),
				[primary_action, "repair"]
			)

	# 6) 其余情况 → ready，并明确写出"判了什么 / 没判什么"。
	#
	#    ⚠ "maxed" 永远不会返回：项目没有 max_count（数量上限）概念，
	#      没有数据支撑就不假装判定成功。
	var checked: Array[String] = []
	if has_producer_key:
		checked.append("生产建筑")
	if has_queue_key:
		checked.append("队列")
	if has_player_key:
		checked.append("资源")
	var reason := "UI 侧粗判可生产。已判定：%s。" % (
		"、".join(PackedStringArray(checked)) if not checked.is_empty() else "无"
	)
	if not has_producer_key:
		reason += "未提供 producer：生产建筑是否存在未知。"
	if not has_queue_key:
		reason += "未提供 queue_items：是否已在生产未知。"
	if not has_player_key:
		reason += "未提供 player：资源是否足够未知。"
	reason += "maxed 无数据支撑（项目无数量上限概念），故永不返回。"
	return _state_result("ready", reason, [primary_action])


## Hermes（AI 副官）建议 → { available, recommendations, basis, generated_at,
##                          model_version, source }。
##
## 数据源优先级：
##   1) context["hermes_advice"]（Array）存在 → 视为**实时**建议（source="live"）；
##   2) 传入的 profile 非空 → 用它；
##   3) 否则读 GrowthStore.get_profile_snapshot() → 这是落盘快照（source="cache"）。
## 任何一步都拿不到数据 → available=false + source="none"，**绝不编造建议**。
##
## source 取值： "live"（实时） / "cache"（缓存快照） / "none"（无数据）。
## 硬约束：建议只出现在 recommendations 里，与 entries() 的 stats 完全分离。
## `unit_id` 非空时额外返回**单位级**建议与可用性标记（见返回值的 `unit_specific`）。
static func hermes_advice(profile: Dictionary, context: Dictionary, unit_id: String = "") -> Dictionary:
	var used: Dictionary = {}
	if not profile.is_empty():
		used = profile
	if used.is_empty():
		var store = _growth_store()
		if store != null and store.has_method("get_profile_snapshot"):
			var snapshot = store.get_profile_snapshot()
			if snapshot is Dictionary:
				used = snapshot

	var recommendations: Array[Dictionary] = []
	var live = context.get("hermes_advice", null)
	var source := "none"

	if live is Array and not (live as Array).is_empty():
		source = "live"
		for advice in _array_of(live):
			var row := _advice_row(advice, source)
			if not row.is_empty():
				recommendations.append(row)
	elif not used.is_empty():
		source = "cache"
		for advice in _array_of(used.get("recommended_adjutants", null)):
			var row := _advice_row(advice, source)
			if not row.is_empty():
				row["kind"] = "adjutant"
				recommendations.append(row)
		for strategy in _array_of(used.get("preferred_strategies", null)):
			if strategy is String and not (strategy as String).is_empty():
				recommendations.append({
					"kind": "strategy",
					"title": strategy,
					"reason": "",
					"source": source,
				})

	# ---- 单位级建议（可选） ----
	#
	# ⚠️ 老实说：**项目里目前没有按单位的 Hermes 数据源**。画像快照只有
	# `recommended_adjutants` / `preferred_strategies` 这类**画像级**字段，没有任何
	# 形如"这个单位该怎么用"的记录。所以这里**只接受调用方显式传入的
	# `context["unit_advice"]`**（未来接上真正的按单位分析时走这里），
	# 拿不到就如实标 `unit_specific = false` —— 绝不把画像级建议冒充成单位级建议。
	var unit_rows: Array[Dictionary] = []
	var unit_specific := false
	if unit_id != "":
		var live_unit = context.get("unit_advice", null)
		if live_unit is Array and not (live_unit as Array).is_empty():
			for advice in _array_of(live_unit):
				var row := _advice_row(advice, "live")
				if not row.is_empty():
					row["kind"] = "unit"
					unit_rows.append(row)
			unit_specific = not unit_rows.is_empty()

	# 元数据只取自快照；实时建议不携带这些字段时保持 null，不猜。
	var raw_generated = used.get("generated_at", null)
	var generated_at = raw_generated if raw_generated is String else null
	var raw_model = used.get("model_version", null)
	var model_version = raw_model if raw_model is String else null

	return {
		"available": not recommendations.is_empty(),
		"recommendations": recommendations,
		"basis": _advice_basis(used, model_version, source),
		"generated_at": generated_at,
		"model_version": model_version,
		"source": source,
		"unit_id": unit_id,
		## false ⇒ UI 必须写"暂无针对该单位的建议"，不许拿上面的画像级建议顶替。
		"unit_specific": unit_specific,
		"unit_recommendations": unit_rows,
	}


## 本次构建是否成功拿到 UI 清单（UI 侧可据此决定要不要显示"数据不可用"）。
static func is_available() -> bool:
	_ensure_built()
	return _cache.has("entries")


# ------------------------------------------------------------------ 构建

static func _ensure_built() -> void:
	if _cache.has("entries"):
		return
	_build()


static func _build() -> void:
	var tabs := _sidebar_tabs()
	if tabs.is_empty():
		# 不写缓存：下次调用会重试，避免把一次失败永久固化。
		push_warning(
			"[ProductionCatalog] 读不到 %s 的 TABS 常量，生产目录为空。" % SIDEBAR_SCRIPT_PATH
		)
		return

	var balance: Dictionary = _load_json(_balance_config_path())
	var manifest: Dictionary = _load_json(_asset_manifest_path())

	var scene_to_id: Dictionary = {}
	var id_to_blueprint: Dictionary = {}
	for asset in _array_of(manifest.get("unitAssets", null)):
		if not (asset is Dictionary):
			continue
		var type_id := str((asset as Dictionary).get("unitTypeId", ""))
		var scene_path := str((asset as Dictionary).get("scenePath", ""))
		if type_id.is_empty() or scene_path.is_empty():
			continue
		scene_to_id[scene_path] = type_id
		id_to_blueprint[type_id] = str((asset as Dictionary).get("blueprintScenePath", ""))

	var unit_types := _index_by_id(_array_of(balance.get("unitTypes", null)))
	var weapons := _index_by_id(_array_of(balance.get("weapons", null)))

	var productions: Dictionary = {}
	for production in _array_of(balance.get("productions", null)):
		if production is Dictionary:
			productions[str((production as Dictionary).get("productUnitTypeId", ""))] = production

	var constructions: Dictionary = {}
	for construction in _array_of(balance.get("constructions", null)):
		if construction is Dictionary:
			constructions[str((construction as Dictionary).get("unitTypeId", ""))] = construction

	# queueLimit 只在建筑类 unitType 上声明（:237 附近），索引起来供 state_of 用。
	var queue_limits: Dictionary = {}
	for unit_type_id in unit_types:
		var unit_type: Dictionary = unit_types[unit_type_id]
		var producer = unit_type.get("producer", null)
		if producer is Dictionary:
			queue_limits[unit_type_id] = int(
				(producer as Dictionary).get("queueLimit", QUEUE_LIMIT_DEFAULT)
			)

	var lookups := {
		"scene_to_id": scene_to_id,
		"id_to_blueprint": id_to_blueprint,
		"unit_types": unit_types,
		"weapons": weapons,
		"productions": productions,
		"constructions": constructions,
	}

	var built_entries: Array[Dictionary] = []
	var by_id: Dictionary = {}
	var built_categories: Array[Dictionary] = []

	for tab in tabs:
		if not (tab is Dictionary):
			continue
		var tab_row: Dictionary = tab
		var category_id := str(tab_row.get("id", ""))
		var place := bool(tab_row.get("place", false))
		var tab_producer_scene := str(tab_row.get("producer", ""))
		var tab_producer_caption := str(tab_row.get("producer_caption", ""))
		var item_ids := PackedStringArray()

		lookups["place"] = place
		lookups["tab_producer_scene"] = tab_producer_scene
		lookups["tab_producer_caption"] = tab_producer_caption

		for tab_item in _array_of(tab_row.get("items", null)):
			if not (tab_item is Dictionary):
				continue
			var row := _build_entry(tab_item, category_id, lookups)
			var unit_id := str(row["unit_id"])
			item_ids.append(unit_id)
			if not by_id.has(unit_id):
				by_id[unit_id] = built_entries.size()
			built_entries.append(row)

		built_categories.append({
			"id": category_id,
			"name": str(tab_row.get("caption", "")),
			"place": place,
			"producer_caption": tab_producer_caption,
			"producer_scene_path": tab_producer_scene,
			"producer_unit_type_id": str(scene_to_id.get(tab_producer_scene, "")),
			"item_ids": item_ids,
			"item_count": item_ids.size(),
		})

	_cache["entries"] = built_entries
	_cache["by_id"] = by_id
	_cache["categories"] = built_categories
	_cache["queue_limits"] = queue_limits


## 单个条目：把 TABS 的展示信息 + balance 的真实数值合成为统一 schema。
static func _build_entry(tab_item: Dictionary, category_id: String, lookups: Dictionary) -> Dictionary:
	var scene_path := str(tab_item.get("scene", ""))
	var place := bool(lookups["place"])
	var scene_to_id: Dictionary = lookups["scene_to_id"]

	var available: Array[String] = []
	var derived: Array[String] = []
	var missing: Array[String] = []

	var unit_id := str(scene_to_id.get(scene_path, ""))
	if unit_id.is_empty():
		unit_id = _fallback_id(scene_path)
		missing.append("unit_id")
	else:
		available.append("unit_id")

	var display_name := str(tab_item.get("caption", ""))
	if display_name.is_empty():
		missing.append("display_name")
	else:
		available.append("display_name")

	var unit_type: Dictionary = lookups["unit_types"].get(unit_id, {})
	var definition: Dictionary = (
		lookups["constructions"].get(unit_id, {}) if place else lookups["productions"].get(unit_id, {})
	)

	# ---- cost（真实数据；形状对齐 C# ToLegacyCosts）----
	# 找不到对应定义时才登记 missing，**不做跨表兜底**（兜底会掩盖配置错误）。
	var cost = null
	if definition.is_empty():
		missing.append("cost")
	else:
		cost = _legacy_costs(definition.get("cost", null))
		available.append("cost")

	# ---- build_time（推导：requiredWork / 60，见文件头第 5 条）----
	var required_work = definition.get("requiredWork", null)
	var build_time = null
	if required_work is int or required_work is float:
		build_time = float(required_work) / PHYSICS_TICKS_PER_SECOND
		derived.append("build_time")
	else:
		missing.append("build_time")

	# ---- stats（读不到就 null；stats.armor 全仓库无此概念）----
	var stats: Dictionary = {
		"hp": null, "armor": null, "speed": null,
		"sight": null, "range": null, "damage": null, "attack_interval": null,
	}
	missing.append("stats.armor")
	var weapon_ids := _array_of(unit_type.get("weaponIds", null))
	var weapon: Dictionary = {}
	if not weapon_ids.is_empty():
		# C# BalanceConfigRuntime.cs:133-137 对多武器直接抛异常；本项目配置全是单武器。
		# 这里只取主武器，绝不把多件武器平均成一个假数字。
		weapon = lookups["weapons"].get(str(weapon_ids[0]), {})
	if unit_type.is_empty():
		for key in ["hp", "sight", "speed", "range", "damage", "attack_interval"]:
			missing.append("stats.%s" % key)
	else:
		_read_stat(unit_type, "maxHp", "hp", stats, available, missing)
		_read_stat(unit_type, "sightRangeMeters", "sight", stats, available, missing)
		var movement = unit_type.get("movement", null)
		if movement is Dictionary:
			_read_stat(movement, "speedMetersPerSecond", "speed", stats, available, missing)
		else:
			# 建筑没有 movement trait → 真的没有速度，不是缺数据。
			missing.append("stats.speed")
		_read_stat(weapon, "rangeMeters", "range", stats, available, missing)
		_read_stat(weapon, "baseDamage", "damage", stats, available, missing)
		var cooldown = weapon.get("cooldownMilliseconds", null)
		if cooldown is int or cooldown is float:
			stats["attack_interval"] = float(cooldown) / 1000.0
			available.append("stats.attack_interval")
		else:
			missing.append("stats.attack_interval")

	# ---- role / counters（推导，规则见文件头第 5 条）----
	# weapon 为空时要区分两种"没有武器"：配置里查不到这个单位（缺数据） vs
	# 配置明确声明 weaponIds=[]（真的无武装）。只有后者才算推导成功。
	var unarmed_declared := not unit_type.is_empty() and weapon_ids.is_empty()
	var role = null
	if not unit_type.is_empty():
		role = _derive_role(unit_type, weapon, unarmed_declared)
	if role == null:
		missing.append("role")
	else:
		derived.append("role")

	var counters = null
	if not unit_type.is_empty():
		counters = PackedStringArray()
		for domain in _array_of(weapon.get("targetDomains", null)):
			counters.append(str(domain))
		derived.append("counters")
	else:
		missing.append("counters")

	# ---- icon（真实文件存在才算 available）----
	var icon_key := str(tab_item.get("icon", ""))
	var icon = _resolve_icon(icon_key)
	if icon == null:
		missing.append("icon")
	else:
		available.append("icon")

	# ---- production_source（producer 来自 TABS + balance，工人绑定来自 UI 行为）----
	var producer_ids := PackedStringArray()
	for producer_id in _array_of(definition.get("allowedProducerUnitTypeIds", null)):
		producer_ids.append(str(producer_id))
	var producer_caption: String
	var producer_scene: String
	if place:
		producer_caption = "工人"
		producer_scene = ""
	else:
		# 完全复刻 Ra3Sidebar.gd:462-465：item 自带的 producer 优先于页签默认值。
		producer_caption = str(
			tab_item.get("producer_caption", lookups["tab_producer_caption"])
		)
		producer_scene = str(tab_item.get("producer", lookups["tab_producer_scene"]))
	available.append("production_source")

	var footprint = null
	if definition.has("footprintRadiusMeters"):
		footprint = definition.get("footprintRadiusMeters")

	var production_source := {
		"mode": "place" if place else "produce",
		# 配置里的真实门槛：必须拥有这些生产建筑（productions[].allowedProducerUnitTypeIds）。
		# place 模式下该字段为空——结构物没有生产建筑门槛。
		"producer_unit_type_ids": producer_ids,
		# 结构物的施工者是工人：这是从 UI 行为推出的绑定（Ra3Sidebar.gd:708-744
		# _begin_structure_placement → _select_builder_if_needed 只认 Worker），
		# 配置里没有这个字段，所以单独放，不混进上面那个真实字段。
		"builder_unit_type_ids": PackedStringArray(["worker"]) if place else PackedStringArray(),
		"producer_caption": producer_caption,
		"producer_scene_path": producer_scene,
		"product_scene_path": scene_path,
		"blueprint_scene_path": str(lookups["id_to_blueprint"].get(unit_id, "")),
		"environment_id": str(definition.get("environmentId", "")),
		"footprint_radius_m": footprint,
	}

	# 以下六个概念在项目里**不存在**：值一律 null，并在 missing_fields 登记。
	# description / energy_cost / tech_level / unlock_condition / max_count / adjutant_tags。
	for absent_key in [
		"description", "energy_cost", "tech_level", "unlock_condition", "max_count", "adjutant_tags",
	]:
		missing.append(str(absent_key))

	return {
		"unit_id": unit_id,
		"display_name": display_name,
		"category": category_id,
		"description": null,
		"icon": icon,
		"cost": cost,
		"energy_cost": null,
		"build_time": build_time,
		"tech_level": null,
		"unlock_condition": null,
		"max_count": null,
		"stats": stats,
		"role": role,
		"counters": counters,
		"production_source": production_source,
		"adjutant_tags": null,
		# 诚实桶。
		"available_fields": PackedStringArray(available),
		"derived_fields": PackedStringArray(derived),
		"missing_fields": PackedStringArray(missing),
		# 透明补充（非契约字段，仅供 UI 调试与图标兜底）：
		# TABS 里声明的图标 key 与场景路径，即使图标文件缺失也不会丢信息。
		"icon_key": icon_key,
		"scene_path": scene_path,
	}


# ------------------------------------------------------------------ 推导与工具

## 角色定位：唯一真实的结构性信号是 trait 块（producer / gatherer / constructor）
## 与主武器 targetDomains，故按固定优先级机械映射；无任何信号 → null（不猜）。
static func _derive_role(unit_type: Dictionary, weapon: Dictionary, unarmed_declared: bool) -> Variant:
	if unit_type.get("producer", null) is Dictionary:
		return "production_structure"
	if unit_type.get("gatherer", null) is Dictionary:
		return "gatherer"
	if unit_type.get("constructor", null) is Dictionary:
		return "builder"
	var domains := _array_of(weapon.get("targetDomains", null))
	if domains.size() > 1:
		return "multi_domain"
	if domains.size() == 1:
		var domain := str(domains[0])
		if domain == "air":
			return "anti_air"
		if domain == "terrain":
			return "anti_ground"
		return null
	# 无武器：只有"配置明确声明无武器"且该单位会动，才算可推导的无武装单位。
	if unarmed_declared and unit_type.get("movement", null) is Dictionary:
		return "unarmed_mobile"
	return null


## 把一个数值字段从 source 搬进 stats；拿到真实数字才算 available，否则 null + missing。
## 注意：available/missing 是 Array[String]（引用类型），可以被本函数就地追加——
## PackedStringArray 是值类型，传进来改不会回传，所以内部统一用 Array[String] 累积。
static func _read_stat(
	source: Dictionary, source_key: String, stat_key: String,
	stats: Dictionary, available: Array[String], missing: Array[String]
) -> void:
	var raw = source.get(source_key, null)
	if raw is int or raw is float:
		stats[stat_key] = float(raw)
		available.append("stats.%s" % stat_key)
	else:
		missing.append("stats.%s" % stat_key)


static func _legacy_costs(raw) -> Dictionary:
	# 与 C# BalanceConfigRuntime.cs:286-299 ToLegacyCosts 同形状：缺省键恒为 0。
	var out: Dictionary = {"resource_a": 0, "resource_b": 0}
	for amount in _array_of(raw):
		if not (amount is Dictionary):
			continue
		var key := "resource_a" if str((amount as Dictionary).get("kind", "")) == "A" else "resource_b"
		out[key] = int(out[key]) + int((amount as Dictionary).get("amount", 0))
	return out


static func _resolve_icon(icon_key: String) -> Variant:
	if icon_key.is_empty():
		return null
	var ra3_path := "%s/%s.png" % [ICON_DIR_RA3, icon_key]
	if ResourceLoader.exists(ra3_path):
		return ra3_path
	var ui_path := "%s/%s.png" % [ICON_DIR_UI, _pascal_case(icon_key)]
	if ResourceLoader.exists(ui_path):
		return ui_path
	return null


static func _pascal_case(value: String) -> String:
	var out := ""
	for part in value.split("_", false):
		var piece := str(part)
		if piece.is_empty():
			continue
		out += piece.substr(0, 1).to_upper() + piece.substr(1)
	return out


static func _fallback_id(scene_path: String) -> String:
	var file_name := scene_path.get_file().get_basename()
	if file_name.is_empty():
		return scene_path
	return file_name.to_snake_case()


static func _index_by_id(rows: Array) -> Dictionary:
	var out: Dictionary = {}
	for row in rows:
		if not (row is Dictionary):
			continue
		var key := str((row as Dictionary).get("id", ""))
		if not key.is_empty():
			out[key] = row
	return out


static func _array_of(value) -> Array:
	if value is Array:
		return value
	return []


static func _is_valid_node(value) -> bool:
	if value == null:
		return false
	if not is_instance_valid(value):
		return false
	return value is Node


## 第三参用无类型 Array：调用处传的是数组字面量，用 Array[String] 会触发
## "Cannot convert argument from Array to Array[String]" 的运行期类型错误。
static func _state_result(state: String, reason: String, actions: Array) -> Dictionary:
	if not STATES.has(state):
		# 契约内的状态才允许外传（防止笔误把 UI 变成未知状态）。
		push_warning("[ProductionCatalog] 非法状态 %s，降级为 ready。" % state)
		state = "ready"
	return {
		"state": state,
		"reason": reason,
		"available_actions": PackedStringArray(actions),
	}


# ------------------------------------------------------------------ state_of 辅助

## 该条目是否真的在当前队列里。同时容忍两种队列元素形态：
##   · Dictionary：{product_type_id | unit_id | scene_path}（如 C# ProductionObservation）
##   · ProductionQueueElement：有 unit_prototype / item_id（source/match/units/traits/ProductionQueue.gd:8-24）
static func _queue_contains(row: Dictionary, queue_items) -> bool:
	if not (queue_items is Array):
		return false
	var wanted_id := str(row["unit_id"])
	var source: Dictionary = row["production_source"]
	var wanted_scene := str(source.get("product_scene_path", ""))
	for queue_item in queue_items:
		if queue_item is Dictionary:
			var candidate: Dictionary = queue_item
			var candidate_id := str(candidate.get("product_type_id", candidate.get("unit_id", "")))
			if not wanted_id.is_empty() and candidate_id == wanted_id:
				return true
			var candidate_scene := str(candidate.get("scene_path", ""))
			if not wanted_scene.is_empty() and candidate_scene == wanted_scene:
				return true
			continue
		if not _is_valid_node(queue_item):
			continue
		if not wanted_scene.is_empty():
			if _prototype_scene_path(queue_item.get("unit_prototype")) == wanted_scene:
				return true
	return false


static func _prototype_scene_path(prototype) -> String:
	if prototype is PackedScene:
		return (prototype as PackedScene).resource_path
	if prototype is String:
		return prototype
	return ""


## 当前队列长度；拿不到时返回 -1（表示"未知"，不做判定）。
static func _live_queue_size(producer) -> int:
	if not _is_valid_node(producer):
		return -1
	if not ("production_queue" in producer):
		return -1
	var queue = producer.get("production_queue")
	if queue == null or not is_instance_valid(queue):
		return -1
	if not queue.has_method("size"):
		return -1
	return int(queue.size())


## 队列上限：调用方显式给了就优先用它，否则查配置里生产建筑的 producer.queueLimit。
## 供 UI 查询某条目的队列上限（默认 5）。
##
## 为什么要有这个公开入口：队列上限的真值在 `config/balance/demo.balance.v1.json` 的
## `unitTypes[].producer.queueLimit`，而 UI 组件需要它来显示「已用/上限」并判 `queue_full`。
## 没有这个入口时各 UI 组件只好各自再读一遍那份 JSON（实测已发生一次重复实现）。
static func queue_limit_for(item_id: String, producer = null, context: Dictionary = {}) -> int:
	_ensure_built()
	var row := entry(item_id)
	if row.is_empty():
		# 条目查不到时给默认上限，**不能返回 0** —— 那会让 UI 谎报"队列已满"。
		return 5
	return _queue_limit_for(row, producer, context)


static func _queue_limit_for(row: Dictionary, producer, context: Dictionary) -> int:
	var raw_override = context.get("queue_limit", null)
	if raw_override is int or raw_override is float:
		return int(raw_override)

	var limits: Dictionary = _cache.get("queue_limits", {})
	var unit_type_id := ""
	if _is_valid_node(producer) and "unit_type_id" in producer:
		unit_type_id = str(producer.get("unit_type_id"))
	if unit_type_id.is_empty():
		var source: Dictionary = row["production_source"]
		var candidates = source.get("producer_unit_type_ids", null)
		if not (candidates is PackedStringArray) or (candidates as PackedStringArray).is_empty():
			candidates = source.get("builder_unit_type_ids", null)
		if candidates is PackedStringArray and not (candidates as PackedStringArray).is_empty():
			unit_type_id = (candidates as PackedStringArray)[0]
	if limits.has(unit_type_id):
		return int(limits[unit_type_id])
	return QUEUE_LIMIT_DEFAULT


## 生产建筑受损提示；无 hp/hp_max 数据时返回空串（不猜）。
static func _damage_note(producer) -> String:
	if not _is_valid_node(producer):
		return ""
	if not ("hp" in producer) or not ("hp_max" in producer):
		return ""
	var current = producer.get("hp")
	var maximum = producer.get("hp_max")
	if not (current is int or current is float) or not (maximum is int or maximum is float):
		return ""
	var hp_value := float(current)
	var hp_max_value := float(maximum)
	if hp_max_value <= 0.0 or hp_value >= hp_max_value:
		return ""
	return "生产建筑受损：%.0f/%.0f" % [hp_value, hp_max_value]


# ------------------------------------------------------------------ hermes_advice 辅助

static func _advice_row(advice, source: String) -> Dictionary:
	if advice is Dictionary:
		var row: Dictionary = advice
		var title := str(row.get("type", row.get("title", "")))
		if title.is_empty():
			return {}
		return {
			"kind": str(row.get("kind", "adjutant")),
			"title": title,
			"reason": str(row.get("reason", "")),
			# source 必须由调用方按**真实来源**传入：早期版本这里写死 "live"，
			# 导致缓存快照来的建议也被标成实时，属于撒谎式标注，已修正。
			"source": source,
		}
	if advice is String and not (advice as String).is_empty():
		return {"kind": "advice", "title": advice, "reason": "", "source": source}
	return {}


## 把"这条建议是从什么算出来的"讲清楚——只用画像里真实存在的字段拼装。
static func _advice_basis(used: Dictionary, model_version, source: String) -> String:
	var parts: Array[String] = []
	if used.is_empty():
		parts.append("无画像快照（GrowthStore 未就绪或尚未生成）")
	else:
		var sample_count = used.get("sample_count", null)
		if sample_count is int or sample_count is float:
			parts.append("基于 %d 场对局档案" % int(sample_count))
		var report_list := _array_of(used.get("source_reports", null))
		if not report_list.is_empty():
			var names := PackedStringArray()
			for report in report_list:
				names.append(str(report))
			parts.append("档案 %s" % ", ".join(names))
		var dimensions = used.get("dimensions", null)
		if dimensions is Dictionary:
			parts.append("画像维度 %s" % JSON.stringify(dimensions))
		if model_version is String:
			parts.append("模型 %s" % str(model_version))
		parts.append("来源 MatchReportAdapter 生成的本地基线画像快照（非 LLM 实时推理）")
	if source == "live":
		# 实时建议由调用方提供，而 generated_at / model_version 仍取自画像快照——
		# 两者不同源，必须显式说明，别让 UI 以为元数据也是实时推理产出的。
		parts.append(
			"建议列表由调用方实时提供（source=live）；generated_at / model_version 元数据仍取自画像快照，两者不同源"
		)
	else:
		parts.append("建议来源标记 source=%s" % source)
	return "；".join(PackedStringArray(parts))


static func _growth_store():
	var loop := Engine.get_main_loop()
	var tree := loop as SceneTree
	if tree == null:
		return null
	var root: Window = tree.root
	if root == null:
		return null
	return root.get_node_or_null("GrowthStore")


# ------------------------------------------------------------------ 配置读取

static func _load_json(path: String) -> Dictionary:
	if path.is_empty() or not FileAccess.file_exists(path):
		return {}
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {}
	var text := file.get_as_text()
	file.close()
	var parsed = JSON.parse_string(text)
	if parsed is Dictionary:
		return parsed
	return {}


## 允许 --balance-config= / --assets-manifest= 覆盖，
## 与 C# BalanceConfigRuntime.cs:306-319 ApplyCommandLineOverrides 行为一致
## （副官 E2E 用独立配置启动时，本适配层必须跟着走同一份数据）。
static func _balance_config_path() -> String:
	var override := _cmdline_override("--balance-config=")
	return override if not override.is_empty() else BALANCE_CONFIG_DEFAULT


static func _asset_manifest_path() -> String:
	var override := _cmdline_override("--assets-manifest=")
	return override if not override.is_empty() else ASSET_MANIFEST_DEFAULT


static func _cmdline_override(prefix: String) -> String:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with(prefix):
			return argument.substr(prefix.length())
	return ""


## UI 侧权威清单：运行期从 Ra3Sidebar.gd 读常量 TABS（只读，不复制）。
static func _sidebar_tabs() -> Array:
	var script: GDScript = load(SIDEBAR_SCRIPT_PATH) as GDScript
	if script == null:
		return []
	var constants: Dictionary = script.get_script_constant_map()
	var tabs = constants.get("TABS", null)
	if not (tabs is Array):
		return []
	return tabs
