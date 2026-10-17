extends Node

func _ready() -> void:
	print("[MIN] alive ✓")
	var m = load("res://source/match/Match.tscn")
	print("[MIN] Match.tscn 可加载:", str(m != null))
	get_tree().quit(0)