extends Node

## 副官双层改造第一阶段：战术快照与战略摘要冒烟测试（双玩家场景）。
## 需要以 -- --debugport <port> 启动使 DebugControlServer autoload 保持挂载；
## 测试直接调用其 op 方法（与 TCP 调用同一路径）。
## 验证：公共包头、视野公平（敌方只回 as_player 视野内数据）、失去视野冻结、
## 确认死亡独立事件、显式截断与续取、战略摘要地图边界与动态生产关系。

const MatchScene = preload("res://tests/manual/TestPlayerVsAI.tscn")

var _failures := 0
var _dbg: Node = null
var _match: Node = null


func _ready():
	print("[ADJ-OBS] test start")
	_dbg = get_node_or_null("/root/DebugControlServer")
	if _dbg == null:
		_fail(0, "DebugControlServer autoload 未挂载：请用 -- --debugport <port> 启动本测试")
		SmokeTestExit.request(get_tree(), 1)
		return
	_match = MatchScene.instantiate()
	print("[ADJ-OBS] match instantiated, adding")
	add_child(_match)
	print("[ADJ-OBS] match added, waiting")
	await get_tree().create_timer(0.7).timeout
	print("[ADJ-OBS] wait done")

	var human = _match.get_node("Players/Human")
	var ai = _match.get_node_or_null("Players/SimpleClairvoyantAI")
	print("[ADJ-OBS] players resolved human=%s ai=%s" % [str(human), str(ai)])
	_check(ai != null, "双玩家场景应包含 AI 玩家")
	print("[ADJ-OBS] calling _op_tactical")
	var header: Dictionary = _dbg._op_tactical(_match, {"as_player": "Human"})
	print("[ADJ-OBS] tactical returned, error=%s" % str(header.get("error", "")))
	if not _check(not header.has("error"), "战术快照不应报错"):
		return
	_verify_header(header, "Human")

	# 视野公平：把 Human Worker 传送到 AI 单位旁建立真实视野（_unit_scouted 实时计算）。
	var worker = _find_unit(human, "Worker")
	var ai_unit = _first_ai_unit(ai)
	_check(worker != null and ai_unit != null, "场景应有 Human Worker 与 AI 单位")
	ai_unit.global_position = worker.global_position + Vector3(3.0, 0.0, 0.0)
	var visible_view: Dictionary = _dbg._op_tactical(_match, {"as_player": "Human"})
	var live_enemy: Variant = _find_entity(visible_view, "unit_enemy", str(ai_unit.name))
	_check(live_enemy != null, "进入视野的敌方单位应以实时条目返回")
	if live_enemy != null:
		_check(
			int(live_enemy.get("last_seen_tick", -1)) == int(header["server_tick"])
			or int(live_enemy.get("last_seen_tick", -1)) > 0,
			"实时敌情应带 last_seen_tick"
		)
		_check(float(live_enemy.get("hp", 0.0)) > 0.0, "实时敌情应带当前血量")

	# 失去视野：Worker 拉远 → 冻结情报，不更新真实位置。
	ai_unit.global_position = worker.global_position + Vector3(80.0, 0.0, 0.0)
	var frozen_view: Dictionary = _dbg._op_tactical(_match, {"as_player": "Human"})
	var frozen_enemy: Variant = _find_entity(frozen_view, "unit_enemy_frozen", str(ai_unit.name))
	_check(frozen_enemy != null, "失去视野后应以冻结情报返回（不是消失也不是实时）")
	if frozen_enemy != null:
		_check(not bool(frozen_enemy.get("confirmed_dead", true)),
			"失去视野不等于死亡")
		_check(
			int(frozen_enemy.get("last_seen_tick", 0)) <= int(frozen_view["server_tick"]),
			"冻结情报应保留 last_seen_tick"
		)

	# 确认死亡：冻结目标从世界移除 → confirmed_dead 独立事件。
	var ai_unit_name := str(ai_unit.name)
	ai_unit.queue_free()
	await get_tree().process_frame
	await get_tree().process_frame
	var dead_view: Dictionary = _dbg._op_tactical(_match, {"as_player": "Human"})
	var dead_enemy: Variant = _find_entity(dead_view, "unit_enemy_dead", ai_unit_name)
	_check(dead_enemy != null, "世界移除后应报告确认死亡（独立于失去视野）")
	if dead_enemy != null:
		_check(bool(dead_enemy.get("confirmed_dead", false)), "死亡条目必须标记 confirmed_dead")

	# 截断与续取：limit=2 显式截断，续取合并后覆盖全量。
	var full_view: Dictionary = _dbg._op_tactical(_match, {"as_player": "Human", "limit": 10000})
	var total: int = (full_view.get("entities", []) as Array).size()
	_check(total > 0, "全量视图应至少包含我方单位")
	var paged: Array = []
	var offset := 0
	var guard := 0
	while offset >= 0 and guard < 200:
		guard += 1
		var page: Dictionary = _dbg._op_tactical(_match, {"as_player": "Human", "limit": 2, "offset": offset})
		paged.append_array(page.get("entities", []) as Array)
		offset = int(page.get("next_offset", -1))
		if offset < 0:
			_check(not bool(page.get("truncated", true)), "末页不应再报 truncated")
			break
		_check(bool(page.get("truncated", false)), "未到末页必须显式报告 truncated")
	_check(paged.size() == total,
		"分页续取合并后应覆盖全量实体（%d/%d），未返回不等于阵亡" % [paged.size(), total])

	# 战略摘要：地图边界 + 动态生产关系 + 敌情摘要。
	var strategic: Dictionary = _dbg._op_strategic(_match, {"as_player": "Human"})
	if not _check(not strategic.has("error"), "战略摘要不应报错"):
		return
	_verify_header(strategic, "Human")
	var map_bounds: Array = strategic.get("map_bounds", [])
	_check(map_bounds.size() == 2 and float(map_bounds[0]) > 0.0 and float(map_bounds[1]) > 0.0,
		"战略摘要应携带当前对局实际地图边界")
	var relations: Array = strategic.get("production_relations", [])
	var found_tank_relation := false
	for relation in relations:
		var entry := relation as Dictionary
		if str(entry.get("product_type_id", "")) == "tank":
			var producers: Array = entry.get("allowed_producer_type_ids", [])
			found_tank_relation = producers.size() == 1 and str(producers[0]) == "vehicle_factory"
	_check(found_tank_relation, "战略摘要应导出动态生产关系（tank←vehicle_factory）")
	var enemy_intel: Array = strategic.get("enemy_intel", [])
	_check(not enemy_intel.is_empty(), "战略摘要敌情应来自 last_seen 情报（含确认死亡）")

	# 未知玩家显式拒绝；AI 玩家视角观测允许（只读、按其视野过滤）。
	var bad_player: Dictionary = _dbg._op_tactical(_match, {"as_player": "Ghost"})
	_check(bad_player.has("error"), "不存在的 as_player 必须显式拒绝")
	var ai_view: Dictionary = _dbg._op_tactical(_match, {"as_player": str(ai.name)})
	_check(not ai_view.has("error"), "AI 玩家视角的只读观测允许存在（按其视野过滤）")

	print("Adjutant observation smoke test completed: %d failure(s)" % _failures)
	_match.queue_free()
	await get_tree().process_frame
	SmokeTestExit.request(get_tree(), 0 if _failures == 0 else 1)


