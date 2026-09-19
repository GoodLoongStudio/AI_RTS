extends Node

## 电脑玩家对局观测工具（S4 验收用）。2026-09-19 由 tmp_ai_observe.gd 固化而来。
##
## 用途：headless 起一局"人对电脑玩家"，按固定间隔**只读**采样 AI 的己方实体构成，
## 输出可直接喂给文档/报告的逐拍记录。不注入命令、不干预对局、不读视野外信息
## （全部通过 AI 自己的标准查询会话 GetOwnForces）。
##
## 用法：
##   godot --headless --path <AI_RTS> res://tools/rule_ai_match_observe.tscn \
##     -- --difficulty=easy --seconds=120
## 参数：
##   --difficulty=easy|normal|hard   覆盖 AI 难度（默认不改，即场景自带值）
##   --seconds=120                   观测时长（默认 120）
##   --interval=10                   采样间隔（默认 10）
##
## 输出行格式（前缀 [OBS]）：时间 / 模拟时间 / 战斗单位数 / 离主基地最远距离 /
## 完工·在建建筑 / 队列长度 / 每个编组的 state 与 size/capacity。

const MatchScene = preload("res://tests/manual/TestPlayerVsAI.tscn")
const FIELD_POSITION := 1 << 0
const FIELD_TYPE := 1 << 1
const FIELD_CONSTRUCTION := 1 << 4
const FIELD_PRODUCTION := 1 << 5
const BELLIGERENT_TYPES := ["tank", "helicopter", "soldier", "rocketeer", "heavy_tank"]

var _match = null
var _ai = null
var _seconds := 120.0
var _interval := 10.0


func _ready():
	var arguments := OS.get_cmdline_user_args()
	var difficulty_override := ""
	for argument in arguments:
		if argument.begins_with("--difficulty="):
			difficulty_override = argument.substr("--difficulty=".length()).to_lower()
		elif argument.begins_with("--seconds="):
			_seconds = maxf(10.0, float(argument.substr("--seconds=".length())))
		elif argument.begins_with("--interval="):
			_interval = maxf(1.0, float(argument.substr("--interval=".length())))

	_match = MatchScene.instantiate()
	if not difficulty_override.is_empty():
		var ai_node = _match.get_node_or_null("Players/SimpleClairvoyantAI")
		if ai_node != null:
			match difficulty_override:
				"easy":
					ai_node.difficulty = 0
				"normal":
					ai_node.difficulty = 1
				"hard":
					ai_node.difficulty = 2
	add_child(_match)

	var waited := 0.0
	while waited < 40.0:
		_ai = _match.get_node_or_null("Players/SimpleClairvoyantAI")
		if _ai != null and _ai.get("_world_query_runtime") != null:
			break
		await get_tree().create_timer(0.1).timeout
		waited += 0.1
	if _ai == null or _ai.get("_world_query_runtime") == null:
		print("[OBS] FAIL AI 未在 40s 内就绪")
		get_tree().quit(1)
		return

	print("[OBS] difficulty=%s attack_delay=%s re_dispatch=%s seconds=%s" % [
		str(_ai.get("difficulty")), str(_ai.get("attack_wave_delay_s")),
		str(_ai.get("re_dispatch_interval_s")), str(_seconds)
	])
	var elapsed := 0.0
	while elapsed < _seconds:
		await get_tree().create_timer(_interval).timeout
		elapsed += _interval
		_report(elapsed)
	print("[OBS] 观测结束")
	get_tree().quit(0)


func _report(elapsed: float) -> void:
	var runtime = _ai.get("_world_query_runtime")
	var session_id: String = _ai.get("_query_session_id")
	var result: Dictionary = runtime.GetOwnForces(
		session_id,
		FIELD_POSITION | FIELD_TYPE | FIELD_CONSTRUCTION | FIELD_PRODUCTION
	)
	if result.get("status", "") != "Accepted":
		print("[OBS] t=%5.0fs 查询被拒: %s" % [elapsed, str(result.get("error", "?"))])
		return
	var counts := {}
	var completed := 0
	var under_construction := 0
	var queued := 0
	var belligerents := 0
	var base_position := Vector3.INF
	for entity in result.get("entities", []):
		var type_id: String = entity.get("type_id", "?")
		counts[type_id] = counts.get(type_id, 0) + 1
		if BELLIGERENT_TYPES.has(type_id):
			belligerents += 1
		if type_id == "command_center" and base_position == Vector3.INF:
			base_position = entity.get("position", Vector3.INF)
		var construction = entity.get("construction", null)
		if construction != null:
			if construction.get("state", "") == "Completed":
				completed += 1
			elif construction.get("state", "") == "UnderConstruction":
				under_construction += 1
		var production = entity.get("production", null)
		if production != null:
			queued += production.get("items", []).size()
	var max_away := -1.0
	if base_position != Vector3.INF:
		for entity in result.get("entities", []):
			if not BELLIGERENT_TYPES.has(entity.get("type_id", "")):
				continue
			var position: Vector3 = entity.get("position", Vector3.INF)
			if position != Vector3.INF:
				max_away = maxf(max_away, position.distance_to(base_position))
	var group_text := ""
	var offense = _ai.get_node_or_null("OffenseController")
	if offense != null:
		var groups = offense.get("_battlegroups")
		if groups != null:
			for index in range(groups.size()):
				var group = groups[index]
				if group == null or not is_instance_valid(group):
					continue
				group_text += " [%d]%s %d/%d" % [
					index, str(group.get("_state")), int(group.call("size")),
					int(group.call("capacity"))
				]
	var sim_s := float(_ai.call("simulation_msec")) / 1000.0
	print("[OBS] t=%5.0fs sim=%6.1fs | 战斗=%d 离基地最远=%5.1fm 完工=%d 在建=%d 队列=%d | %s" % [
		elapsed, sim_s, belligerents, max_away, completed, under_construction, queued,
		str(counts)
	])
	print("[OBS]        编组:%s" % group_text)
