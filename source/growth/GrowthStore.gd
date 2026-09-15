extends Node

const SAVE_PATH := "user://growth_state.json"
const PROFILE_PATH := "user://player_profile.json"
const REPORTS_PATH := "user://match_reports.json"
const MAX_GROWTH_PER_MATCH := 8
const LOCAL_PLAYER_ID := "local_player_demo"

var DEFINITIONS := {
	"combat": [
		{"id":"combat_power","name":"战术火力","description":"提升部队战斗效率。","max_level":5,"costs":[1,1,2,2,3],"prerequisite":""},
		{"id":"combat_guard","name":"战场韧性","description":"提高部队持续作战能力。","max_level":5,"costs":[1,2,2,3,3],"prerequisite":"combat_power"},
		{"id":"combat_skill","name":"技能专精","description":"强化主动技能与副官协同。","max_level":3,"costs":[2,3,4],"prerequisite":"combat_guard"}
	],
	"economy": [
		{"id":"economy_gather","name":"高效采集","description":"提升资源采集效率。","max_level":5,"costs":[1,1,2,2,3],"prerequisite":""},
		{"id":"economy_stock","name":"资源储备","description":"提高资源上限与周转空间。","max_level":5,"costs":[1,2,2,3,3],"prerequisite":"economy_gather"},
		{"id":"economy_production","name":"生产调度","description":"提升生产队列的运营效率。","max_level":3,"costs":[2,3,4],"prerequisite":"economy_stock"}
	],
	"construction": [
		{"id":"construction_speed","name":"快速施工","description":"缩短建筑施工时间。","max_level":5,"costs":[1,1,2,2,3],"prerequisite":""},
		{"id":"construction_armor","name":"坚固工事","description":"提高建筑耐久与防守价值。","max_level":5,"costs":[1,2,2,3,3],"prerequisite":"construction_speed"},
		{"id":"construction_network","name":"建设网络","description":"改善扩张与前线建设能力。","max_level":3,"costs":[2,3,4],"prerequisite":"construction_armor"}
	]
}

var state: Dictionary = {"available_points": 12, "levels": {}, "earned_total": 12, "spent_total": 0}
var profile: Dictionary = {}
var match_reports: Array = []

func _ready() -> void:
	_load_definitions()
	_load_json(SAVE_PATH, "state")
	_load_json(PROFILE_PATH, "profile")
	_load_json(REPORTS_PATH, "reports")
	if match_reports.is_empty() and profile.is_empty():
		_seed_demo_profile()

func _load_definitions() -> void:
	var file := FileAccess.open("res://config/growth_definitions.json", FileAccess.READ)
	if file == null:
		return
	var parsed = JSON.parse_string(file.get_as_text())
	if parsed is Dictionary and parsed.has("branches"):
		DEFINITIONS = parsed.branches

func _load_json(path: String, target: String) -> void:
	if not FileAccess.file_exists(path):
		return
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return
	var parsed = JSON.parse_string(file.get_as_text())
	if target == "reports":
		if parsed is Array: match_reports = parsed
		return
	if parsed is Dictionary:
		if target == "state": state = parsed
		else: profile = parsed

func _save_json(path: String, value: Variant) -> bool:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return false
	file.store_string(JSON.stringify(value, "  "))
	return true

func save_state() -> bool:
	return _save_json(SAVE_PATH, state)

func get_level(node_id: String, pending: Dictionary = {}) -> int:
	if pending.has(node_id):
		return int(pending[node_id])
	return int(state.get("levels", {}).get(node_id, 0))

func get_definition(node_id: String) -> Dictionary:
	for branch in DEFINITIONS.values():
		for definition in branch:
			if definition.get("id") == node_id:
				return definition
	return {}

