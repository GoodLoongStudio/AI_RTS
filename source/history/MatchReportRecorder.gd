class_name MatchReportRecorder
extends Node

## 从**真实对局事件**累积出一份 MatchReport。
##
## 用法（对局侧）：
##     var recorder := MatchReportRecorder.new()
##     add_child(recorder)
##     recorder.begin({"map": {...}, "mode": "custom", "difficulty": "normal",
##                     "adjutant": {"type": "前线指挥官"}, "player_id": ...})
##     ...
##     recorder.finish("victory")          # 或 "defeat" / "aborted"
##
## 三条纪律：
## 1. **只记录，不推断**。信号里拿不到的数值一律留 null；本节点绝不"估算"伤害或资源，
##    缺失由 `MatchReportSchema.completeness()` 如实汇总。
## 2. **绝不改玩法**。所有回调只做本地计数，不调用任何影响对局的 API；
##    出错也不会向对局抛异常（GDScript 无异常传播，回调里仅做字段累加）。
## 3. **扩展点显式**。玩法系统拿到权威数字后，用 `contribute(section, path, value)`
##    推进来即可，不需要改本文件。

## 对一个局的绝对上限，避免长时间挂机把数组撑爆（超出则停止采样）。
const MAX_SAMPLES := 600
const MIN_DURATION_SECONDS := 10.0

## 由信号能记全的字段 + 由 contribute() 补充的字段共同组成最终报告。
var active := false
var context: Dictionary = {}
var started_at_ms := 0
var elapsed_seconds := 0.0
var ended_at := ""
var outcome := "unknown"
var end_reason := ""

var produced_by_type: Dictionary = {}
var lost_by_type: Dictionary = {}
var produced_total := 0
var buildings_built := 0
var buildings_by_type: Dictionary = {}
var resource_samples: Array = []
var resource_drought_events := 0
var timeline: Array = []
var damage_dealt := 0.0
var damage_taken := 0.0
var kills := 0
var contributions: Dictionary = {}

var _sample_accumulator := 0.0
var _connected := false


func _ready() -> void:
	set_process(false)


## 开始记录。`ctx` 支持 map/mode/difficulty/adjutant/player_id/match_id/demo_seed。
func begin(ctx: Dictionary = {}) -> void:
	context = ctx.duplicate(true)
	started_at_ms = Time.get_ticks_msec()
	active = true
	elapsed_seconds = 0.0
	set_process(true)
	_connect_signals()
	_add_event("match_start", "游戏开始", "记录器已挂载", "", false)


func _process(delta: float) -> void:
	if not active:
		return
	elapsed_seconds = float(Time.get_ticks_msec() - started_at_ms) / 1000.0
	_sample_accumulator += delta
	# 1Hz 采样资源库存，足以画出曲线，又不会给对局添负担。
	if _sample_accumulator >= 1.0:
		_sample_accumulator = 0.0
		_sample_resources()


## 结束记录并生成报告。`result` ∈ {victory, defeat, aborted, unknown}。
func finish(result: String, reason: String = "") -> Dictionary:
	if not active:
		return {}
	active = false
	set_process(false)
	outcome = result
	end_reason = reason
	ended_at = Time.get_datetime_string_from_system()
	var report := build_report()
	# 由 store 负责去重与落盘；recorder 自身不直接写文件，便于测试替换实现。
	var store := get_node_or_null("/root/MatchReportStore")
	if store != null and store.has_method("upsert"):
		store.upsert(report)
	return report


## 玩法系统补充权威数字。两个参数都是点号路径，会拼接后写入嵌套结构，例如
## `contribute("combat.damage", "dealt", 8420.0)` → `combat.damage.dealt = 8420.0`。
func contribute(section: String, path: String, value: Variant) -> void:
	if section.is_empty() or path.is_empty():
		return
	var segments := ("%s.%s" % [section, path]).split(".")
	var cursor: Dictionary = contributions
	for index in range(segments.size() - 1):
		var key := segments[index]
		if not cursor.get(key, null) is Dictionary:
			cursor[key] = {}
		cursor = cursor[key]
	cursor[segments[segments.size() - 1]] = value


