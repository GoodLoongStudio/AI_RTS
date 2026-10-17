extends Node

## 建筑维修速率回归（2026-10-10 用户报"现在建筑维修的速度太慢了"）。
##
## 口径来源：`source/match/units/Structure.gd` 的
## `REPAIR_RATE_HP_PER_SEC = 6.0` / `REPAIR_COST_PER_HP = 0.25`
## （原始设计见 commit 6794720："维修按秒回血 6HP/s 耗 0.25金/HP"）。
##
## 为什么需要这条测试：`Structure._process` 的攒账只累加**资金**（`_repair_debt`），
## 回血却只加**当帧**那一份 —— 前面几十帧攒进 `_repair_debt` 的血全被丢掉。
## 于是实测速率 ≈ `RATE² × COST × delta`：60fps 下只有 **0.15 HP/s（6 的 1/40）**，
## 而且**随帧率变化**（独立复核实测旧实现：30fps 0.2927 / 129fps 0.0725，差 4.0×）。
## 旧断言（`StructureRepairSellSmokeTest`）只要求 `hp > damaged_hp`，
## 2 秒回 0.3HP 也算过 —— 这正是 40× 缩水能活下来的原因。
##
## 三层判据，锋利度递增（第一轮只有第 3 层，独立复核判定"过松"后补前两层）：
##   ① 静态：未知/缺失常量不放过（速率与单价都按**测试自己的**字面量钉死，
##      不跟着实现漂 —— 实现改常量测试照样红）；
##   ② 账本恒等（零容差、逐帧）：凡扣 `owed` 金，HP 必须正好 +`HP_PER_GOLD × owed`
##      （除非被 `hp_max` 夹住）。不受窗口长度、帧率、整数金量化影响。
##      旧实现 12/12 结算全部违反，新实现 0/12。
##   ③ 速率/单价（12% 容差 + 10s 窗口）：窗口越长，整数金量化噪声越小。

const MatchScene = preload("res://tests/manual/TestAllUnits.tscn")
const CommandCenterScene = preload("res://source/match/units/CommandCenter.tscn")

## 测试自己钉死口径字面量（**不要**从实现里读，否则实现漂了测试跟着漂）。
const EXPECTED_RATE_HP_PER_SEC := 6.0
const EXPECTED_COST_PER_HP := 0.25
## = 1 / EXPECTED_COST_PER_HP：付 1 金应恰好回 4 HP。
const HP_PER_GOLD := 4.0
const RATE_TOLERANCE := 0.12
const COST_TOLERANCE := 0.12
## 前 1 金要攒 1/(RATE×COST) ≈ 0.67s 才结算，跳过预热段再计量。
const WARMUP_SECONDS := 1.5
## 10s 窗口 = ~15 次结算，把"每次固定 4 HP"的量化噪声从 ±11% 压到 ±3% 以内。
const MEASURE_SECONDS := 10.0

var _failures := 0
var _match: Node = null

# ---- 逐帧账本恒等（判据②）----
var _ledger_on := false
var _tracked_unit = null
var _tracked_player = null
var _prev_hp := NAN
var _prev_funds := -1
var _settlements := 0
var _ledger_violations: Array[String] = []


func _check(condition: bool, message: String):
	if not condition:
		_failures += 1
		print("FAIL: %s" % message)
		push_error("Structure repair rate assertion failed: %s" % message)


## 逐帧比对 (扣款, 回血)：这是与帧率/窗口长度/金粒度都无关的**零容差**判据。
func _process(_delta):
	if not _ledger_on:
		return
	if _tracked_unit == null or not is_instance_valid(_tracked_unit):
		return
	var hp_now := float(_tracked_unit.hp)
	var funds_now := int(_tracked_player.resource_a)
	if not is_nan(_prev_hp):
		var d_hp := hp_now - _prev_hp
		var d_money := _prev_funds - funds_now
		if d_money > 0:
			_settlements += 1
			var expected := HP_PER_GOLD * float(d_money)
			# 只有"这一笔被 hp_max 夹住"是唯一合法例外（收尾那一笔）。
			var clamped := hp_now >= float(_tracked_unit.hp_max) - 0.0001
			if not clamped and absf(d_hp - expected) > 0.0001:
				_ledger_violations.append(
					"扣 %d 金却回 %.4f HP（应 %.4f）" % [d_money, d_hp, expected]
				)
		elif d_hp > 0.0001:
			_ledger_violations.append("回 %.4f HP 却没有扣钱" % d_hp)
	_prev_hp = hp_now
	_prev_funds = funds_now


