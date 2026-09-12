extends Node

## 血条闪烁回归测试（2026-09-10）：
## 现象（用户报告）：血条“一闪一闪”。
## 根因：HealthBar.gd 的 _show_for_a_while() 在血条已可见时直接 return，
##       不会续期自动隐藏计时器 —— 于是首次伤害后 2 秒计时器到点熄灭，
##       下一次伤害又点亮，只要伤害间隔 < 2 秒就形成周期性闪烁。
##
## 断言：
##  1) 持续掉血期间（每 1 秒一次，短于 2 秒隐藏窗口）血条不得出现熄灭；
##  2) 停止掉血后约 2 秒才允许自动隐藏（保留原有行为）；
##  3) 选中期间必须常显（超过自动隐藏窗口也不熄灭），取消选中后隐藏；
##  4) 血量不变时不得无谓点亮（避免网络快照每帧赋值导致闪烁）。

const MatchScene = preload("res://tests/manual/TestAllUnits.tscn")

const DAMAGE_INTERVAL := 1.0
const DAMAGE_SECONDS := 6.0
const AUTO_HIDE_SECONDS := 2.0
const SAMPLE_INTERVAL := 0.1

var _failures := 0


func _ready():
	var match_instance = MatchScene.instantiate()
	add_child(match_instance)
	await get_tree().process_frame
	await get_tree().create_timer(0.5).timeout

	var human = match_instance.get_node("Players/Human")
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
			var damage := max(1, int(float(tank.hp_max) * 0.02))
			tank.hp = max(1, int(tank.hp) - damage)
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

	# 2) 停止掉血后应自动隐藏（保留原有 2 秒行为）
	var hid_after_damage := false
	var waited := 0.0
	while waited < AUTO_HIDE_SECONDS + 2.0:
		await get_tree().create_timer(SAMPLE_INTERVAL).timeout
		waited += SAMPLE_INTERVAL
		if not bar.visible:
			hid_after_damage = true
			break
	_check(hid_after_damage, "停止掉血后 %.1f 秒内血条应自动隐藏" % (AUTO_HIDE_SECONDS + 2.0))

	# 3) 选中期间常显
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
		selection.deselect()
		_check(not bar.visible, "取消选中后血条应隐藏")

	# 4) 血量不变时不得无谓点亮
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
	SmokeTestExit.request(get_tree(), 0 if _failures == 0 else 1)
