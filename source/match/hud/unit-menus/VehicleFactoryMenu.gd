extends GridContainer

const TankUnit = preload("res://source/match/units/Tank.tscn")

var unit = null

@onready var _tank_button = find_child("ProduceTankButton")


func _ready():
	var balance = find_parent("Match").get_node("BalanceConfigRuntime")
	var tank_properties = balance.GetUnitDisplaySnapshot(TankUnit)
	var tank_cost = balance.GetProductionCost(TankUnit)
	_tank_button.tooltip_text = ("{0} - {1}\n{2} HP, {3} DPS\n{4}: {5}, {6}: {7}".format(
		[
			tr("TANK"),
			tr("TANK_DESCRIPTION"),
			tank_properties["hp_max"],
			tank_properties["attack_damage"] * tank_properties["attack_interval"],
			tr("RESOURCE_A"),
			tank_cost["resource_a"],
			tr("RESOURCE_B"),
			tank_cost["resource_b"]
		]
	))


func _on_produce_tank_button_pressed():
	unit.production_queue.produce(TankUnit)