func can_upgrade(node_id: String, pending: Dictionary = {}) -> Dictionary:
	var definition := get_definition(node_id)
	if definition.is_empty():
		return {"ok": false, "reason": "节点不存在"}
	var level := get_level(node_id, pending)
	if level >= int(definition.get("max_level", 0)):
		return {"ok": false, "reason": "已满级"}
	var prerequisite := str(definition.get("prerequisite", ""))
	if prerequisite != "" and get_level(prerequisite, pending) <= 0:
		return {"ok": false, "reason": "前置未满足"}
	var cost := int(definition.get("costs", [])[level])
	var committed := int(state.get("available_points", 0))
	for id in pending:
		var base := int(state.get("levels", {}).get(id, 0))
		var target := int(pending[id])
		if target > base:
			var def := get_definition(str(id))
			for i in range(base, target):
				committed -= int(def.get("costs", [])[i])
	return {"ok": committed >= cost, "reason": "成长点不足" if committed < cost else "", "cost": cost}

func confirm_pending(pending: Dictionary) -> Dictionary:
	var before := state.duplicate(true)
	for id in pending:
		var target := int(pending[id])
		var current := int(state.get("levels", {}).get(id, 0))
		if target < current:
			return {"ok": false, "reason": "不能降低已保存等级"}
		while current < target:
			var result := can_upgrade(id, {})
			if not bool(result.get("ok", false)):
				state = before
				return {"ok": false, "reason": result.get("reason", "无法升级")}
			state["available_points"] = int(state.get("available_points", 0)) - int(result.get("cost", 0))
			state["spent_total"] = int(state.get("spent_total", 0)) + int(result.get("cost", 0))
			current += 1
			state["levels"][id] = current
	if not save_state():
		state = before
		return {"ok": false, "reason": "无法保存成长状态"}
	return {"ok": true, "state": state.duplicate(true)}

func reset_pending() -> Dictionary:
	return state.duplicate(true)

func save_profile_snapshot(snapshot: Dictionary) -> bool:
	profile = snapshot.duplicate(true)
	return _save_json(PROFILE_PATH, profile)

func get_profile_snapshot() -> Dictionary:
	return profile.duplicate(true)

func ingest_match_reports(reports: Array) -> Dictionary:
	match_reports = reports.duplicate(true)
	_save_json(REPORTS_PATH, match_reports)
	var snapshot := MatchReportAdapter.build_profile_snapshot(LOCAL_PLAYER_ID, match_reports, state.get("levels", {}))
	save_profile_snapshot(snapshot)
	return snapshot

func regenerate_profile() -> Dictionary:
	return ingest_match_reports(match_reports)

func _seed_demo_profile() -> void:
	match_reports = [
		{"match_id":"demo-001","outcome":"victory","resources":{"gathered":1280,"spent":1060},"production":{"units":34,"routes":["机械化步兵","无人机"]},"construction":{"structures":12,"value":0.72},"combat":{"damage_dealt":8420,"damage_taken":5160,"units_lost":11},"key_events":["快速扩张","中期反攻"],"growth_levels":{"combat_power":2,"economy_gather":1}},
		{"match_id":"demo-002","outcome":"victory","resources":{"gathered":1540,"spent":1320},"production":{"units":41,"routes":["装甲车","炮台"]},"construction":{"structures":16,"value":0.84},"combat":{"damage_dealt":10300,"damage_taken":6220,"units_lost":14},"key_events":["前线筑垒","资源压制"],"growth_levels":{"combat_power":2,"construction_speed":1}},
		{"match_id":"demo-003","outcome":"defeat","resources":{"gathered":980,"spent":910},"production":{"units":25,"routes":["侦察机","步兵"]},"construction":{"structures":8,"value":0.48},"combat":{"damage_dealt":4980,"damage_taken":7810,"units_lost":22},"key_events":["侦察开局","高风险突袭"],"growth_levels":{"economy_gather":2}},
		{"match_id":"demo-004","outcome":"victory","resources":{"gathered":1710,"spent":1450},"production":{"units":46,"routes":["坦克","无人机"]},"construction":{"structures":14,"value":0.76},"combat":{"damage_dealt":11800,"damage_taken":6040,"units_lost":13},"key_events":["稳定运营","侧翼进攻"],"growth_levels":{"combat_guard":1,"economy_stock":1}}
	]
	_save_json(REPORTS_PATH, match_reports)
	var levels: Dictionary = state.get("levels", {}).duplicate(true)
	var snapshot := MatchReportAdapter.build_profile_snapshot(LOCAL_PLAYER_ID, match_reports, levels)
	save_profile_snapshot(snapshot)
