extends Node

## 专项验收（2026-09-30 用户口径）：矿车只能把矿交给**矿场**。
## ① 无矿场时：矿车采集满载后不得回主基地交矿入账，也不得在矿点-主基地间死循环；
## ② 矿场建成接管后：满载矿车恢复正常交付（矿场账本入账）。
## 运行：Godot --headless --path <repo> res://tests/automated/WorkerDeliveryRefineryOnlyTest.tscn

const MatchScene = preload("res://tests/manual/TestAllUnits.tscn")
const SmokeTestWarmup = preload("res://tests/automated/SmokeTestWarmup.gd")
const RefineryScene = preload("res://source/match/units/OreRefinery.tscn")
const WorkerScene = preload("res://source/match/units/Worker.tscn")
const ResourceAScene = preload("res://source/match/units/non-player/ResourceA.tscn")
const CollectingResourcesSequentially = preload(
	"res://source/match/units/actions/CollectingResourcesSequentially.gd"
)

var _failures := 0
var _finished := false
var _match: Node = null


func _ready():
	get_tree().create_timer(240.0).timeout.connect(_on_failsafe)
	_match = MatchScene.instantiate()
	add_child(_match)
	await get_tree().process_frame
	await SmokeTestWarmup.wait_for_units(get_tree(), 1, 2)

	var human = _match.get_node("Players/Human")
	var worker = _spawn_worker(Vector3(40.0, 0.0, 40.0), human)
	var ore = _spawn_ore(Vector3(44.0, 0.0, 40.0), 4000)
	await _ticks(1.0)

	# —— 场景 A：无矿场 ——（TestAllUnits 夹具自带主基地，正好用来验证"不能回主基地交矿"）
	var balance_before: int = human.resource_a
	_check(
		CollectingResourcesSequentially.find_drop_off(worker) == null,
		"A·前置：没有己方完工矿场时没有可交货点（find_drop_off=null，主基地不算）"
	)
	var gateway = human.get_node("UnitCommandGateway")
	var result: Dictionary = gateway.GatherResources([worker], ore, human)
	var accepted := int(result.get("accepted", 0)) > 0 or str(result.get("status", "")) == "Accepted"
	_check(accepted, "A·前置：采集订单应被接受（%s）" % str(result))

	# 等矿车采满（120ms/单位 ⇒ 一车最多 ~50s）。
	var waited := 0.0
	while int(worker.get("resource_a")) <= 0 and waited < 90.0:
		await _ticks(3.0)
		waited += 3.0
	_check(int(worker.get("resource_a")) > 0, "A·1：矿车应已采到矿（车上 %d）" % int(worker.get("resource_a")))

	# 满载后再等 12 秒：旧口径此时已经回主基地入账；新口径必须原地持货、账户纹丝不动。
	await _ticks(12.0)
	var carried := int(worker.get("resource_a"))
	_check(carried > 0, "A·2：无矿场时满载矿车必须持货不卸（车上 %d）" % carried)
	_check(
		human.resource_a == balance_before,
		"A·3：无矿场时账户不得增长（实际 %d → %d）" % [balance_before, human.resource_a]
	)
	var distance_to_cc := _planar_distance_to_nearest_cc(worker, human)
	_check(
		distance_to_cc > 6.0,
		"A·4：矿车不得停进主基地（距最近主基地 %.1fm）" % distance_to_cc
	)

	# —— 场景 B：矿场建成接管，满载矿车恢复交付 ——
	var refinery = _spawn_refinery(Vector3(42.0, 0.0, 36.0), human)
	refinery.service_radius_m = 1.0
	refinery.claim_interval_s = 0.2
	var delivery_before := int(refinery.delivery_stats().get("delivered_count", 0))
	var recover_waited := 0.0
	while (
		int(refinery.delivery_stats().get("delivered_count", 0)) <= delivery_before
		and recover_waited < 120.0
	):
		await _ticks(5.0)
		recover_waited += 5.0
	_check(
		int(refinery.delivery_stats().get("delivered_count", 0)) > delivery_before,
		"B·1：矿场接管后矿车应把货交给矿场（等了 %.0fs，交付 %d 次）"
			% [recover_waited, int(refinery.delivery_stats().get("delivered_count", 0))]
	)
	_check(
		human.resource_a > balance_before,
		"B·2：矿场接管后账户应真实增长（%d → %d）" % [balance_before, human.resource_a]
	)

	_finish()


func _planar_distance_to_nearest_cc(unit, player) -> float:
	var nearest := INF
	for node in get_tree().get_nodes_in_group("units"):
		if not is_instance_valid(node) or not node.is_inside_tree():
			continue
		if node.get_parent() != player:
			continue
		if node.get_script() != null and str(node.get_script().resource_path).ends_with("CommandCenter.gd"):
			nearest = minf(nearest, Vector2(
				unit.global_position.x - node.global_position.x,
				unit.global_position.z - node.global_position.z).length())
	return nearest


func _spawn_refinery(position: Vector3, player):
	var refinery = RefineryScene.instantiate()
	_match.call("_setup_and_spawn_unit", refinery, Transform3D(Basis.IDENTITY, position), player, false)
	return refinery


func _spawn_worker(position: Vector3, player):
	var worker = WorkerScene.instantiate()
	_match.call("_setup_and_spawn_unit", worker, Transform3D(Basis.IDENTITY, position), player, false)
	return worker


func _spawn_ore(position: Vector3, amount: int):
	var ore = ResourceAScene.instantiate()
	ore.resource_a = amount
	_match.get_node("Map/Resources").add_child(ore)
	ore.global_position = Vector3(
		position.x,
		_match.ground_height_at(position) if _match.has_method("ground_height_at") else position.y,
		position.z
	)
	return ore


func _ticks(seconds: float):
	await get_tree().create_timer(seconds).timeout
	await get_tree().process_frame


func _check(condition: bool, label: String):
	if condition:
		print("PASS ", label)
	else:
		print("FAIL ", label)
		_failures += 1


func _on_failsafe():
	if _finished:
		return
	_finished = true
	_failures += 1
	print("FAIL 看门狗超时（240s）")
	get_tree().quit(1)


func _finish():
	if _finished:
		return
	_finished = true
	print("RESULT ", "PASS" if _failures == 0 else "FAIL(%d)" % _failures)
	get_tree().quit(1 if _failures > 0 else 0)
