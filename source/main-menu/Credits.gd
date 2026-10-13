extends "res://source/ui/MenuPage.gd"

@onready var _rich_text_label = find_child("RichTextLabel")


func _ready():
	_rich_text_label.text = (
		_rich_text_label
		. text
		. replace("CORE_CONTRIBUTORS", tr("CORE_CONTRIBUTORS"))
		. replace("ASSETS", tr("ASSETS"))
	)


func _on_back_button_pressed():
	# 【2026-10-11 修复】ESC 闪退：同步切场景改为帧末（同 Options 页修复）。
	get_tree().change_scene_to_file.call_deferred("res://source/main-menu/Main.tscn")


## ESC 回退（MenuPage 基类）：返回主菜单。
func _on_escape() -> bool:
	_on_back_button_pressed()
	return true
