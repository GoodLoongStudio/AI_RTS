extends CanvasLayer

@onready var _victory_tile = find_child("Victory")
@onready var _defeat_tile = find_child("Defeat")
@onready var _finish_tile = find_child("Finish")
@onready var _outcome_runtime = find_parent("Match").get_node("MatchOutcomeRuntime")


func _ready():
	if not FeatureFlags.handle_match_end:
		queue_free()
		return
	hide()
	_victory_tile.hide()
	_defeat_tile.hide()
	_finish_tile.hide()
	_outcome_runtime.connect("MatchResolved", _on_match_resolved)


func _handle_defeat():
	_defeat_tile.show()
	_show()
	MatchSignals.match_finished_with_defeat.emit()
	_award_growth_points("defeat", _defeat_tile)


func _handle_victory():
	_victory_tile.show()
	_show()
	MatchSignals.match_finished_with_victory.emit()
	_award_growth_points("victory", _victory_tile)


## 对局奖励成长点（胜 3 / 负 1）并就地反馈给玩家。
##
## 只在**单机**发放：`GrowthStore` 是本地存档，联机/专用服上发点等于让客户端自造收益，
## 且权威端（服务器）没有"玩家本地存档"这一概念。规则与硬顶见
## `GrowthStore.award_match_points()`（唯一发点入口，本函数只负责调用与展示）。
func _award_growth_points(outcome: String, tile: Node) -> void:
	if NetSession.is_networked():
		return
	var store := get_node_or_null("/root/GrowthStore")
	if store == null or not store.has_method("award_match_points"):
		return
	var result: Dictionary = store.call("award_match_points", outcome)
	if not bool(result.get("ok", false)):
		push_warning("[GROWTH] 对局奖励未发放：%s" % str(result.get("reason", "")))
		return
	var awarded := int(result.get("awarded", 0))
	print("[GROWTH] 对局结算 %s：+%d 成长点（可用 %d）" % [
		outcome, awarded, int(store.state.get("available_points", 0)),
	])
	var label := tile.find_child("Label", true, false) if tile != null else null
	if label is Label:
		(label as Label).text = "%s\n成长点 +%d" % [(label as Label).text, awarded]


func _handle_finish():
	_finish_tile.show()
	_show()


func _show():
	show()
	get_tree().paused = true


## 将结构化终态映射到当前 Legacy 面板；胜负计算不在 UI 中进行。
func _on_match_resolved(resolution: Dictionary):
	# 单人练习房：不以胜负结束，玩家主动退出才算结束（设计师需求 2026-09-04）。
	if NetSession.is_solo_practice():
		return
	if visible or not is_inside_tree():
		return
	var local_result: String = str(resolution.get("local_result", ""))
	if local_result.is_empty():
		var kind: String = resolution.get("kind", "InProgress")
		var local_side: String = resolution.get("local_human_side_id", "")
		var winners: Array = resolution.get("winning_side_ids", [])
		if kind == "Draw" or local_side.is_empty():
			local_result = "Finish"
		elif local_side in winners:
			local_result = "Victory"
		else:
			local_result = "Defeat"
	if local_result == "Victory":
		_handle_victory()
	elif local_result == "Defeat":
		_handle_defeat()
	else:
		_handle_finish()


func _on_exit_button_pressed():
	get_tree().paused = false
	# 同"退出战斗"：回主菜单前断开会话，避免残留房间/本机 server 状态（2026-09-14）。
	NetSession.disconnect_if_networked()
	get_tree().change_scene_to_file("res://source/main-menu/Main.tscn")
