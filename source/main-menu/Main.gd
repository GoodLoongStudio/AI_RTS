extends Control


static var _autojoin_fired := false  # 每进程只生效一次，防止把玩家弹回联机界面


func _ready() -> void:
	# 调试钩子：--autojoin（或 res://autojoin.txt）→ 直接进联机界面，
	# Online._ready 的 autojoin 钩子接管加入+立即开局（供 Godot MCP 一键开局）。
	# 复核 2026-09-02：只在本进程第一次加载 Main 时生效——自动化会话遗留/重建
	# autojoin.txt 期间，玩家点「返回」到主菜单会被立刻弹回联机界面（表现为返回失灵）。
	if not _autojoin_fired and ("--autojoin" in OS.get_cmdline_user_args() or FileAccess.file_exists("res://autojoin.txt")):
		_autojoin_fired = true
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
