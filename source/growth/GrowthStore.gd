extends Node

const SAVE_PATH := "user://growth_state.json"
const PROFILE_PATH := "user://player_profile.json"
const REPORTS_PATH := "user://match_reports.json"
const MAX_GROWTH_PER_MATCH := 8
## 局后发点规则：赢 3、输 1（都远低于 MAX_GROWTH_PER_MATCH，该常量是硬顶，
## 供以后加"表现分"时兜底，不得被单局突破）。
const MATCH_WIN_POINTS := 3
const MATCH_LOSE_POINTS := 1
const LOCAL_PLAYER_ID := "local_player_demo"

## 成长树定义：**唯一数据源是 `res://config/growth_definitions.json`**
## （每个节点的 name/description/max_level/costs/prerequisite 与 `effect`）。
## 这里刻意不内置任何兜底副本：内置副本没有 `effect`，一旦 json 读取失败，
## 成长会"看起来能加点、实际不生效"地静默退化 —— 那正是 2026-09-21 修复的那个坑。
var DEFINITIONS := {}

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
		push_error("成长定义缺失：res://config/growth_definitions.json（成长树将为空）")
		return
	var parsed = JSON.parse_string(file.get_as_text())
	if parsed is Dictionary and parsed.has("branches"):
		DEFINITIONS = parsed.branches
		return
	push_error("成长定义格式错误：缺少 branches 字段")

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


## 对局奖励成长点：**唯一**发点入口（胜 3 / 负 1，单局硬顶 MAX_GROWTH_PER_MATCH）。
##
## 为什么必须存在：加点系统此前只有初始 12 点，玩家点完就永久停滞 —— "跨对局的永久
## 成长"根本没有来源（2026-09-21 核查）。发点与加点闭环后，玩家才有继续加点的动机。
##
## 不变式与加点同口径：`available + spent == earned`，所以 earned_total 与
## available_points 必须同时增加；写盘失败要整体回滚，不许留下"领了点但没存上"的状态。
func award_match_points(outcome: String) -> Dictionary:
	var amount := 0
	match outcome:
		"victory":
			amount = MATCH_WIN_POINTS
		"defeat":
			amount = MATCH_LOSE_POINTS
		_:
			return {"ok": false, "awarded": 0, "reason": "未知对局结果：%s" % outcome}
	amount = mini(amount, MAX_GROWTH_PER_MATCH)
	if amount <= 0:
		return {"ok": false, "awarded": 0, "reason": "本局不发点"}
	var before := state.duplicate(true)
	state["available_points"] = int(state.get("available_points", 0)) + amount
	state["earned_total"] = int(state.get("earned_total", 0)) + amount
	if not save_state():
		state = before
		return {"ok": false, "awarded": 0, "reason": "无法保存成长状态"}
	return {"ok": true, "awarded": amount, "reason": ""}

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
	## 只返回**已保存的等级**，供 UI 丢弃未保存的暂存选择（"撤销本次选择"，不写盘）。
	return state.duplicate(true)

func reset_all() -> Dictionary:
	## 彻底重置加点（洗点）：清空**已保存**的等级，并把已投入的成长点**全额退还**。
	##
	## 与 `reset_pending()` 的区别必须分清：那个是"撤销本次未保存的选择"，只动 UI 暂存；
	## 这个是连存档一起归零。因此**必须退款** —— 退多少由 costs 数组逐级回滚算出
	## （第 1..level 级各自花的点数之和），否则玩家的点数会凭空蒸发。
	## spent_total 归零（历史累计获得 earned_total 保留），使 available + spent == earned 恒成立。
	var before := state.duplicate(true)
	var levels: Dictionary = state.get("levels", {})
	var refund := 0
	var nodes := 0
	for key in levels.keys():
		var level := int(levels[key])
		if level <= 0:
			continue
		var costs: Array = get_definition(str(key)).get("costs", [])
		for i in range(mini(level, costs.size())):
			refund += int(costs[i])
		nodes += 1
	if nodes == 0 and refund == 0:
		return {
			"ok": true, "refunded": 0, "nodes": 0,
			"reason": "当前没有已投入的加点", "state": state.duplicate(true),
		}
	state["levels"] = {}
	state["available_points"] = int(state.get("available_points", 0)) + refund
	state["spent_total"] = maxi(0, int(state.get("spent_total", 0)) - refund)
	if not save_state():
		state = before
		return {
			"ok": false, "refunded": 0, "nodes": 0,
			"reason": "无法保存成长状态", "state": state.duplicate(true),
		}
	return {
		"ok": true, "refunded": refund, "nodes": nodes,
		"reason": "", "state": state.duplicate(true),
	}

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