func _verify_header(header: Dictionary, expected_player: String) -> bool:
	var ok := true
	ok = _check(int(header.get("schema_version", 0)) == 1, "包头 schema_version 应为 1") and ok
	ok = _check(not str(header.get("match_id", "")).is_empty(), "包头应携带稳定 match_id") and ok
	ok = _check(str(header.get("player_id", "")) == expected_player, "包头 player_id 应等于 as_player") and ok
	ok = _check(not str(header.get("rules_version", "")).is_empty(), "包头应携带规则版本指纹") and ok
	ok = _check(int(header.get("server_tick", -1)) >= 0, "包头应携带服务器 tick（权威逻辑时钟）") and ok
	ok = _check(int(header.get("snapshot_id", 0)) > 0, "包头应携带自增 snapshot_id") and ok
	return ok


func _find_unit(player, unit_name: String) -> Variant:
	for unit in get_tree().get_nodes_in_group("units"):
		if unit.get_parent() == player and str(unit.name) == unit_name:
			return unit
	return null


func _first_ai_unit(ai) -> Variant:
	for unit in get_tree().get_nodes_in_group("units"):
		if unit.get_parent() == ai:
			return unit
	return null


func _find_entity(view: Dictionary, kind: String, name: String) -> Variant:
	for entity in view.get("entities", []):
		var entry := entity as Dictionary
		if str(entry.get("kind", "")) == kind and str(entry.get("name", "")) == name:
			return entry
	return null


func _check(condition: bool, message: String) -> bool:
	if condition:
		return true
	_failures += 1
	push_error("Adjutant observation assertion failed: %s" % message)
	return false


func _fail(_code: int, message: String):
	push_error("Adjutant observation fatal: %s" % message)
	print("Adjutant observation smoke test aborted: %s" % message)
