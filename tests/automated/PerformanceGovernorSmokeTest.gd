extends Node

## 帧率治理冒烟测试（用户 2026-09-14："锁 60 帧 + 单位多自动降画质"）。
##
## **纯逻辑，不需要真帧**：直接驱动 `PerformanceGovernor.step()`（静态纯函数）。
## 为什么这样测：这套治理的判据全是**规则**（前馈门槛/迟滞/冷却/升档/降档效果验证），
## 真机上"单位多了画质有没有降"要跑好几分钟才看得出来；这里把规则当场钉死。
##
## 2026-09-14 二次定标（用户投诉"这么点单位就要低画质"）后新增的三条硬规矩：
## ① 前馈**只数自己的兵**（对手/电脑 AI 攒兵不算到玩家头上）；
## ② 升档**只看帧率稳不稳**（旧实现要求 CPU 帧时 < 8ms，这台机器实测 10.9ms → 永远升不回去）；
## ③ 降档必须**换来帧率**，换不来就把画质还回去（别为守帧白牺牲画面）。
##
## 注意：**不使用 `class_name`**（headless 不会注册全局类名，见 `SmokeTestWarmup` 的说明）。

const Governor = preload("res://source/PerformanceGovernor.gd")

var _failures := 0


func _ready():
	_test_unit_floor_table()
	_test_more_units_lowers_quality_immediately()
	_test_downgrade_needs_dwell()
	_test_cooldown_prevents_double_downgrade()
	_test_upgrade_is_conservative_and_respects_floor()
	_test_upgrade_does_not_need_cpu_headroom()
	_test_downgrade_must_pay_off()
	_test_own_units_only()
	_test_warmup_ignores_startup_stutter()
	_test_player_visible_feedback()
	print("Performance governor smoke test completed: %d failure(s)" % _failures)
	SmokeTestExit.request(get_tree(), 0 if _failures == 0 else 1)


func _test_unit_floor_table():
	# 口径（2026-09-14 真机复检）：**只数自己的兵** —— 之前数全图，
	# 对面（电脑 AI）攒兵也会让玩家掉画质，玩家看着"这么点兵"却已经在低画质。
	_check(Governor.tier_floor_for_units(10) == 0, "小规模部队不该降画质")
	_check(Governor.tier_floor_for_units(49) == 0, "不到 50 个自己的兵不该降画质")
	_check(Governor.tier_floor_for_units(50) == 1, "50 个自己的兵起降到 1 档")
	_check(Governor.tier_floor_for_units(80) == 2, "80 个起降到 2 档")
	_check(Governor.tier_floor_for_units(120) == 3, "大规模部队降到最低档")


func _test_more_units_lowers_quality_immediately():
	# 用户点名的行为：**单位多就降低渲染效果**（前馈，不等 FPS 掉）。
	var core := {"tier": 1, "low_seconds": 0.0, "high_seconds": 0.0, "cooldown": 0.0}
	var result := Governor.step(core, {"fps": 60.0, "cpu_ms": 3.0, "draw_calls": 100,
		"units": 120, "delta": 0.25})
	_check(int(result["tier"]) == 3, "单位数到规模就该立刻降档（不等掉帧）")
	_check(bool(result["changed"]), "降档要标记 changed（调用方据此应用画质）")
	# 兵少了 → 允许反馈把画质升回去（退到门槛之上才算数）。
	var back := Governor.step({"tier": 3, "low_seconds": 0.0, "high_seconds": 0.0,
		"cooldown": 0.0}, {"fps": 60.0, "cpu_ms": 3.0, "draw_calls": 100, "units": 5,
		"delta": 0.25})
	_check(int(back["tier"]) == 3, "部队撤了不会**立刻**升档（要先观察够久，防抖）")


