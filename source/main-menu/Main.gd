extends Control


func _ready() -> void:
	# 调试钩子：--autojoin（或 res://autojoin.txt）→ 直接进联机界面，
	# Online._ready 的 autojoin 钩子接管加入+立即开局（供 Godot MCP 一键开局）。
	if "--autojoin" in OS.get_cmdline_user_args() or FileAccess.file_exists("res://autojoin.txt"):
		_on_online_button_pressed()


func _on_campaign_button_pressed():
	get_tree().change_scene_to_file("res://source/campaign/CampaignMenu.tscn")


func _on_play_button_pressed():
	get_tree().change_scene_to_file("res://source/main-menu/Play.tscn")


func _on_online_button_pressed():
	get_tree().change_scene_to_file("res://source/main-menu/Online.tscn")


func _on_options_button_pressed():
	get_tree().change_scene_to_file("res://source/main-menu/Options.tscn")


func _on_credits_button_pressed():
	get_tree().change_scene_to_file("res://source/main-menu/Credits.tscn")


func _on_quit_button_pressed():
	get_tree().quit()
