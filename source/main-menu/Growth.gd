extends "res://source/ui/MenuPage.gd"

func _ready() -> void:
	$CenterContainer/PanelContainer/MarginContainer/VBoxContainer/UpgradesButton.grab_focus()

func _on_upgrades_pressed() -> void:
	get_tree().change_scene_to_file("res://source/main-menu/GrowthUpgrades.tscn")

func _on_profile_pressed() -> void:
	get_tree().change_scene_to_file("res://source/main-menu/PlayerProfile.tscn")

func _on_back_pressed() -> void:
	get_tree().change_scene_to_file("res://source/main-menu/Main.tscn")

func _on_escape() -> bool:
	_on_back_pressed()
	return true
