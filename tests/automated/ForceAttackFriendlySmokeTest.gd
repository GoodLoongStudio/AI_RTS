extends Node

const SmokeTestWarmup = preload("res://tests/automated/SmokeTestWarmup.gd")

## 强制攻击友军冒烟测试（2026-09-07）：
## 单位与炮塔对友军下达强制攻击后应造成伤害（按友伤倍率结算）。

const MatchScene = preload("res://tests/manual/TestAllUnits.tscn")
const WorkerScene = preload("res://source/match/units/Worker.tscn")

const WAIT_SECONDS := 20.0

var _failures := 0
var _finished := false


func _ready():
	get_tree().create_timer(90.0).timeout.connect(_on_failsafe)
	var match_instance = MatchScene.instantiate()
	add_child(match_instance)
	await SmokeTestWarmup.wait_for_units(get_tree(), 1)
	await get_tree().create_timer(0.5).timeout

	var human = match_instance.get_node("Players/Human")
	var actions_controller = human.get_node("UnitActionsController")
	actions_controller.command_feedback.connect(
		func(command_name, accepted, rejected, status):
			print("[FA] feedback %s accepted=%d rejected=%d status=%s" % [
				command_name, accepted, rejected, status
			])
	)

	# 两个友军目标工人
	var worker_a = WorkerScene.instantiate()
	var worker_b = WorkerScene.instantiate()
	var my_tank = match_instance.get_node("Players/Human/Tank")
	var my_turret = match_instance.get_node("Players/Human/AntiGroundTurret")
	# 目标工人放在攻击者贴身处，确保直接进入射程（不依赖寻路接近）
	MatchSignals.setup_and_spawn_unit.emit(
		worker_a, Transform3D(Basis.IDENTITY, my_tank.global_position + Vector3(2.2, 0, 0)), human, false
	)
	MatchSignals.setup_and_spawn_unit.emit(
		worker_b, Transform3D(Basis.IDENTITY, my_turret.global_position + Vector3(2.2, 0, 0)), human, false
	)
	await get_tree().process_frame
	var worker_a_hp_before: float = worker_a.hp
	var worker_b_hp_before: float = worker_b.hp

	# --- 1) 坦克强制攻击友军工人 ---
	MatchSignals.deselect_all_units.emit()
	await get_tree().process_frame
	human.get_node("Tank").get_node("Selection").select()
	await get_tree().process_frame
	actions_controller.begin_force_attack_targeting()
	MatchSignals.unit_targeted.emit(worker_a, worker_a.global_position)
	await get_tree().process_frame
	print(
		"[FA] tank.action=%s targeting=%s" % [
			str(human.get_node("Tank").action),
			str(actions_controller.get_active_command_targeting())
		]
	)

	var waited := 0.0
	while worker_a.hp >= worker_a_hp_before and waited < WAIT_SECONDS:
		await get_tree().create_timer(0.25).timeout
		waited += 0.25
	_check(
		worker_a.hp < worker_a_hp_before,
		"坦克强制攻击友军工人应造成伤害（hp %s → %s）" % [worker_a_hp_before, worker_a.hp]
	)

	# --- 2) 炮塔强制攻击友军工人 ---
	MatchSignals.deselect_all_units.emit()
	await get_tree().process_frame
	human.get_node("AntiGroundTurret").get_node("Selection").select()
	await get_tree().process_frame
	_check(
		actions_controller.get_selected_force_attack_unit_count() == 1,
		"选中炮塔时强制攻击按钮应可用（计数=1）"
	)
	actions_controller.begin_force_attack_targeting()
	MatchSignals.unit_targeted.emit(worker_b, worker_b.global_position)
	await get_tree().process_frame
	var turret = human.get_node("AntiGroundTurret")
	print(
		"[FA] turret.action=%s range=%s dist=%s" % [
			str(turret.action),
			str(turret.get("attack_range")),
			str((turret.global_position - worker_b.global_position).length())
		]
	)

	waited = 0.0
	while worker_b.hp >= worker_b_hp_before and waited < WAIT_SECONDS:
		await get_tree().create_timer(0.25).timeout
		waited += 0.25
	_check(
		worker_b.hp < worker_b_hp_before,
		"炮塔强制攻击友军工人应造成伤害（hp %s → %s）" % [worker_b_hp_before, worker_b.hp]
	)

	_finish()


func _on_failsafe():
	if _finished:
		return
	print("FAIL: 看门狗超时——测试协程中断未收尾")
	_finish()


func _finish():
	if _finished:
		return
	_finished = true
	print("Force attack friendly smoke test completed: %d failure(s)" % _failures)
	SmokeTestExit.request(get_tree(), 0 if _failures == 0 else 1)


func _check(condition: bool, message: String):
	if condition:
		return
	_failures += 1
	print("FAIL: %s" % message)
	push_error("Force attack friendly assertion failed: %s" % message)
