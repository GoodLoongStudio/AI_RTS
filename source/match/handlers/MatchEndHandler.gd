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


func _handle_victory():
	_victory_tile.show()
	_show()
	MatchSignals.match_finished_with_victory.emit()


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