func _test_downgrade_needs_dwell():
	# 门槛改成 **低于 50 帧** 才算"真卡"：锁 60 时 57 帧只是 5% 抖动，不该拿它降画质。
	var core := {"tier": 0, "low_seconds": 0.0, "high_seconds": 0.0, "cooldown": 0.0}
	var sample := {"fps": 45.0, "cpu_ms": 12.0, "draw_calls": 900, "units": 10, "delta": 1.0}
	core = Governor.step(core, sample)
	_check(int(core["tier"]) == 0, "掉帧 1 秒还不该降档（迟滞）")
	core = Governor.step(core, sample)      # 累计 2.0s
	_check(int(core["tier"]) == 0, "还没到 DWELL（2.5s）不许降")
	core = Governor.step(core, sample)      # 累计 3.0s
	_check(int(core["tier"]) == 1, "持续掉帧超过 DWELL 就该降一档")
	# 帧率回到 60 且余量充足时的降档计时要被清掉（避免"抖一次就降两档"）
	core = Governor.step(core, {"fps": 60.0, "cpu_ms": 3.0, "draw_calls": 100,
		"units": 10, "delta": 0.25})
	_check(float(core["low_seconds"]) == 0.0, "帧率恢复后低帧计时必须清零")
	# 【用户投诉的那一次】60 帧附近的小抖动不该降画质
	var jitter := {"tier": 0, "low_seconds": 0.0, "high_seconds": 0.0, "cooldown": 0.0}
	var mid := {"fps": 57.0, "cpu_ms": 10.9, "draw_calls": 220, "units": 30, "delta": 1.0}
	for _index in range(10):
		jitter = Governor.step(jitter, mid)
	_check(int(jitter["tier"]) == 0, "57 帧不算掉帧（旧门槛 57 会在这里降档，正是被投诉的那次）")


func _test_cooldown_prevents_double_downgrade():
	var core := {"tier": 0, "low_seconds": 0.0, "high_seconds": 0.0, "cooldown": 0.0}
	var sample := {"fps": 30.0, "cpu_ms": 20.0, "draw_calls": 2000, "units": 10, "delta": 1.0}
	for _index in range(3):
		core = Governor.step(core, sample)
	_check(int(core["tier"]) == 1, "第一次降档")
	var second := Governor.step(core, sample)
	_check(int(second["tier"]) == 1, "冷却期内不许再降（画质不能『连跳两档』）")
	# 冷却走完、验证窗口也过去、仍守不住 → 才允许继续降
	second["cooldown"] = 0.0
	second["verify_left"] = 0.0
	second["low_seconds"] = 3.0
	var third := Governor.step(second, sample)
	_check(int(third["tier"]) == 2, "冷却结束且仍守不住 → 继续降到 2 档")


func _test_upgrade_does_not_need_cpu_headroom():
	# 【用户 2026-09-14 截图："60 FPS 却停在低画质"的回归用例】
	# 现场实测：60 帧时主线程帧时 10.9ms、绘制调用 220。旧实现要求 `cpu_ms < 8` 才升档
	# → 门槛永远不满足 → **档位只降不升**。升档只该看"帧率稳不稳"。
	var core := {"tier": 2, "low_seconds": 0.0, "high_seconds": 0.0, "cooldown": 0.0}
	var real := {"fps": 60.0, "cpu_ms": 10.9, "draw_calls": 220, "units": 25, "delta": 1.0}
	for _index in range(7):
		core = Governor.step(core, real)
	_check(int(core["tier"]) == 1, "帧率稳在 60 就该逐级升回去（不许被 CPU 帧时门槛卡死）")


