extends GridContainer

const WorkerUnit = preload("res://source/match/units/Worker.tscn")

var unit = null

@onready var _worker_button = find_child("ProduceWorkerButton")


func _ready():
	var balance = find_parent("Match").get_node("BalanceConfigRuntime")
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


func _on_produce_worker_button_pressed():
	unit.production_queue.produce(WorkerUnit)