## 生成报告（不落盘）。缺的字段一律 null，由 schema 记入 missing。
func build_report() -> Dictionary:
	var duration := maxf(elapsed_seconds, 0.0)
	var map_ctx: Dictionary = context.get("map", {}) if context.get("map", {}) is Dictionary else {}
	var unit_rows: Array = []
	for unit_id in produced_by_type:
		unit_rows.append({
			"id": str(unit_id),
			"label": str(unit_id),
			"produced": int(produced_by_type[unit_id]),
			"lost": int(lost_by_type.get(unit_id, 0)),
		})
	var building_rows: Array = []
	for building_id in buildings_by_type:
		building_rows.append({
			"id": str(building_id),
			"label": str(building_id),
			"count": int(buildings_by_type[building_id]),
		})
	var series: Array = []
	for sample in resource_samples:
		series.append({
			"t": (sample as Dictionary).get("t", null),
			"stock": (sample as Dictionary).get("stock", null),
			"gathered_cum": null,
			"spent_cum": null,
			"gather_rate": null,
			"spend_rate": null,
			"event": "",
		})
	var report := {
		"schema_version": MatchReportSchema.SCHEMA_VERSION,
		"report_id": _make_report_id(),
		"player_id": str(context.get("player_id", "local_player_demo")),
		"created_at": ended_at,
		"match_id": str(context.get("match_id", "")),
		"match_version": "0.1",
		"demo": context.get("demo_seed", null) != null,
		"demo_seed": context.get("demo_seed", null),
		"map": {
			"name": str(map_ctx.get("name", "")),
			"path": str(map_ctx.get("path", "")),
			"seed": map_ctx.get("seed", null),
			"size": map_ctx.get("size", null),
			"players": map_ctx.get("players", null),
		},
		"mode": str(context.get("mode", "unknown")),
		"difficulty": str(context.get("difficulty", "unknown")),
		"duration_seconds": duration,
		"outcome": outcome,
		"victory_condition": str(context.get("victory_condition", "")),
		"defeat_reason": end_reason if outcome in ["defeat", "aborted"] else "",
		"commander": str(context.get("player_id", "local_player_demo")),
		"adjutant": context.get("adjutant", {"type": null, "level": null}),
		"growth_before": context.get("growth_before", {}),
		"growth_after": context.get("growth_after", {}),
		"growth_spent_this_match": context.get("growth_spent_this_match", null),
		"overview": {
			"units_produced": produced_total,
			"structures_built": buildings_built,
			"units_lost": _sum_values(lost_by_type),
			# 击杀没有可订阅的信号：没有外部 contribute 时它是"未测量"而不是 0。
			"enemies_killed": kills if kills > 0 else null,
			"damage_dealt": damage_dealt if damage_dealt > 0.0 else null,
			"damage_taken": damage_taken if damage_taken > 0.0 else null,
			"total_gathered": context.get("total_gathered", null),
			"total_spent": context.get("total_spent", null),
			"final_resources": context.get("final_resources", null),
			"key_events": _key_events(),
		},
		"economy": {
			"series": series,
			"structure": {
				"drought_windows": _drought_windows(),
			},
		},
		"production": {"units": unit_rows},
		"construction": {"total_built": buildings_built, "buildings": building_rows},
		"combat": {
			"damage": {
				"dealt": damage_dealt if damage_dealt > 0.0 else null,
				"taken": damage_taken if damage_taken > 0.0 else null,
			},
			"units": unit_rows.duplicate(true),
		},
		"timeline": timeline.duplicate(true),
		"hermes_analysis": {"status": "none"},
	}
	# 把 contribute() 推来的权威字段合并进去（覆盖 recorder 自己数出来的粗值）。
	for section in contributions:
		if not report.has(section):
			report[section] = {}
		report[section] = _deep_merge(report[section], contributions[section])
	# 总览与分区必须是**同一个数字**（schema.validate 会交叉校验）。
	# 分区里已有权威值时，总览直接引用它，而不是另算一遍。
	var combat_section = report.get("combat", {})
	var damage_section = combat_section.get("damage", {}) if combat_section is Dictionary else {}
	if damage_section is Dictionary:
		for pair in [["damage_dealt", "dealt"], ["damage_taken", "taken"]]:
			var overview_key := str(pair[0])
			var damage_key := str(pair[1])
			if report["overview"].get(overview_key, null) == null \
					and (damage_section as Dictionary).get(damage_key, null) != null:
				report["overview"][overview_key] = (damage_section as Dictionary)[damage_key]
	if outcome == "aborted":
		report = MatchReportSchema.aborted_report(report,
			end_reason if not end_reason.is_empty() else "对局未正常结束")
	var normalized: Dictionary = MatchReportSchema.normalize(report)["report"]
	normalized["performance_score"] = MatchReportScoring.evaluate(normalized)
	normalized["overview"]["score"] = normalized["performance_score"]["total"]
	normalized["source"] = {
		"generated_by": "MatchReportRecorder.gd",
		"generated_at": ended_at,
		"game_version": "0.1",
	}
	return MatchReportSchema.normalize(normalized)["report"]


# ---------------- 信号接线 ----------------

func _connect_signals() -> void:
	if _connected:
		return
	var signals := get_node_or_null("/root/MatchSignals")
	if signals == null:
		return
	_connected = true
	_connect(signals, "unit_production_finished", _on_unit_production_finished)
	_connect(signals, "unit_construction_finished", _on_unit_construction_finished)
	_connect(signals, "unit_died", _on_unit_died)
	_connect(signals, "not_enough_resources_for_production", _on_not_enough_resources)
	_connect(signals, "not_enough_resources_for_construction", _on_not_enough_resources)


