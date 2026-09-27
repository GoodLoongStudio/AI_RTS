extends Node

## 矿点周期再生冒烟测试（阶段 4 / 提示词 8.2、8.4）。
##
## 用"小容量 + 短等待"的专用夹具跑至少两个完整再生周期，并逐项钉住再生规则：
## 耗尽不删实体（保留身份与计时）、按权威模拟毫秒恢复、矿量不超过容量、暂停不偷跑、
## 同一周期不重复结算、关闭再生时保持旧的"采空即消失"语义、恢复只进矿点不进玩家账户。

const MatchScene = preload("res://tests/manual/TestAllUnits.tscn")
const SmokeTestWarmup = preload("res://tests/automated/SmokeTestWarmup.gd")
const ResourceAScene = preload("res://source/match/units/non-player/ResourceA.tscn")

const CAPACITY := 30
const RESTORE := 10
const DELAY_MS := 800

var _failures := 0
var _finished := false
var _match: Node = null
var _driver: Node = null
var _replenishments := []
var _exhaustions := []


func _ready():
	get_tree().create_timer(150.0).timeout.connect(_on_failsafe)
	_match = MatchScene.instantiate()
	add_child(_match)
	await get_tree().process_frame
	await SmokeTestWarmup.wait_for_units(get_tree(), 1, 2)

	_driver = _match.get_node_or_null("ResourceRegeneration")
	_check(_driver != null, "Match 应带权威再生驱动器 ResourceRegeneration")
	if _driver == null:
		_finish()
		return
	_driver.ore_replenished.connect(_on_replenished)
	_driver.ore_exhausted.connect(_on_exhausted)
	_driver.rule_overrides = {
		"resource_a": {
			"enabled": true,
			"delay_milliseconds": DELAY_MS,
			"restore_amount": RESTORE,
		}
	}

	var human = _match.get_node("Players/Human")
	var balance_before: int = human.resource_a

	# 1) 采空 → 不得删除实体，必须转入"耗尽等待"并保留身份。
	var ore = _spawn_ore(CAPACITY)
	await _ticks(0.2)
	_check(ore.ore_capacity == CAPACITY,
		"矿点容量应记录为开局存量 %d（实际 %d）" % [CAPACITY, ore.ore_capacity])
	ore.resource_a = 0
	await _ticks(0.1)
	_check(is_instance_valid(ore) and not ore.is_queued_for_deletion(),
		"采空后矿点实体必须保留（旧实现 queue_free 会让再生计时无处存放）")
	_check(ore.depleted, "采空后应进入 depleted（耗尽等待）状态")
	_check(_exhaustions.size() == 1, "ore_exhausted 应恰好广播一次（实际 %d）" % _exhaustions.size())

	# 2) 第一个完整周期：等待到点后恢复一份，且重新变为可采。
	await _ticks(1.4)
	_check(ore.resource_a >= RESTORE,
		"一个等待周期后应恢复至少 %d 矿（实际 %d）" % [RESTORE, ore.resource_a])
	_check(not ore.depleted, "恢复到账后应回到可采状态")
	_check(ore.regen_cycles == 1, "第一个周期应恰好结算一次（实际 %d）" % ore.regen_cycles)
	_check(_replenishments.size() == 1,
		"ore_replenished 应与结算次数一致（实际 %d）" % _replenishments.size())

	# 3) 第二个完整周期（连续两周期是提示词 8.4 的硬要求）。
	ore.resource_a = 0
	await _ticks(1.4)
	_check(ore.regen_cycles == 2, "第二个周期应再结算一次（实际 %d）" % ore.regen_cycles)
	_check(ore.resource_a > 0 and not ore.depleted, "第二周期后矿点应重新可采")

	# 4) 矿量不超过容量：让它在满容量的情况下继续"到点"。
	ore.resource_a = CAPACITY
	await _ticks(2.5)
	_check(ore.resource_a <= CAPACITY,
		"恢复累加不得超过容量 %d（实际 %d）" % [CAPACITY, ore.resource_a])

	# 5) 再生只进矿点存量，绝不直接给玩家账户加钱。
	_check(human.resource_a == balance_before,
		"再生期间玩家账户必须分文不动（%d → %d）" % [balance_before, human.resource_a])

	# 6) 暂停不偷跑：暂停时恢复量不得增加（权威模拟毫秒，不是墙钟）。
	ore.resource_a = 0
	await _ticks(0.1)
	var before_pause = int(ore.resource_a)
	var cycles_before_pause = int(ore.regen_cycles)
	get_tree().paused = true
	await _ticks(2.0)
	_check(ore.resource_a == before_pause and ore.regen_cycles == cycles_before_pause,
		"暂停期间再生不得推进（%d/%d → %d/%d）" % [
			before_pause, cycles_before_pause, ore.resource_a, ore.regen_cycles])
	get_tree().paused = false
	await _ticks(1.4)
	_check(ore.regen_cycles > cycles_before_pause,
		"恢复播放后再生必须继续推进（暂停不应丢失矿点身份）")

	# 7) 同一再生周期只结算一次：让驱动器在一个等待窗口内跑几十个物理帧，
	# 只准到账一次（"重复更新不多刷"就是这条）。
	ore.resource_a = 0
	ore.mark_depleted()
	ore.regen_remaining_ms = 1
	var settled = ore.regen_cycles
	await _ticks(0.3)   # 远小于 DELAY_MS=800ms ⇒ 第二个周期不可能已经开始
	_check(ore.regen_cycles == settled + 1,
		"一个等待窗口内应恰好结算一次（%d → %d）" % [settled, ore.regen_cycles])
	_check(ore.resource_a == RESTORE,
		"结算一次只应到账一份恢复量 %d（实际 %d）" % [RESTORE, ore.resource_a])

	# 8) 关闭再生 → 保持旧的"采空即消失"语义。
	_driver.rule_overrides = {"resource_a": {"enabled": false}}
	var legacy = _spawn_ore(10)
	await _ticks(0.2)
	legacy.resource_a = 0
	await _ticks(0.3)
	_check(not is_instance_valid(legacy) or legacy.is_queued_for_deletion(),
		"配置关闭再生时，采空矿点应按旧语义消失")

	_finish()


func _spawn_ore(amount: int):
	var ore = ResourceAScene.instantiate()
	ore.resource_a = amount
	_match.get_node("Map/Resources").add_child(ore)
	var position := Vector3(60.0, 0.0, 60.0)
	if _match.has_method("ground_height_at"):
		position.y = float(_match.ground_height_at(position))
	ore.global_position = position
	return ore


func _ticks(seconds: float):
	await get_tree().create_timer(seconds).timeout
	await get_tree().process_frame


func _on_replenished(_node, _added):
	_replenishments.append([_node, _added])


func _on_exhausted(node):
	_exhaustions.append(node)


func _finish():
	if _finished:
		return
	_finished = true
	print("Ore regeneration smoke test completed: %d failure(s)" % _failures)
	SmokeTestExit.request(get_tree(), 0 if _failures == 0 else 1, _match)


func _on_failsafe():
	if _finished:
		return
	_finished = true
	_failures += 1
	print("FAIL: 看门狗超时——再生测试协程中断未收尾")
	print("Ore regeneration smoke test completed: %d failure(s)" % _failures)
	SmokeTestExit.request(get_tree(), 1, _match)


func _check(condition: bool, message: String):
	if condition:
		return
	_failures += 1
	print("FAIL: %s" % message)
	push_error("Ore regeneration smoke test assertion failed: %s" % message)
