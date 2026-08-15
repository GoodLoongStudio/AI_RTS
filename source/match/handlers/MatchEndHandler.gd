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
	_outcome_runtime.match_resolved.connect(_on_match_resolved)


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
	if visible or not is_inside_tree():
		return
	var kind: String = resolution.get("kind", "InProgress")
	var local_side: String = resolution.get("local_human_side_id", "")
	var winners: Array = resolution.get("winning_side_ids", [])
	if kind == "Draw" or local_side.is_empty():
		_handle_finish()
	elif local_side in winners:
		_handle_victory()
	else:
		_handle_defeat()


func _on_exit_button_pressed():
	get_tree().paused = false
	get_tree().change_scene_to_file("res://source/main-menu/Main.tscn")
