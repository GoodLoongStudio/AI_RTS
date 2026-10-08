extends GridContainer

const TankUnit = preload("res://source/match/units/Tank.tscn")
# 【2026-09-28 红警2 口径】矿车（原"工人"）由车厂生产（balance:
# worker.allowedProducerUnitTypeIds=[vehicle_factory]），主基地不再生产。
const WorkerUnit = preload("res://source/match/units/Worker.tscn")

var unit = null

@onready var _tank_button = find_child("ProduceTankButton")
@onready var _worker_button = find_child("ProduceWorkerButton")


func _ready():
	var balance = find_parent("Match").get_node("BalanceConfigRuntime")
	var tank_properties = balance.GetUnitDisplaySnapshot(TankUnit)
	var tank_cost = balance.GetProductionCost(TankUnit)
	_tank_button.tooltip_text = ("{0} - {1}\n{2} HP, {3} DPS\n{4}: {5}".format(
		[
			tr("TANK"),
			tr("TANK_DESCRIPTION"),
			tank_properties["hp_max"],
			tank_properties["attack_damage"] * tank_properties["attack_interval"],
			tr("RESOURCE_A"),
			tank_cost["resource_a"]
		]
	))
	var worker_properties = balance.GetUnitDisplaySnapshot(WorkerUnit)
	var worker_cost = balance.GetProductionCost(WorkerUnit)
	_worker_button.tooltip_text = ("{0} - {1}\n{2} HP\n{3}: {4}".format(
		[
			tr("WORKER"),
			tr("WORKER_DESCRIPTION"),
			worker_properties["hp_max"],
			tr("RESOURCE_A"),
			worker_cost["resource_a"]
		]
	))


func _on_produce_tank_button_pressed():
	unit.production_queue.produce(TankUnit)


func _on_produce_worker_button_pressed():
	unit.production_queue.produce(WorkerUnit)
