extends Node

## 回归探针（2026-09-28）：验证「单机模式没有电脑玩家也能开局」（用户单独测试用）。
## A. 单机页把其余槽位全设「空位」→ 开始按钮保持可用（旧逻辑不足 2 人会禁用）。
## B. 用只有 1 名人类玩家的 MatchSettings 真实起局 → 进入对局、
##    被判为单人练习房（is_solo_practice，不判胜负、主动退出才结束）。

const PLAY_SCENE := "res://source/main-menu/Play.tscn"
const MAP_SCENE := "res://source/match/maps/PlainAndSimple.tscn"

var _failures: Array[String] = []


func _ready() -> void:
	await get_tree().process_frame
	_test_ui_slot_gate()
	await _test_solo_match_boot()
	if _failures.is_empty():
		print("[SOLO-PROBE] ALL PASS")
		get_tree().quit(0)
	else:
		for f in _failures:
			print("[SOLO-PROBE] FAIL: ", f)
		get_tree().quit(1)


func _check(cond: bool, what: String) -> void:
	if cond:
		print("[SOLO-PROBE] PASS: ", what)
	else:
		_failures.append(what)
		print("[SOLO-PROBE] FAIL: ", what)


func _test_ui_slot_gate() -> void:
	var page: Node = load(PLAY_SCENE).instantiate()
	add_child(page)
	await get_tree().process_frame
	var selects: Array = page._slot_selects
	_check(selects.size() == 4, "单机页应有 4 个槽位下拉（实际 %d）" % selects.size())
	# 复现截图场景：1 号指挥官，2/3/4 全空位（把默认 3 号的简单 AI 也改成空位）。
	var sel: OptionButton = selects[2]
	var none_item := -1
	for i in range(sel.item_count):
		if sel.get_item_id(i) == Constants.PlayerType.NONE:
			none_item = i
	_check(none_item >= 0, "槽位下拉应含「空位」选项")
	sel.select(none_item)
	sel.item_selected.emit(none_item)
	await get_tree().process_frame
	_check(not page._start_button.disabled, "仅剩指挥官一人时开始按钮应可用")
	_check(page._slot_rows[2]["name"].text == "空位", "3 号槽显示应为「空位」")
	page.queue_free()
	await get_tree().process_frame


func _test_solo_match_boot() -> void:
	# 与 Play.gd::_create_match_settings 在"只有 1 号指挥官"时的产物保持同构。
	var settings = load("res://source/data-model/MatchSettings.gd").new()
	var human = load("res://source/data-model/PlayerSettings.gd").new()
	human.controller = Constants.PlayerType.HUMAN
	human.difficulty = Constants.rule_ai_difficulty(Constants.PlayerType.HUMAN)
	human.color = Constants.Player.COLORS[0]
	human.spawn_index_offset = 0
	settings.players.append(human)
	settings.visible_player = 0
	settings.local_player_index = 0
	var a_match: Node = load("res://source/match/Match.tscn").instantiate()
	a_match.settings = settings
	a_match.map = load(MAP_SCENE).instantiate()
	get_tree().root.add_child(a_match)
	get_tree().current_scene = a_match
	for i in range(300):
		await get_tree().process_frame
	var players := get_tree().get_nodes_in_group("players")
	_check(players.size() == 1, "单人局应有 1 名参战玩家（实际 %d）" % players.size())
	_check(NetSession.is_solo_practice(), "单人局应判为单人练习房（不判胜负）")
	_check(is_instance_valid(a_match) and a_match.is_inside_tree(), "对局 300 帧后应仍在运行")
