extends GridContainer

const Structure = preload("res://source/match/units/Structure.gd")
const Tank = preload("res://source/match/units/Tank.gd")
const Helicopter = preload("res://source/match/units/Helicopter.gd")

var units = []


func _on_cancel_action_button_pressed():
	if len(units) == 1 and units[0] is Structure and units[0].is_under_construction():
		units[0].cancel_construction()
		return
	for unit in units:
		if unit is Tank or unit is Helicopter:
			var gateway = unit.player.find_child("UnitCommandGateway")
			if gateway != null:
				gateway.StopUnits([unit], unit.player)
			else:
				unit.action = null