func _connect(source: Node, signal_name: String, target: Callable) -> void:
	if source.has_signal(signal_name) and not source.is_connected(signal_name, target):
		source.connect(signal_name, target)


func _on_unit_production_finished(unit, _producer) -> void:
	produced_total += 1
	var key := _unit_key(unit)
	produced_by_type[key] = int(produced_by_type.get(key, 0)) + 1
	if produced_total == 1:
		_add_event("first_unit_produced", "第一个单位下线", key, key, false)


func _on_unit_construction_finished(unit) -> void:
	buildings_built += 1
	var key := _unit_key(unit)
	buildings_by_type[key] = int(buildings_by_type.get(key, 0)) + 1
	if buildings_built == 1:
		_add_event("first_structure_built", "首个建筑建成", key, key, false)


func _on_unit_died(unit) -> void:
	var key := _unit_key(unit)
	lost_by_type[key] = int(lost_by_type.get(key, 0)) + 1
	if _sum_values(lost_by_type) == 1:
		_add_event("first_contact", "首次损失单位", key, key, false)


func _on_not_enough_resources(_player) -> void:
	resource_drought_events += 1


func _sample_resources() -> void:
	if resource_samples.size() >= MAX_SAMPLES:
		return
	var player := _local_player()
	if player == null:
		return
	# 用 Object.get() 而不是 `"resource_a" in player`：前者对不存在的属性返回 null，
	# 后者在不同 Godot 版本上对 Object 的语义并不一致。
	var a = player.get("resource_a")
	if a == null:
		return
	var stock := float(a)
	var b = player.get("resource_b")
	if b != null:
		stock += float(b)
	resource_samples.append({"t": int(elapsed_seconds), "stock": stock})


func _local_player() -> Node:
	var match_root := get_parent()
	if match_root == null:
		return null
	var players := match_root.get_node_or_null("Players")
	if players == null:
		return null
	for child in players.get_children():
		if child.get("is_local_player") == true:
			return child
		if str(child.name).to_lower().contains("human"):
			return child
	return null


func _unit_key(unit) -> String:
	if unit == null:
		return "unknown"
	var prototype = unit.get("unit_prototype")
	if prototype != null:
		var path := str(prototype.get("resource_path"))
		if not path.is_empty():
			return path.get_file().get_basename()
	var scene_path := str(unit.get("scene_file_path"))
	if not scene_path.is_empty():
		return scene_path.get_file().get_basename()
	return str(unit.name)


func _add_event(type_key: String, title: String, detail: String, subject: String,
		hermes_tagged: bool) -> void:
	timeline.append({
		"t": int(elapsed_seconds),
		"type": type_key,
		"title": title,
		"detail": detail,
		"subject": subject,
		"resources_delta": null,
		"combat_impact": null,
		"hermes_tagged": hermes_tagged,
	})


func _key_events() -> Array:
	var out: Array = []
	for event in timeline:
		out.append({
			"t": (event as Dictionary).get("t", null),
			"title": str((event as Dictionary).get("title", "")),
			"detail": str((event as Dictionary).get("detail", "")),
		})
	return out


func _drought_windows() -> Array:
	if resource_drought_events <= 0:
		return []
	# 记录器只知道"发生了多少次资源不足"，不知道确切时间窗 —— 不编造窗口，
	# 只把次数如实写进一条零长度窗口并把 cause 说明清楚。
	return [{
		"start_s": int(elapsed_seconds),
		"end_s": int(elapsed_seconds),
		"cause": "采集中断共 %d 次（记录器只有计数，精确窗口待玩法侧提供）" % resource_drought_events,
	}]


func _make_report_id() -> String:
	var stamp := Time.get_datetime_string_from_system().replace("-", "").replace(":", "").replace("T", "").replace(" ", "")
	var match_id := str(context.get("match_id", ""))
	if not match_id.is_empty():
		return "MR-%s-%s" % [stamp, match_id]
	return "MR-%s" % stamp


static func _sum_values(source: Dictionary) -> int:
	var total := 0
	for key in source:
		total += int(source[key])
	return total


static func _deep_merge(base: Variant, overlay: Variant) -> Variant:
	if not (base is Dictionary) or not (overlay is Dictionary):
		return overlay if overlay != null else base
	var out: Dictionary = (base as Dictionary).duplicate(true)
	for key in (overlay as Dictionary):
		var value = (overlay as Dictionary)[key]
		if out.has(key) and out[key] is Dictionary and value is Dictionary:
			out[key] = _deep_merge(out[key], value)
		else:
			out[key] = value
	return out
