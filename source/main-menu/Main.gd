extends Control

## 主菜单背景音乐（2026-09-07）：菜单场景内循环 menu_theme。
const MENU_MUSIC := "res://assets/music/menu_theme.wav"
const MENU_MUSIC_DB := -8.0

static var _autojoin_fired := false  # 每进程只生效一次，防止把玩家弹回联机界面


func _ready() -> void:
	_start_menu_music()
	# 调试钩子：--autojoin（或 res://autojoin.txt）→ 直接进联机界面，
	# Online._ready 的 autojoin 钩子接管加入+立即开局（供 Godot MCP 一键开局）。
	# 复核 2026-09-02：只在本进程第一次加载 Main 时生效——自动化会话遗留/重建
	# autojoin.txt 期间，玩家点「返回」到主菜单会被立刻弹回联机界面（表现为返回失灵）。
	if not _autojoin_fired and "--autojoin" in OS.get_cmdline_user_args():
		_autojoin_fired = true
		_on_online_button_pressed()


func _start_menu_music() -> void:
	if not ResourceLoader.exists(MENU_MUSIC):
		return
	var player := AudioStreamPlayer.new()
	player.name = "MenuMusic"
	var stream = load(MENU_MUSIC)
	if stream is AudioStreamWAV:
		stream.loop_mode = AudioStreamWAV.LOOP_FORWARD
		stream.loop_begin = 0
		stream.loop_end = stream.data.size() / 4  # 16-bit 立体声帧数
	player.stream = stream
	player.volume_db = MENU_MUSIC_DB
	add_child(player)
	player.play()


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
