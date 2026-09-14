extends Node

## 临时诊断：打印 TestOneUnit 场景的 HUD 树与本地玩家，用于修 LegacyHudVisibilitySmokeTest。

const MatchScene = preload("res://tests/manual/TestOneUnit.tscn")


func _ready():
	var m = MatchScene.instantiate()
	add_child(m)
	await get_tree().process_frame
	await get_tree().create_timer(0.6).timeout
	print("[HUDTREE] local_player=", m.get_local_player() if m.has_method("get_local_player") else "n/a")
	var hud = m.get_node_or_null("HUD")
	print("[HUDTREE] HUD=", hud, " children=", hud.get_children() if hud != null else "n/a")
	print("[HUDTREE] TraditionalUnitCommandHUD=", m.find_child("TraditionalUnitCommandHUD", true, false))
	print("[HUDTREE] AICommandHUD=", m.find_child("AICommandHUD", true, false))
	print("[HUDTREE] AICommandHUDToggle=", m.find_child("AICommandHUDToggle", true, false))
	print("[HUDTREE] Ra3Sidebar=", m.find_child("Ra3Sidebar", true, false))
	var toggle = m.find_child("AICommandHUDToggle", true, false)
	if toggle != null:
		print("[HUDTREE] toggle text='", toggle.text, "' visible=", toggle.visible)
	get_tree().quit(0)
