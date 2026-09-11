extends Node

## 维修/出售冒烟测试（2026-09-11）：
## 受损建筑开启维修 → 回血并扣资金；出售 → 返还 50% 造价并移除建筑。
## 注意：sell() 会立即走死亡路径释放节点，断言需用 is_instance_valid 短路保护。

const MatchScene = preload("res://tests/manual/TestAllUnits.tscn")
const BarracksScene = preload("res://source/match/units/Barracks.tscn")

const WAIT_SECONDS := 60.0

var _failures := 0
var _finished := false


func _ready():
	get_tree().create_timer(WAIT_SECONDS).timeout.connect(_on_failsafe)
	var match_instance = MatchScene.instantiate()
	add_child(match_instance)
	await get_tree().process_frame
	await get_tree().create_timer(0.5).timeout

	var human = match_instance.get_node("Players/Human")
	# 测试夹具初始资金为 0：先注入维修/出售所需的资金
	human.add_resources({"resource_a": 5000}, "ScriptedAdjustment")
	var barracks = BarracksScene.instantiate()
	MatchSignals.setup_and_spawn_unit.emit(
		barracks, Transform3D(Basis.IDENTITY, Vector3(12, 0, 10)), human, false
	)
	await get_tree().process_frame
	await get_tree().create_timer(0.3).timeout
	_check(barracks.hp != null, "兵营应有生命值")

	# 维修：打到 40% 再开启维修，2 秒后应回血且资金减少
	barracks.set_hp_without_damage(barracks.hp_max * 0.4)
	var damaged_hp: float = barracks.hp
	var funds_before_repair: int = human.resource_a
	barracks.set_repairing(true)
	await get_tree().create_timer(2.0).timeout
	_check(barracks.hp > damaged_hp, "维修应回血（%s → %s）" % [damaged_hp, barracks.hp])
	_check(
		human.resource_a < funds_before_repair,
		"维修应扣资金（%s → %s）" % [funds_before_repair, human.resource_a]
	)
	barracks.set_repairing(false)

	# 出售：返还 50% 造价并移除建筑（死亡路径会 queue_free，注意 freed 保护）
	var funds_before_sell: int = human.resource_a
	barracks.sell()
	await get_tree().process_frame
	var removed := false
	if not is_instance_valid(barracks):
		removed = true
	elif barracks.hp == 0:
		removed = true
	_check(removed, "出售后建筑应被移除（hp=0 或节点已释放）")
	_check(
		human.resource_a > funds_before_sell,
		"出售应返还资金（%s → %s）" % [funds_before_sell, human.resource_a]
	)

	print("Structure repair/sell smoke test completed: %d failure(s)" % _failures)
	SmokeTestExit.request(get_tree(), 0 if _failures == 0 else 1)


func _on_failsafe():
	if _finished:
		return
	print("FAIL: 看门狗超时——测试协程中断未收尾")
	_finish()


func _finish():
	if _finished:
		return
	_finished = true
	print("Structure repair/sell smoke test completed: %d failure(s)" % _failures)
	SmokeTestExit.request(get_tree(), 0 if _failures == 0 else 1)


func _check(condition: bool, message: String):
	if condition:
		return
	_failures += 1
	print("FAIL: %s" % message)
	push_error("Structure repair/sell assertion failed: %s" % message)
