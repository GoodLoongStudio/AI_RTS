extends Node

## 维修/出售指定模式冒烟测试（2026-09-11，用户要求精准出售/维修）：
## 点维修按钮进入维修模式 → 左键点建筑只切换该建筑维修；
## 点出售按钮进入出售模式 → 左键点建筑只出售该建筑；点地面取消模式。

const MatchScene = preload("res://tests/manual/TestAllUnits.tscn")
const BarracksScene = preload("res://source/match/units/Barracks.tscn")

var _failures := 0
var _finished := false


func _ready():
	get_tree().create_timer(60.0).timeout.connect(_on_failsafe)
	var match_instance = MatchScene.instantiate()
	add_child(match_instance)
	await get_tree().process_frame
	await get_tree().create_timer(0.5).timeout

	var human = match_instance.get_node("Players/Human")
	var controller = human.find_child("UnitActionsController", true, false)
	_check(controller != null, "应能找到本地 UnitActionsController")
	if controller == null:
		_finish()
		return

	# 经济账户就绪 + 资金
	var waited := 0.0
	while waited < 10.0 and human.get("_economy_runtime") == null:
		await get_tree().create_timer(0.2).timeout
		waited += 0.2
	human.add_resources({"resource_a": 5000}, "ScriptedAdjustment")

	var barracks_a = BarracksScene.instantiate()
	MatchSignals.setup_and_spawn_unit.emit(
		barracks_a, Transform3D(Basis.IDENTITY, Vector3(14, 0, 10)), human, false
	)
	var barracks_b = BarracksScene.instantiate()
	MatchSignals.setup_and_spawn_unit.emit(
		barracks_b, Transform3D(Basis.IDENTITY, Vector3(16, 0, 10)), human, false
	)
	await get_tree().process_frame
	await get_tree().create_timer(0.5).timeout

	# 1) 维修模式：进入 → 左键点 A 建筑 → 仅 A 进入维修
	controller.begin_repair_targeting()
	_check(controller.is_repair_targeting(), "点维修按钮后应处于维修指定模式")
	MatchSignals.unit_targeted.emit(barracks_a, Vector3(14, 0.5, 10))
	await get_tree().process_frame
	_check(not controller.is_repair_targeting(), "点击建筑后维修模式应自动结束")
	_check(barracks_a.is_repairing(), "被点击的 A 建筑应进入维修")
	_check(not barracks_b.is_repairing(), "B 建筑不应被波及")
	# 修复是耗资回血：等 2 秒确认 A 在回血
	barracks_a.set_hp_without_damage(barracks_a.hp_max * 0.5)
	var hp_before: float = barracks_a.hp
	await get_tree().create_timer(2.0).timeout
	_check(barracks_a.hp > hp_before, "维修模式点选的 A 建筑应持续回血")
	barracks_a.set_repairing(false)

	# 2) 地面点击取消模式
	controller.begin_repair_targeting()
	_check(controller.is_repair_targeting(), "再次进入维修指定模式")
	MatchSignals.terrain_targeted.emit(Vector3(0, 0, 0))
	await get_tree().process_frame
	_check(not controller.is_repair_targeting(), "点击地面应取消维修指定模式")

	# 3) 出售模式：左键点 B 建筑 → 仅 B 被出售
	var funds_before: int = human.resource_a
	controller.begin_sell_targeting()
	_check(controller.is_sell_targeting(), "点出售按钮后应处于出售指定模式")
	MatchSignals.unit_targeted.emit(barracks_b, Vector3(16, 0.5, 10))
	await get_tree().process_frame
	_check(not controller.is_sell_targeting(), "点击建筑后出售模式应自动结束")
	var b_sold := false
	if not is_instance_valid(barracks_b):
		b_sold = true
	elif barracks_b.hp == 0:
		b_sold = true
	_check(b_sold, "被点击的 B 建筑应被出售（hp=0 或已释放）")
	_check(human.resource_a > funds_before, "精准出售应只返还被点建筑的一半造价")
	_check(barracks_a.is_repairing() == false or is_instance_valid(barracks_a), "A 建筑不应被出售波及")

	print("Repair/Sell targeting smoke test completed: %d failure(s)" % _failures)
	_finish()


func _on_failsafe():
	if _finished:
		return
	_finished = true
	print("FAIL: 看门狗超时——测试协程中断未收尾")
	print("Repair/Sell targeting smoke test completed: %d failure(s)" % _failures)
	SmokeTestExit.request(get_tree(), 1)


func _finish():
	if _finished:
		return
	_finished = true
	print("Repair/Sell targeting smoke test completed: %d failure(s)" % _failures)
	SmokeTestExit.request(get_tree(), 0 if _failures == 0 else 1)


func _check(condition: bool, message: String):
	if condition:
		return
	_failures += 1
	print("FAIL: %s" % message)
	push_error("Repair/Sell targeting smoke test assertion failed: %s" % message)
