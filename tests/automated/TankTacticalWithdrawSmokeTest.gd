extends Node

const MatchScene = preload("res://tests/manual/TestOneUnit.tscn")
const TacticalWithdrawing = preload(
	"res://source/match/units/actions/TacticalWithdrawing.gd"
)

var _failures := 0


func _ready():
	var match_instance = MatchScene.instantiate()
	add_child(match_instance)
	await get_tree().process_frame
	await get_tree().process_frame

	var human = match_instance.get_node("Players/Human")
	var tank = human.get_node("Tank")
	var gateway = human.get_node("UnitCommandGateway")
	var start_position: Vector3 = tank.global_position
	var destination := start_position + Vector3(0.0, 0.0, 4.0)
	var result = gateway.TacticalWithdrawUnits([tank], destination, human)
	var order_id: String = result["unit_results"][0]["order_id"]

	_check(result["status"] == "Accepted", "Tank 撤退命令应被接受")
	_check(tank.action != null and tank.action.get_script() == TacticalWithdrawing, "Tank 应进入撤退行为")
	await get_tree().create_timer(0.4).timeout
	var displacement: Vector3 = tank.global_position - start_position
	var chassis_forward: Vector3 = -tank.global_transform.basis.z * Vector3(1, 0, 1)
	_check(displacement.length() > 0.05, "Tank 应沿导航路径发生位移")
	_check(
		chassis_forward.normalized().dot(-displacement.normalized()) > 0.75,
		"Tank 车头应与实际撤退路径方向相反"
	)

	var halt_result = gateway.HaltMovement([tank], human)
	_check(halt_result["status"] == "Accepted", "撤退中的停止应被接受")
	_check(gateway.GetOrderState(order_id) == "Suspended", "停止应暂停撤退订单")

	print("Tank tactical withdraw smoke test completed: %d failure(s)" % _failures)
	match_instance.queue_free()
	await get_tree().process_frame
	get_tree().quit(0 if _failures == 0 else 1)


func _check(condition: bool, message: String):
	if condition:
		return
	_failures += 1
	push_error("Tank tactical withdraw assertion failed: %s" % message)
