extends Node

const MatchScene = preload("res://tests/manual/TestAllUnits.tscn")
const AutoGatherAction = preload(
	"res://source/match/units/actions/AutoGatheringResources.gd"
)
const ReturnToBaseAction = preload(
	"res://source/match/units/actions/ReturningToBase.gd"
)

var _failures := 0


func _ready():
	var match_instance = MatchScene.instantiate()
	add_child(match_instance)
	await get_tree().process_frame
	await get_tree().process_frame

	var human = match_instance.get_node("Players/Human")
	var worker = human.get_node("Worker")
	var controller = human.get_node("UnitActionsController")
	var gateway = human.get_node("UnitCommandGateway")
	MatchSignals.deselect_all_units.emit()
	worker.find_child("Selection").select()

	controller.set_selected_engagement_stance("Aggressive")
	await get_tree().process_frame
	await get_tree().process_frame
	_check(
		worker.action != null and worker.action.get_script() == AutoGatherAction,
		"Worker 设置侵略姿态后应开始自动搜寻资源"
	)
	_check(
		gateway.GetEngagementStance(worker) == "Aggressive",
		"Worker 侵略姿态应写入权威策略"
	)

	controller.set_selected_engagement_stance("ReturnToBase")
	await get_tree().process_frame
	_check(
		worker.action != null and worker.action.get_script() == ReturnToBaseAction,
		"Worker 设置撤回基地后应切换到回基地动作"
	)
	_check(
		gateway.GetEngagementStance(worker) == "ReturnToBase",
		"Worker 回基地姿态应写入权威策略"
	)

	print("Worker engagement policy smoke test completed: %d failure(s)" % _failures)
	match_instance.queue_free()
	await get_tree().process_frame
	SmokeTestExit.request(get_tree(), 0 if _failures == 0 else 1)


func _check(condition: bool, message: String):
	if condition:
		return
	_failures += 1
	push_error("Worker engagement policy assertion failed: " + message)
