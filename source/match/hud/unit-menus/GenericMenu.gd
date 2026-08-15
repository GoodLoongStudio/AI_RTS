extends GridContainer

const Structure = preload("res://source/match/units/Structure.gd")
const Tank = preload("res://source/match/units/Tank.gd")
const Helicopter = preload("res://source/match/units/Helicopter.gd")

var units = []


func _on_cancel_action_button_pressed():
	if len(units) == 1 and units[0] is Structure and units[0].is_under_construction():
		var gateway = units[0].player.find_child("UnitCommandGateway")
		if gateway != null:
			gateway.CancelConstruction(units[0], units[0].player)
		return
	for unit in units:
		if unit is Tank or unit is Helicopter:
			var gateway = unit.player.find_child("UnitCommandGateway")
			if gateway == null:
				push_error("GenericMenu cannot stop unit without UnitCommandGateway")
				continue
			gateway.StopUnits([unit], unit.player)