func _test_downgrade_must_pay_off():
	# 【真机复检】这台机器是**主线程/逻辑**瓶颈：降画质换不来帧率 → 白降。
	# 所以降完要盯着看：帧率没回来就把画质还回去，并记住"别再白降"。
	var core := {"tier": 1, "low_seconds": 0.0, "high_seconds": 0.0, "cooldown": 0.0}
	var bad := {"fps": 45.0, "cpu_ms": 12.0, "draw_calls": 300, "units": 10, "delta": 1.0}
	core = Governor.step(core, bad)
	core = Governor.step(core, bad)
	core = Governor.step(core, bad)
	_check(int(core["tier"]) == 2, "持续低帧 → 先降一档试用")
	_check(float(core["verify_left"]) > 0.0, "降档后要进入效果验证窗口")
	for _index in range(9):                      # 窗口内帧率一直没回来
		core = Governor.step(core, bad)
	_check(int(core["tier"]) == 1, "降了没用（帧率没回来）→ 把画质还回去")
	_check(str(core["reason"]) == "no_effect", "还回去的原因要记成 no_effect（复盘要能查）")
	_check(float(core["no_effect_left"]) > 0.0, "白降一次就记住：一段时间内不再自动降档")
	for _index in range(20):                     # 记忆期内持续低帧也不再折腾画面
		core = Governor.step(core, bad)
	_check(int(core["tier"]) == 1, "白降记忆期内不许再降档")

	# 降了**有效**（帧率回来了）→ 保留这一档；且不许立刻又升回去（否则画面来回跳）
	var worked := {"tier": 1, "low_seconds": 0.0, "high_seconds": 0.0, "cooldown": 0.0}
	worked = Governor.step(worked, bad)
	worked = Governor.step(worked, bad)
	worked = Governor.step(worked, bad)
	_check(int(worked["tier"]) == 2, "先降档")
	var good := {"fps": 60.0, "cpu_ms": 4.0, "draw_calls": 200, "units": 10, "delta": 0.5}
	worked = Governor.step(worked, good)
	_check(float(worked["verify_left"]) == 0.0, "帧率回来了 → 验证通过")
	_check(int(worked["tier"]) == 2, "验证通过就保留这一档（不许马上又升回去抖画面）")


func _test_own_units_only():
	# 【口径回归】前馈只认**自己的兵**：`units` 组里还有对手/电脑 AI 的单位，
	# 真机上 41 个单位里一大半是敌人的，旧口径照样触发降档。
	var governor := get_node_or_null("/root/PerformanceGovernor")
	_check(governor != null, "治理器必须是 autoload（DCS 与右上角状态行都要读它）")
	if governor == null:
		return
	var base_all := get_tree().get_nodes_in_group("units").size()
	var base_own := get_tree().get_nodes_in_group("controlled_units").size()
	for index in range(3):
		var enemy := Node.new()
		enemy.name = "FakeEnemy%d" % index
		add_child(enemy)
		enemy.add_to_group("units")             # 对手：只在 `units` 组
	for index in range(1):
		var own := Node.new()
		own.name = "FakeOwn%d" % index
		add_child(own)
		own.add_to_group("units")
		own.add_to_group("controlled_units")    # 自己的兵：两组都在
	governor.call("_process", 0.016)
	var stats: Dictionary = governor.call("stats")
	_check(int(stats.get("units_all", -1)) == base_all + 4, "全图单位数要如实统计（复盘要能分开看）")
	_check(int(stats.get("units_own", -1)) == base_own + 1, "自己的单位数要单独统计")
	_check(int(stats.get("units", -1)) == base_own + 1, "前馈口径必须只数自己的兵（对手的不算）")
	_check(int(stats.get("floor", -1)) == 0, "1 个自己的兵不该触发降档")


func _test_upgrade_is_conservative_and_respects_floor():
	var good := {"fps": 60.0, "cpu_ms": 4.0, "draw_calls": 200, "units": 5, "delta": 1.0}
	var core := {"tier": 3, "low_seconds": 0.0, "high_seconds": 0.0, "cooldown": 0.0}
	core = Governor.step(core, good)
	_check(int(core["tier"]) == 3, "富余 1 秒还不升（升档要比降档保守得多）")
	for _index in range(6):
		core = Governor.step(core, good)
	_check(int(core["tier"]) == 2, "长时间富余才升一档")
	# 部队规模把门槛抬起来后，**不许**升回门槛之上
	var busy := {"fps": 60.0, "cpu_ms": 4.0, "draw_calls": 200, "units": 80, "delta": 1.0}
	var pinned := {"tier": 2, "low_seconds": 0.0, "high_seconds": 0.0, "cooldown": 0.0}
	for _index in range(20):
		pinned = Governor.step(pinned, busy)
	_check(int(pinned["tier"]) == 2, "部队规模还大时不许把画质升回去（前馈是硬门槛）")


