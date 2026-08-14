extends "res://source/match/Match.gd"

func _ready():
	find_child("MatchEndHandler").queue_free()
	super()
