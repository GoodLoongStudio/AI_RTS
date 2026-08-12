extends "res://source/match/units/Unit.gd"

const WaitingForTargets = preload("res://source/match/units/actions/WaitingForTargets.gd")


func _get_can_reverse() -> bool:
	return true


func _get_can_fire_while_moving() -> bool:
	return true


func _get_moving_weapon_arc_degrees() -> float:
	return 120.0


func _ready():
	await super()
	action_changed.connect(_on_action_changed)
	action = WaitingForTargets.new()


func _on_action_changed(new_action):
	if new_action == null:
		action = WaitingForTargets.new()
