extends GridContainer

const HelicopterUnit = preload("res://source/match/units/Helicopter.tscn")
const DroneUnit = preload("res://source/match/units/Drone.tscn")

var unit = null

@onready var _helicopter_button = find_child("ProduceHelicopterButton")
@onready var _drone_button = find_child("ProduceDroneButton")


func _ready():
	var balance = find_parent("Match").get_node("BalanceConfigRuntime")
	var helicopter_properties = balance.GetUnitDisplaySnapshot(HelicopterUnit)
	var helicopter_cost = balance.GetProductionCost(HelicopterUnit)
	_helicopter_button.tooltip_text = ("{0} - {1}\n{2} HP, {3} DPS\n{4}: {5}, {6}: {7}".format(
		[
			tr("HELICOPTER"),
			tr("HELICOPTER_DESCRIPTION"),
			helicopter_properties["hp_max"],
			helicopter_properties["attack_damage"] * helicopter_properties["attack_interval"],
			tr("RESOURCE_A"),
			helicopter_cost["resource_a"],
			tr("RESOURCE_B"),
			helicopter_cost["resource_b"]
		]
	))
	var drone_properties = balance.GetUnitDisplaySnapshot(DroneUnit)
	var drone_cost = balance.GetProductionCost(DroneUnit)
	_drone_button.tooltip_text = ("{0} - {1}\n{2} HP\n{3}: {4}, {5}: {6}".format(
		[
			tr("DRONE"),
			tr("DRONE_DESCRIPTION"),
			drone_properties["hp_max"],
			tr("RESOURCE_A"),
			drone_cost["resource_a"],
			tr("RESOURCE_B"),
			drone_cost["resource_b"]
		]
	))


func _on_produce_helicopter_button_pressed():
	unit.production_queue.produce(HelicopterUnit)


func _on_produce_drone_button_pressed():
	unit.production_queue.produce(DroneUnit)
