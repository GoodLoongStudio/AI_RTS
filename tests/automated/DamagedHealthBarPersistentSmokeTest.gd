extends Node

## 残血血条常显冒烟测试（2026-10-10）
##
## 用户口径：「残血单位和建筑的血条要一直显示的」。
##
## 覆盖（真实 Match，夹具用 `tests/manual/TestAllUnits.tscn`：既有单位也有**已完工建筑**）：
##  1) 满血、未选中 ⇒ 血条隐藏（初始态）；
##  2) 单位（Tank）打掉 25% ⇒ 血条显示，且**超过 2 秒自动隐藏窗口仍在显示**、计时器停表；
##  3) 建筑（VehicleFactory）同样：残血 ⇒ 常显；
##  4) **负例**：`mark_as_under_construction()` 的建筑 hp 从 1 递增，**不得**被当成残血常显
##     （窗口结束后必须隐藏，否则所有在建建筑都会常显血条）；
##  5) 单位与建筑修满 ⇒ 恢复"2 秒窗口后隐藏"的既有行为。

const MatchScene = preload("res://tests/manual/TestAllUnits.tscn")

## 自动隐藏窗口（与 HealthBar.BAR_AUTO_VISIBILITY_DURATION 同口径）。
const AUTO_HIDE_SECONDS := 2.0
const SAMPLE_INTERVAL := 0.1
## 判"常显"要等得比窗口明显更久。
const PERSIST_SECONDS := 3.5

var _failures := 0
var _match: Node = null


func _ready():
	_match = MatchScene.instantiate()
	add_child(_match)
	await get_tree().process_frame
	await get_tree().create_timer(0.5).timeout

	var human = _match.get_node("Players/Human")
	var tank = human.get_node_or_null("Tank")
	var factory = human.get_node_or_null("VehicleFactory")
	var under_construction = human.get_node_or_null("AircraftFactory")
	if tank == null or factory == null or under_construction == null:
		_fail("夹具缺节点：Tank=%s VehicleFactory=%s AircraftFactory=%s" % [
			str(tank), str(factory), str(under_construction)])
		_finish()
		return

	var tank_bar = tank.find_child("HealthBar", true, false)
	var factory_bar = factory.find_child("HealthBar", true, false)
	var uc_bar = under_construction.find_child("HealthBar", true, false)
	_check(tank_bar != null and factory_bar != null and uc_bar != null, "三个目标都应带 HealthBar")
	if tank_bar == null or factory_bar == null or uc_bar == null:
		_finish()
		return

	# 1) 初始：全是满血 ⇒ 都隐藏
	_check(tank.hp == tank.hp_max, "Tank 初始应满血（%s/%s）" % [tank.hp, tank.hp_max])
	_check(factory.hp == factory.hp_max, "VehicleFactory 初始应满血（%s/%s）" % [factory.hp, factory.hp_max])
	_check(not tank_bar.visible, "满血未选中的单位血条应隐藏")
	_check(not factory_bar.visible, "满血未选中的建筑血条应隐藏")

	# 2) 单位残血 ⇒ 常显
	tank.set_hp_without_damage(maxi(1, int(float(tank.hp_max) * 0.75)))
	await get_tree().create_timer(SAMPLE_INTERVAL).timeout
	_check(tank_bar.visible, "单位受伤后血条应立即可见")
	var tank_persist := await _wait_visible(tank_bar, PERSIST_SECONDS)
	_check(tank_persist, "单位残血期间血条必须常显（等待 %.1f 秒仍在显示）" % PERSIST_SECONDS)
	var tank_timer = tank_bar.find_child("Timer", true, false)
	if tank_timer != null:
		_check(tank_timer.is_stopped(), "单位残血常显期间自动隐藏计时器应停表")

	# 3) 建筑残血 ⇒ 常显
	factory.set_hp_without_damage(maxi(1, int(float(factory.hp_max) * 0.75)))
	await get_tree().create_timer(SAMPLE_INTERVAL).timeout
	_check(factory_bar.visible, "建筑受伤后血条应立即可见")
	var factory_persist := await _wait_visible(factory_bar, PERSIST_SECONDS)
	_check(factory_persist, "建筑残血期间血条必须常显（等待 %.1f 秒仍在显示）" % PERSIST_SECONDS)

	# 4) 负例：施工中的建筑 hp 从 1 递增，不得当成残血常显
	under_construction.mark_as_under_construction()
	await get_tree().create_timer(SAMPLE_INTERVAL).timeout
	_check(under_construction.hp < under_construction.hp_max,
		"在建筑事阶段 hp 应小于 hp_max（%s/%s）" % [under_construction.hp, under_construction.hp_max])
	var uc_hidden := await _wait_hidden(uc_bar, AUTO_HIDE_SECONDS + 2.0)
	_check(uc_hidden,
		"施工中的建筑不得被当成残血常显（%.1f 秒内应自动隐藏）" % (AUTO_HIDE_SECONDS + 2.0))

	# 5) 修满 ⇒ 恢复 2 秒窗口后隐藏
	tank.set_hp_without_damage(int(tank.hp_max))
	factory.set_hp_without_damage(int(factory.hp_max))
	var tank_hidden := await _wait_hidden(tank_bar, AUTO_HIDE_SECONDS + 2.0)
	var factory_hidden := await _wait_hidden(factory_bar, AUTO_HIDE_SECONDS + 2.0)
	_check(tank_hidden, "单位修满后应在 2 秒窗口内隐藏")
	_check(factory_hidden, "建筑修满后应在 2 秒窗口内隐藏")

	_finish()


## 在 seconds 秒内持续可见 ⇒ true；期间任何一次不可见 ⇒ false。
func _wait_visible(bar, seconds: float) -> bool:
	var waited := 0.0
	while waited < seconds:
		await get_tree().create_timer(SAMPLE_INTERVAL).timeout
		waited += SAMPLE_INTERVAL
		if not bar.visible:
			return false
	return true


## 在 seconds 秒内出现过不可见 ⇒ true；一直可见到超时 ⇒ false。
func _wait_hidden(bar, seconds: float) -> bool:
	var waited := 0.0
	while waited < seconds:
		await get_tree().create_timer(SAMPLE_INTERVAL).timeout
		waited += SAMPLE_INTERVAL
		if not bar.visible:
			return true
	return false


func _check(condition: bool, message: String):
	if condition:
		print("  ok: %s" % message)
		return
	_fail(message)


func _fail(message: String):
	_failures += 1
	print("FAIL: %s" % message)
	push_error("Damaged health bar persistent assertion failed: %s" % message)


func _finish():
	print("Damaged health bar persistent smoke test completed: %d failure(s)" % _failures)
	SmokeTestExit.request(get_tree(), 0 if _failures == 0 else 1, _match)
