extends "res://source/ui/MenuPage.gd"

func _ready() -> void:
	var profile := GrowthStore.get_profile_snapshot()
	var empty := profile.is_empty()
	$CenterContainer/PanelContainer/MarginContainer/VBoxContainer/Sample.text = "暂无 Hermes 画像快照\n完成更多对局后，Hermes 会生成可解释的玩家画像。" if empty else "样本数：%d    生成时间：%s" % [int(profile.get("sample_count", 0)), str(profile.get("generated_at", "未知"))]
	if not empty:
		$CenterContainer/PanelContainer/MarginContainer/VBoxContainer/Dimensions.text = "战斗 %.0f   经济 %.0f   建设 %.0f" % [float(profile.get("dimensions", {}).get("combat", 0)), float(profile.get("dimensions", {}).get("economy", 0)), float(profile.get("dimensions", {}).get("construction", 0))]

func _on_back() -> void:
	get_tree().change_scene_to_file("res://source/main-menu/Growth.tscn")

func _on_escape() -> bool:
	_on_back()
	return true