func _ready():
	_match = MatchScene.instantiate()
	add_child(_match)
	await get_tree().process_frame
	await get_tree().create_timer(0.5).timeout

	var human = _match.get_node("Players/Human")
	human.add_resources({"resource_a": 100000}, "ScriptedAdjustment")
	var cc = CommandCenterScene.instantiate()
	MatchSignals.setup_and_spawn_unit.emit(
		cc, Transform3D(Basis.IDENTITY, Vector3(12, 0, 10)), human, false
	)
	await get_tree().process_frame
	await get_tree().create_timer(0.3).timeout
	_check(cc.hp != null and float(cc.hp_max) > 0.0, "指挥中心应有生命值")
	if cc.hp == null:
		_finish()
		return

	# 打到 1 HP：预热 1.5s(+9) + 计量 10s(+60) 也修不满 80，全程不撞满血截断。
	cc.set_hp_without_damage(1.0)
	_tracked_unit = cc
	_tracked_player = human
	_ledger_on = true
	cc.set_repairing(true)
	_check(cc.is_repairing(), "维修应已开启")

	var warmed := 0.0
	while warmed < WARMUP_SECONDS:
		await get_tree().process_frame
		warmed += get_process_delta_time()
	_check(
		cc.is_repairing(),
		"预热后维修应仍在进行（hp=%.2f/%.2f）" % [cc.hp, cc.hp_max]
	)

	var hp_start := float(cc.hp)
	var funds_start := int(human.resource_a)
	var elapsed := 0.0
	while elapsed < MEASURE_SECONDS:
		await get_tree().process_frame
		elapsed += get_process_delta_time()
		if float(cc.hp) >= float(cc.hp_max):
			break
	var hp_gain := float(cc.hp) - hp_start
	var funds_spent := funds_start - int(human.resource_a)
	_ledger_on = false

	var measured_rate := hp_gain / elapsed if elapsed > 0.0 else -1.0
	var measured_cost := float(funds_spent) / hp_gain if hp_gain > 0.0 else -1.0
	print(
		"[INFO] 维修实测：%.2fs 回血 %.2fHP ⇒ %.3f HP/s（口径 %.1f）；花 %d 金 ⇒ %.3f 金/HP（口径 %.2f）"
		% [
			elapsed, hp_gain, measured_rate, EXPECTED_RATE_HP_PER_SEC,
			funds_spent, measured_cost, EXPECTED_COST_PER_HP
		]
	)
	print(
		"[INFO] 账本恒等：%d 次结算，%d 次违反（判据 Δhp = %.1f × Δ金）"
		% [_settlements, _ledger_violations.size(), HP_PER_GOLD]
	)

	_check(hp_gain > 0.0, "维修应回血")
	# 判据②：零容差账本恒等 —— 最锋利的回归门（旧实现每次结算都违反）
	_check(_settlements > 0, "窗口内应观察到至少一次资金结算")
	_check(
		_ledger_violations.is_empty(),
		"账本恒等被违反 %d 次，前 3 条：%s"
			% [_ledger_violations.size(), " | ".join(_ledger_violations.slice(0, 3))]
	)
	# 判据③：速率与单价
	_check(
		absf(measured_rate - EXPECTED_RATE_HP_PER_SEC) <= EXPECTED_RATE_HP_PER_SEC * RATE_TOLERANCE,
		"维修速率应为 %.1f HP/s（实际 %.3f，容差 %.0f%%）"
			% [EXPECTED_RATE_HP_PER_SEC, measured_rate, RATE_TOLERANCE * 100.0]
	)
	_check(
		absf(measured_cost - EXPECTED_COST_PER_HP)
			<= EXPECTED_COST_PER_HP * COST_TOLERANCE,
		"维修单价应为 %.2f 金/HP（实际 %.3f）" % [EXPECTED_COST_PER_HP, measured_cost]
	)
	_finish()


func _finish():
	print("Structure repair rate: %d failure(s)" % _failures)
	SmokeTestExit.request(get_tree(), 0 if _failures == 0 else 1, _match)
