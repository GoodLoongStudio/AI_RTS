extends Node

## 血条可见性回归测试（2026-09-10 建立；2026-10-10 按新口径更新断言）
## 现象（用户报告）：血条“一闪一闪”。
## 根因：HealthBar.gd 的 _show_for_a_while() 在血条已可见时直接 return，
##       不会续期自动隐藏计时器 —— 于是首次伤害后 2 秒计时器到点熄灭，
##       下一次伤害又点亮，只要伤害间隔 < 2 秒就形成周期性闪烁。
##
## 【2026-10-10 口径变更】用户要求「残血单位和建筑的血条要一直显示的」：
##   残血（hp < hp_max，且**非施工中**）⇒ 血条常显，不再受 2 秒窗口限制。
##   因此本测试里两条旧断言**按产品口径变更**（不是把判据改绿）：
##     · 旧 2)「停止掉血 2 秒后应自动隐藏」→ 新：残血期间**必须一直显示**，且计时器停表；
##       新增「修满后仍在 2 秒窗口内自动隐藏」以保留旧行为；
##     · 旧 3)「取消选中后血条应隐藏」→ 新：残血时取消选中**继续显示**，
##       修满后取消选中才隐藏。
##   断言 1（持续掉血不闪）与断言 4（数值不变不点亮，且必须在**满血**下测）保持不变。
##
## 断言：
##  1) 持续掉血期间（每 1 秒一次，短于 2 秒隐藏窗口）血条不得出现熄灭；
##  2) 残血期间常显（超过窗口仍在显示、计时器停表）；修满后 2 秒窗口内自动隐藏；
##  3) 选中期间必须常显；残血时取消选中继续显示；满血取消选中才隐藏；
##  4) 满血且血量不变时不得无谓点亮（避免网络快照每帧赋值导致闪烁）。

const MatchScene = preload("res://tests/manual/TestAllUnits.tscn")

const DAMAGE_INTERVAL := 1.0
const DAMAGE_SECONDS := 6.0
const AUTO_HIDE_SECONDS := 2.0
const SAMPLE_INTERVAL := 0.1

var _failures := 0
## 整局根节点：收尾时必须回收（见 SmokeTestExit.request 的说明）。
var _match: Node = null


