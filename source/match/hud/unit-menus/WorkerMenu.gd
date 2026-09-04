extends GridContainer

const CommandCenterUnit = preload("res://source/match/units/CommandCenter.tscn")
const VehicleFactoryUnit = preload("res://source/match/units/VehicleFactory.tscn")
const AircraftFactoryUnit = preload("res://source/match/units/AircraftFactory.tscn")
const AntiGroundTurretUnit = preload("res://source/match/units/AntiGroundTurret.tscn")
const AntiAirTurretUnit = preload("res://source/match/units/AntiAirTurret.tscn")

@onready var _ag_turret_button = find_child("PlaceAntiGroundTurretButton")
@onready var _aa_turret_button = find_child("PlaceAntiAirTurretButton")
@onready var _cc_button = find_child("PlaceCommandCenterButton")
@onready var _vehicle_factory_button = find_child("PlaceVehicleFactoryButton")
@onready var _aircraft_factory_button = find_child("PlaceAircraftFactoryButton")


func _ready():
	var balance = find_parent("Match").get_node("BalanceConfigRuntime")
	var ag_turret_properties = balance.GetUnitDisplaySnapshot(AntiGroundTurretUnit)
	var ag_turret_cost = balance.GetConstructionCost(AntiGroundTurretUnit)
	_ag_turret_button.tooltip_text = ("{0} - {1}\n{2} HP, {3} DPS\n{4}: {5}".format(
		[
			tr("AG_TURRET"),
			tr("AG_TURRET_DESCRIPTION"),
			ag_turret_properties["hp_max"],
			ag_turret_properties["attack_damage"] * ag_turret_properties["attack_interval"],
			tr("RESOURCE_A"),
			ag_turret_cost["resource_a"]
		]
	))
	var aa_turret_properties = balance.GetUnitDisplaySnapshot(AntiAirTurretUnit)
	var aa_turret_cost = balance.GetConstructionCost(AntiAirTurretUnit)
	_aa_turret_button.tooltip_text = ("{0} - {1}\n{2} HP, {3} DPS\n{4}: {5}".format(
		[
			tr("AA_TURRET"),
			tr("AA_TURRET_DESCRIPTION"),
			aa_turret_properties["hp_max"],
			aa_turret_properties["attack_damage"] * aa_turret_properties["attack_interval"],
			tr("RESOURCE_A"),
			aa_turret_cost["resource_a"]
		]
	))
	var cc_properties = balance.GetUnitDisplaySnapshot(CommandCenterUnit)
	var cc_cost = balance.GetConstructionCost(CommandCenterUnit)
	_cc_button.tooltip_text = ("{0} - {1}\n{2} HP\n{3}: {4}".format(
		[
			tr("CC"),
			tr("CC_DESCRIPTION"),
			cc_properties["hp_max"],
			tr("RESOURCE_A"),
			cc_cost["resource_a"]
		]
	))
	var vehicle_factory_properties = balance.GetUnitDisplaySnapshot(VehicleFactoryUnit)
	var vehicle_factory_cost = balance.GetConstructionCost(VehicleFactoryUnit)
	_vehicle_factory_button.tooltip_text = ("{0} - {1}\n{2} HP\n{3}: {4}".format(
		[
			tr("VEHICLE_FACTORY"),
			tr("VEHICLE_FACTORY_DESCRIPTION"),
			vehicle_factory_properties["hp_max"],
			tr("RESOURCE_A"),
			vehicle_factory_cost["resource_a"]
		]
	))
	var aircraft_factory_properties = balance.GetUnitDisplaySnapshot(AircraftFactoryUnit)
	var aircraft_factory_cost = balance.GetConstructionCost(AircraftFactoryUnit)
	_aircraft_factory_button.tooltip_text = ("{0} - {1}\n{2} HP\n{3}: {4}".format(
		[
			tr("AIRCRAFT_FACTORY"),
			tr("AIRCRAFT_FACTORY_DESCRIPTION"),
			aircraft_factory_properties["hp_max"],
			tr("RESOURCE_A"),
			aircraft_factory_cost["resource_a"]
		]
	))


func _on_place_command_center_button_pressed():
	MatchSignals.place_structure.emit(CommandCenterUnit)


func _on_place_vehicle_factory_button_pressed():
	MatchSignals.place_structure.emit(VehicleFactoryUnit)


func _on_place_aircraft_factory_button_pressed():
	MatchSignals.place_structure.emit(AircraftFactoryUnit)


func _on_place_anti_ground_turret_button_pressed():
	MatchSignals.place_structure.emit(AntiGroundTurretUnit)


func _on_place_anti_air_turret_button_pressed():
	MatchSignals.place_structure.emit(AntiAirTurretUnit)
