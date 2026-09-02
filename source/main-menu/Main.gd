extends Control


func _ready():
	AudioDirector.set_music_context("menu")


func _on_campaign_button_pressed():
	AudioDirector.play("ui_click")
	get_tree().change_scene_to_file("res://source/campaign/CampaignMenu.tscn")


func _on_play_button_pressed():
	AudioDirector.play("ui_click")
	get_tree().change_scene_to_file("res://source/main-menu/Play.tscn")


func _on_options_button_pressed():
	AudioDirector.play("ui_click")
	get_tree().change_scene_to_file("res://source/main-menu/Options.tscn")


func _on_credits_button_pressed():
	AudioDirector.play("ui_click")
	get_tree().change_scene_to_file("res://source/main-menu/Credits.tscn")


func _on_quit_button_pressed():
	AudioDirector.play("ui_click")
	get_tree().quit()