func _ready():
	_match = MatchScene.instantiate()
	add_child(_match)
	await get_tree().process_frame
	await get_tree().create_timer(0.5).timeout

	var human = _match.get_node("Players/Human")
	var tank = human.get_node_or_null("Tank")
	if tank == null:
		_fail("测试场景中未找到己方 Tank")
		_finish()
		return

	var bar = tank.find_child("HealthBar", true, false)
	if bar == null:
		_fail("Tank 上未找到 HealthBar")
		_finish()
		return
	var timer = bar.find_child("Timer", true, false)

	_check(tank.hp != null and tank.hp_max != null, "Tank 必须带有 hp/hp_max")
	if tank.hp == null or tank.hp_max == null:
		_finish()
		return

	# 0) 初始隐藏
	_check(not bar.visible, "初始血条应隐藏")

	# 1) 持续掉血期间不得闪烁
	var hidden_samples := 0
	var damage_count := 0
	var elapsed := 0.0
	var next_damage := 0.0
	while elapsed < DAMAGE_SECONDS:
		if elapsed >= next_damage:
			var damage := maxi(1, int(float(tank.hp_max) * 0.02))
			# ⚠️ 必须用 `set_hp_without_damage()`，不能直接赋 `tank.hp`：
			# 本项目的 `hp` 由伤害模型驱动，直接赋值会被立刻回写成原值——
			# 实测每 1 秒一次的"持续掉血"只有一半真正生效，有效间隔恰好等于
			# 2 秒自动隐藏窗口，于是血条在该熄灭/点亮之间抖动（实测 12/60 采样熄灭），
			# 让断言 1 变成"夹具不可靠"而不是产品问题。2026-09-14 定位。
			tank.set_hp_without_damage(int(tank.hp) - damage)
			damage_count += 1
			next_damage += DAMAGE_INTERVAL
		if elapsed > 0.3 and not bar.visible:
			hidden_samples += 1
		await get_tree().create_timer(SAMPLE_INTERVAL).timeout
		elapsed += SAMPLE_INTERVAL

	_check(damage_count >= 5, "持续掉血阶段应产生至少 5 次伤害（实际 %d）" % damage_count)
	_check(hidden_samples == 0,
		"持续掉血期间血条不得熄灭（实测熄灭采样 %d 次 / 共 %d 次采样）" % [
			hidden_samples, int(DAMAGE_SECONDS / SAMPLE_INTERVAL)])

	# 2) 【2026-10-10 口径变更】停止掉血后，**残血期间血条必须一直显示**
	#    （旧口径是"停血 2 秒后自动隐藏"；用户要求残血常显 ⇒ 断言随之更新）
	var still_visible_after_window := true
	var waited := 0.0
	while waited < AUTO_HIDE_SECONDS + 2.0:
		await get_tree().create_timer(SAMPLE_INTERVAL).timeout
		waited += SAMPLE_INTERVAL
		if not bar.visible:
			still_visible_after_window = false
			break
	_check(tank.hp < tank.hp_max, "此阶段坦克应仍处于残血（hp=%s / %s）" % [tank.hp, tank.hp_max])
	_check(still_visible_after_window,
		"残血期间血条必须常显（停止掉血并等待 %.1f 秒后仍在显示）" % waited)
	if timer != null:
		_check(timer.is_stopped(), "残血常显期间自动隐藏计时器应处于停止状态")

	# 3) 修满后恢复"数值变化闪 2 秒再隐藏"的既有行为
	tank.set_hp_without_damage(int(tank.hp_max))
	var hid_after_full := false
	waited = 0.0
	while waited < AUTO_HIDE_SECONDS + 2.0:
		await get_tree().create_timer(SAMPLE_INTERVAL).timeout
		waited += SAMPLE_INTERVAL
		if not bar.visible:
			hid_after_full = true
			break
	_check(hid_after_full, "修满后 %.1f 秒内血条应自动隐藏（保留 2 秒窗口）" % (AUTO_HIDE_SECONDS + 2.0))

	# 4) 选中常显；残血时取消选中继续常显；满血取消选中才隐藏
	var selection = tank.find_child("Selection", true, false)
	if selection == null:
		_fail("Tank 上未找到 Selection")
	else:
		selection.select()
		_check(bar.visible, "选中单位后血条应立即显示")
		await get_tree().create_timer(AUTO_HIDE_SECONDS + 1.0).timeout
		_check(bar.visible, "选中期间血条不得自动隐藏（等待 %.1f 秒后仍在显示）" % (AUTO_HIDE_SECONDS + 1.0))
		if timer != null:
			_check(timer.is_stopped(), "选中期间自动隐藏计时器应处于停止状态")
		# 打掉 25% 血后取消选中：残血 ⇒ 必须继续显示（2026-10-10 新口径）
		tank.set_hp_without_damage(maxi(1, int(float(tank.hp_max) * 0.75)))
		selection.deselect()
		_check(bar.visible, "取消选中后若仍残血，血条必须继续显示")
		await get_tree().create_timer(AUTO_HIDE_SECONDS + 1.0).timeout
		_check(bar.visible,
			"残血期间取消选中后 %.1f 秒仍在显示" % (AUTO_HIDE_SECONDS + 1.0))
		# 修满后应隐藏
		tank.set_hp_without_damage(int(tank.hp_max))
		await get_tree().create_timer(AUTO_HIDE_SECONDS + 0.5).timeout
		_check(not bar.visible, "修满后取消选中，血条应在窗口结束后隐藏")

	# 5) 满血时血量不变不得无谓点亮
	tank.hp = tank.hp  # 触发 setter → hp_changed，但数值未变
	await get_tree().create_timer(SAMPLE_INTERVAL).timeout
	_check(not bar.visible, "血量未变化时血条不应被点亮")

	_finish()


func _check(condition: bool, message: String):
	if condition:
		print("  ok: %s" % message)
		return
	_fail(message)


func _fail(message: String):
	_failures += 1
	print("FAIL: %s" % message)
	push_error("Health bar flicker assertion failed: %s" % message)


func _finish():
	print("Health bar flicker smoke test completed: %d failure(s)" % _failures)
	SmokeTestExit.request(get_tree(), 0 if _failures == 0 else 1, _match)