func _test_warmup_ignores_startup_stutter():
	# 【真机复验发现】开局加载期帧率极低（实测 units=0, fps=32）→ 拿它降画质会"开局白降两档"。
	var core := {"tier": 0, "low_seconds": 0.0, "high_seconds": 0.0, "cooldown": 0.0}
	var busy := {"fps": 30.0, "cpu_ms": 25.0, "draw_calls": 1500, "units": 0,
		"delta": 1.0, "warmup": true}
	for _index in range(10):
		core = Governor.step(core, busy)
	_check(int(core["tier"]) == 0, "预热期内低帧不该降档（加载不是负载）")
	_check(float(core["low_seconds"]) == 0.0, "预热期不该累积低帧计时")
	# 预热期内**前馈照旧生效**（部队规模是硬事实，与是否在加载无关）
	var crowded := {"fps": 30.0, "cpu_ms": 25.0, "draw_calls": 1500, "units": 120,
		"delta": 1.0, "warmup": true}
	var pushed := Governor.step(core, crowded)
	_check(int(pushed["tier"]) == 3, "预热期也必须认部队规模（前馈不能被预热屏蔽）")
	# 预热结束后同样的低帧才开始降档（要跨过 DWELL=2.5s）
	var after := Governor.step({"tier": 0, "low_seconds": 0.0, "high_seconds": 0.0,
		"cooldown": 0.0}, {"fps": 30.0, "cpu_ms": 25.0, "draw_calls": 1500, "units": 0,
		"delta": 3.0, "warmup": false})
	_check(int(after["tier"]) == 1, "预热结束后低帧照旧降档")


func _test_player_visible_feedback():
	# 【用户 2026-09-14："玩家需要看到反馈，要不然不知道一些功能是怎么回事"】
	# 画面是被**自动**改的 —— 屏幕上必须有中文说明，且换档要讲清方向与原因。
	# 常驻信息**接在游戏原有右上角状态行**后面（用户："不要，游戏原来就有延时+帧率"）。
	_check(Governor.quality_suffix({"enabled": true, "tier": 1, "scale": 0.9})
		== "画质 高（90%）", "画质档要用中文接在原有状态行后")
	_check(Governor.quality_suffix({"enabled": false, "tier": 0, "scale": 1.0}) == "",
		"治理关掉时不该显示画质（没有自动画质这回事）")
	_check("载入中" in Governor.quality_suffix({"enabled": true, "tier": 0, "scale": 1.0,
		"warmup": true}), "载入期要说明（压测实测：加入对局后第 13 秒还有一次 509ms 卡顿）")
	_check("部队 78 个" in Governor.change_text(2, {"reason": "units=78"}, 1),
		"因部队规模降档 → 提示要说清'部队 78 个'")
	_check("帧率掉到 42" in Governor.change_text(2, {"reason": "fps=42"}, 1),
		"因掉帧降档 → 提示要说清掉到多少")
	_check("升回" in Governor.change_text(1, {"reason": "headroom"}, 2),
		"升档也要有提示（玩家要知道画面变好是功能在起作用）")
	_check("降画质没能换来帧率" in Governor.change_text(1, {"reason": "no_effect"}, 2),
		"因为'降了没用'把画质还回去时也要说明原因")


func _check(condition: bool, message: String):
	if condition:
		return
	_failures += 1
	push_error("Performance governor assertion failed: %s" % message)
