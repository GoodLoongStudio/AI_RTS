extends Node

## 火箭炮车冒烟测试（2026-09-11）：
## 车厂生产 → 部署可选中、特性齐全 → 9 米远程火箭溅射命中敌方步兵 → 致死正常清理。

const MatchScene = preload("res://tests/manual/TestAllUnits.tscn")
const RocketArtilleryScene = preload("res://source/match/units/RocketArtillery.tscn")
const InfantryScene = preload("res://source/match/units/Infantry.tscn")
const Player = preload("res://source/match/players/Player.gd")

const PRODUCE_TIMEOUT_SECONDS := 40.0
const COMBAT_WAIT_SECONDS := 20.0
const WAIT_SECONDS := 90.0

var _failures := 0
var _finished := false
var _produced: Array = []


func _ready():
	get_tree().create_timer(WAIT_SECONDS + 30.0).timeout.connect(_on_failsafe)
	MatchSignals.unit_production_finished.connect(_on_unit_production_finished)
	var match_instance = MatchScene.instantiate()
	add_child(match_instance)
	await get_tree().process_frame
	await get_tree().process_frame

	var human = match_instance.get_node("Players/Human")
	var vehicle_factory = human.get_node("VehicleFactory")
	var queue = vehicle_factory.production_queue

	# 权威经济账户异步就绪：轮询注入（先判账户存在避免断言噪音）
	var resources_ready := false
	var waited := 0.0
	while not resources_ready and waited < 10.0:
		if human.get("_economy_runtime") != null:
			resources_ready = human.add_resources({"resource_a": 3000}, "ScriptedAdjustment")
		if not resources_ready:
			await get_tree().create_timer(0.2).timeout
			waited += 0.2
	_check(resources_ready, "权威经济账户应在 10s 内就绪以注入测试资源")

	# 1) 车厂生产火箭炮车
	var item = queue.produce(RocketArtilleryScene)
	_check(item != null, "车厂应可入队生产火箭炮车")
	var elapsed := 0.0
	while _produced.is_empty() and elapsed < PRODUCE_TIMEOUT_SECONDS:
		await get_tree().create_timer(0.2).timeout
		elapsed += 0.2
	_check(
		_produced.size() == 1,
		"火箭炮车应在 %.0fs 内从车厂部署（实际 %d 个）" % [PRODUCE_TIMEOUT_SECONDS, _produced.size()]
	)
	if _produced.is_empty():
		_finish()
		return
	var arty = _produced[0]

	# 2) 部署后：编组/特性/可选中
	_check(arty.is_in_group("controlled_units"), "部署的火箭炮车应编入 controlled_units 组")
	var selection = arty.find_child("Selection", true, false)
	_check(selection != null and selection.has_method("select"), "火箭炮车必须带 Selection 特性")
	_check(arty.find_child("Highlight", true, false) != null, "火箭炮车必须带 Highlight 特性")
	if selection != null and selection.has_method("select"):
		selection.select()

	# 3) 远程溅射作战：9 米射程外的敌方步兵（远超坦克射程）
	var enemy_player = Player.new()
	enemy_player.name = "RocketEnemy"
	enemy_player.color = Color.RED
	enemy_player.add_to_group("players")
	match_instance.get_node("Players").add_child(enemy_player)
	var enemy_soldier = InfantryScene.instantiate()
	MatchSignals.setup_and_spawn_unit.emit(
		enemy_soldier, Transform3D(Basis.IDENTITY, Vector3(8.5, 0, 0)), enemy_player, false
	)
	await get_tree().process_frame
	await get_tree().create_timer(0.5).timeout
	var hp_before: float = enemy_soldier.hp

	var combat_waited := 0.0
	while combat_waited < COMBAT_WAIT_SECONDS:
		if not is_instance_valid(enemy_soldier) or enemy_soldier.hp < hp_before:
			break
		await get_tree().create_timer(0.25).timeout
		combat_waited += 0.25
	_check(
		not is_instance_valid(enemy_soldier) or enemy_soldier.hp < hp_before,
		"火箭炮车应在 %s 秒内远程溅射命中敌方步兵" % COMBAT_WAIT_SECONDS
	)

	# 4) 致死伤害正常清理
	if is_instance_valid(arty):
		arty.hp = 0
		var removal_waited := 0.0
		while is_instance_valid(arty) and removal_waited < 10.0:
			await get_tree().create_timer(0.2).timeout
			removal_waited += 0.2
	_check(not is_instance_valid(arty), "火箭炮车致死伤害后应在 10s 内完成死亡清理")

	_finish()


func _on_unit_production_finished(unit, producer):
	if producer.name == "VehicleFactory" and unit.scene_file_path == RocketArtilleryScene.resource_path:
		_produced.append(unit)


func _on_failsafe():
	if _finished:
		return
	print("FAIL: 看门狗超时——测试协程中断未收尾")
	_finish()


func _finish():
	if _finished:
		return
	_finished = true
	print("Rocket artillery smoke test completed: %d failure(s)" % _failures)
	SmokeTestExit.request(get_tree(), 0 if _failures == 0 else 1)


func _check(condition: bool, message: String):
	if condition:
		return
	_failures += 1
	print("FAIL: %s" % message)
	push_error("Rocket artillery smoke test assertion failed: %s" % message)
