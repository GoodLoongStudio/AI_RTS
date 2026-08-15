extends "res://source/match/Match.gd"

## 普通功能测试默认移除终局面板，避免测试中途暂停；胜负专项场景可以显式关闭。
@export var disable_match_end_for_test := true


func _ready():
	if disable_match_end_for_test:
		var handler = find_child("MatchEndHandler")
		if handler != null:
			handler.queue_free()
	super()
