extends CanvasLayer

const CampaignFlow = preload("res://source/campaign/CampaignFlow.gd")

@onready var _victory_tile = find_child("Victory")
@onready var _defeat_tile = find_child("Defeat")
@onready var _finish_tile = find_child("Finish")
@onready var _campaign_summary = find_child("CampaignSummary")
@onready var _restart_button = find_child("RestartButton")
@onready var _exit_button = find_child("ExitButton")
@onready var _outcome_runtime = find_parent("Match").get_node("MatchOutcomeRuntime")


func _ready():
	if not FeatureFlags.handle_match_end:
		queue_free()
		return
	hide()
	_victory_tile.hide()
	_defeat_tile.hide()
	_finish_tile.hide()
	if _campaign_summary != null:
		_campaign_summary.hide()
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
	if visible or not is_inside_tree():
		return
	_fill_campaign_summary(resolution)
	_configure_campaign_actions()
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


func _fill_campaign_summary(resolution: Dictionary):
	if _campaign_summary == null:
		return
	var campaign = find_parent("Match").get_node_or_null("CampaignController")
	if campaign == null or not campaign.has_method("BuildSettlementText"):
		_campaign_summary.hide()
		return
	_campaign_summary.text = campaign.BuildSettlementText(resolution)
	_campaign_summary.show()


func _configure_campaign_actions():
	var is_campaign := find_parent("Match").get_node_or_null("CampaignController") != null
	if _restart_button != null:
		_restart_button.visible = is_campaign
	if _exit_button != null and is_campaign:
		_exit_button.text = "返回单人战役"


func _on_restart_button_pressed():
	CampaignFlow.restart_from_match(get_tree(), find_parent("Match"))


func _on_exit_button_pressed():
	if find_parent("Match").get_node_or_null("CampaignController") != null:
		CampaignFlow.return_to_campaign_menu(get_tree())
		return
	get_tree().paused = false
	get_tree().change_scene_to_file("res://source/main-menu/Main.tscn")
