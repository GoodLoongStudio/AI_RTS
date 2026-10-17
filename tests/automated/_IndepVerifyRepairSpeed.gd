extends Node

## 独立复核探针（Verifier 席，临时文件，下划线前缀）。
##
## 刻意的**方法与申报方不同**：
##   · A（建筑维修）不读 `_repair_debt` / 不读 `_flight_seconds` / 不读场景 metadata，
##     只用 `Time.get_ticks_msec()` 墙钟在**真实 Match** 里采样 `unit.hp` 与
##     `player.resource_a`（C# 权威账户的只读镜像）随时间的斜率；
##   · B（重坦弹速）不读 `metadata/flight_speed_mps`、不读 `_flight_seconds`/`_aim_point`，
##     只在真实对局里按墙钟采样弹体自身的 `global_position`，用三种互相独立的算法反推速度。
##
## 场景：res://tests/automated/_IndepVerifyRepairSpeed.tscn
## 用法（**同一时刻只跑一个 Godot 进程**）：
##   godot --headless --path <repo> res://tests/automated/_IndepVerifyRepairSpeed.tscn -- --phase=rate
##   ... --phase=rate --fps=30        # 帧率无关性：把 Engine.max_fps 夹到 30
##   ... --phase=rate --fps=144
##   ... --phase=edges
##   ... --phase=shell
## 参数：--phase=rate|edges|shell   --fps=<int>（0=不限）   --window=<秒，默认 10>

const MatchSettings = preload("res://source/data-model/MatchSettings.gd")
const PlayerSettings = preload("res://source/data-model/PlayerSettings.gd")
const SmokeTestExit = preload("res://tests/automated/SmokeTestExit.gd")
const HeavyTankScene = preload("res://source/match/units/HeavyTank.tscn")
const TankScene = preload("res://source/match/units/Tank.tscn")

## 口径常量（只用于**比对**，不作为测量来源）。
const CLAIM_RATE := 6.0
const CLAIM_COST := 0.25
const HEAVY_SHELL_SCENE := "res://source/match/units/projectiles/HeavyCannonShell.tscn"
const TANK_SHELL_SCENE := "res://source/match/units/projectiles/CannonShell.tscn"
const EXPLOSION_SCENE := "res://source/match/units/projectiles/ShellExplosion.tscn"

var _failures := 0
var _match: Node = null


# ---------------------------------------------------------------- 基础设施

func _arg(name: String, fallback: String) -> String:
	for raw in OS.get_cmdline_user_args():
		if raw.begins_with("--%s=" % name):
			return raw.substr(name.length() + 3)
	return fallback


func _report(ok: bool, msg: String) -> void:
	if ok:
		print("[PASS] %s" % msg)
	else:
		_failures += 1
		print("[FAIL] %s" % msg)


func _info(msg: String) -> void:
	print("[INFO] %s" % msg)


## 真实对局：Match.tscn + PlainAndSimple + 人类/AI 各一名（与既有回归同一条出场路径）。
func _build_match(controllers: Array) -> Node:
	var settings = MatchSettings.new()
	for i in controllers.size():
		var ps = PlayerSettings.new()
		ps.controller = controllers[i]
		ps.color = Color.BLUE if i == 0 else Color.RED
		settings.players.append(ps)
	settings.visible_player = 0
	settings.visibility = MatchSettings.Visibility.PER_PLAYER
	var m = load("res://source/match/Match.tscn").instantiate()
	m.settings = settings
	m.map = load("res://source/match/maps/PlainAndSimple.tscn").instantiate()
	get_tree().root.add_child(m)
	_match = m
	return m


func _await_match_ready(m: Node, expected_players: int) -> bool:
	var deadline := Time.get_ticks_msec() + 90000
	while Time.get_ticks_msec() < deadline:
		await get_tree().physics_frame
		var players: Node = m.get_node_or_null("Players")
		if players == null or players.get_child_count() < expected_players:
			continue
		var ok := true
		for p in players.get_children():
			if p.get_child_count() == 0:
				ok = false
		if ok:
			return true
	return false


## 对局里真实生成的、可维修的建筑（唯一判据是"有 set_repairing/is_repairing"）。
func _find_repairable(player: Node) -> Node:
	for child in player.get_children():
		if child.has_method("set_repairing") and child.has_method("is_repairing") \
				and "hp" in child and child.hp_max != null:
			return child
	return null


# ---------------------------------------------------------------- 采样

## 墙钟采样受损建筑的 hp / 资金。
##
## 建筑 hp_max 只有 80，10s×6HP/s 会撞满血导致窗口被截断 ⇒ 这里加一道**安全注水**：
## 仅当 hp 逼近满血时才人工扣掉一截血（`set_hp_without_damage`，非伤害源），
## 并把每次注水量精确记账。正常速率下（hp 从 1 起步、窗口 ≤8s）**一次都不会触发**。
func _sample_repair(cc: Node, human: Node, window_seconds: float) -> Dictionary:
	var hp_max := float(cc.hp_max)
	var inject_threshold := hp_max - 1.0
	var inject_amount := hp_max * 0.35
	var samples: Array = []   # [t_ms, hp, money, 本帧注水量]
	var t0 := Time.get_ticks_msec()
	samples.append([0, float(cc.hp), int(human.resource_a), 0.0])
	var window_ms := int(window_seconds * 1000.0)
	while Time.get_ticks_msec() - t0 < window_ms:
		await get_tree().process_frame
		var injected := 0.0
		if float(cc.hp) > inject_threshold:
			injected = inject_amount
			cc.set_hp_without_damage(float(cc.hp) - injected)
		samples.append([Time.get_ticks_msec() - t0, float(cc.hp), int(human.resource_a), injected])
	return _analyze_repair(samples, hp_max)


func _analyze_repair(samples: Array, hp_max: float) -> Dictionary:
	var n := samples.size()
	var first: Array = samples[0]
	var last: Array = samples[n - 1]
	var elapsed := float(last[0] - first[0]) / 1000.0
	var injected_total := 0.0
	var at_cap_frames := 0
	for s in samples:
		injected_total += float(s[3])
		if is_equal_approx(float(s[1]), hp_max):
			at_cap_frames += 1
	var hp_gain := float(last[1]) - float(first[1]) + injected_total
	var spent := int(first[2]) - int(last[2])
	var rate := hp_gain / elapsed if elapsed > 0.0 else -1.0
	var cost := float(spent) / hp_gain if hp_gain > 0.0 else -1.0
	# 逐帧账本：出现扣款的那一帧，回血(+本帧注水)必须正好是 Δmoney × 4。
	var ledger_bad := 0
	var ledger_pairs := 0
	var clamp_frames := 0
	var damage_frames := 0
	for i in range(1, n):
		var dm := float(samples[i - 1][2] - samples[i][2])
		var dh := float(samples[i][1]) - float(samples[i - 1][1]) + float(samples[i][3])
		if dm > 0.0:
			# "撞满血而少给"是唯一合法的少给：结算前 hp + 应得(4×dm) 必须已经够到 hp_max。
			var legit_clamp := float(samples[i - 1][1]) + 4.0 * dm >= hp_max - 0.0001
			if legit_clamp:
				clamp_frames += 1
			else:
				ledger_pairs += 1
				if absf(dh - 4.0 * dm) > 0.0001:
					ledger_bad += 1
		if float(samples[i][1]) < float(samples[i - 1][1]) - float(samples[i][3]) - 0.0001:
			damage_frames += 1
	# 纯段：两次注水之间、且没有撞满血的连续区间，取最长的一段做 hp–时间线性回归。
	var best_len := 0
	var best_slope := 0.0
	var best_span := 0.0
	var start_i := 0
	for i in range(1, n + 1):
		var boundary := i == n or float(samples[i][3]) > 0.0
		if boundary:
			var len_i := i - start_i
			if len_i > best_len and len_i >= 3:
				var mean_t := 0.0
				var mean_h := 0.0
				for j in range(start_i, i):
					mean_t += float(samples[j][0]) / 1000.0
					mean_h += float(samples[j][1])
				mean_t /= float(len_i)
				mean_h /= float(len_i)
				var stt := 0.0
				var sht := 0.0
				for j in range(start_i, i):
					var dt := float(samples[j][0]) / 1000.0 - mean_t
					stt += dt * dt
					sht += dt * (float(samples[j][1]) - mean_h)
				best_len = len_i
				best_slope = sht / stt
				best_span = float(samples[i - 1][0] - samples[start_i][0]) / 1000.0
			start_i = i
	return {
		"samples": n, "elapsed": elapsed, "hp_gain": hp_gain, "spent": spent,
		"rate": rate, "cost": cost, "ledger_bad": ledger_bad, "ledger_pairs": ledger_pairs,
		"clamp_frames": clamp_frames, "damage_frames": damage_frames,
		"injected_total": injected_total, "pure_slope": best_slope, "pure_span": best_span,
		"pure_frames": best_len, "at_cap_frames": at_cap_frames,
		"hp_first": float(first[1]), "hp_last": float(last[1]),
		"money_first": int(first[2]), "money_last": int(last[2]),
		"fps": float(n) / elapsed if elapsed > 0.0 else -1.0,
	}


# ---------------------------------------------------------------- phase: rate

func _phase_rate(window_seconds: float) -> void:
	var m := _build_match([Constants.PlayerType.HUMAN, Constants.PlayerType.SIMPLE_CLAIRVOYANT_AI])
	_info("phase=rate 建局（HUMAN vs AI，AI 被动）…")
	var ready := await _await_match_ready(m, 2)
	_report(ready, "真实对局应就绪（Players 下每个玩家都有单位）")
	if not ready:
		return

	var human: Node = m.get_node("Players").get_child(0)
	human.add_resources({"resource_a": 1000000}, "ScriptedAdjustment")
	var cc := _find_repairable(human)
	_report(cc != null, "人类玩家名下应有真实生成的建筑（指挥中心）")
	if cc == null:
		return
	_info("建筑=%s hp_max=%s" % [cc.name, str(cc.hp_max)])

	# 打到 1 HP：hp_max 只有 80，从 1 起步才有 ≥13s 的满血余量，8s 窗口绝不可能被截断。
	cc.set_hp_without_damage(1.0)
	cc.set_repairing(true)
	_report(cc.is_repairing(), "维修应已开启")

	# 预热：让第一次"攒够 1 金"的结算发生在窗口之前。
	var warm := 0.0
	var warm_start := Time.get_ticks_msec()
	while Time.get_ticks_msec() - warm_start < 2500:
		await get_tree().process_frame
		warm += get_process_delta_time()
	_report(cc.is_repairing(), "预热后维修应仍在进行（hp=%.2f/%.2f）" % [cc.hp, cc.hp_max])
	if not cc.is_repairing():
		return

	var res := await _sample_repair(cc, human, window_seconds)
	cc.set_repairing(false)
	_info("墙钟窗口 %.3fs（%d 帧，实测 %.1f fps）；预热 %.2fs" % [
		res["elapsed"], res["samples"], res["fps"], warm])
	_info("hp %.2f → %.2f（+%.2f，其中探针注水 %.2f）；资金 %d → %d（花 %d）" % [
		res["hp_first"], res["hp_last"], res["hp_gain"], res["injected_total"],
		res["money_first"], res["money_last"], res["spent"]])
	_info("实测 HP/s = %.4f（申报口径 %.1f，比值 %.4f）" % [
		res["rate"], CLAIM_RATE, res["rate"] / CLAIM_RATE])
	_info("最长无注水纯段：%.3fs / %d 帧，hp 斜率 = %.4f HP/s" % [
		res["pure_span"], res["pure_frames"], res["pure_slope"]])
	_info("实测 金/HP = %.4f（申报口径 %.2f，比值 %.4f）" % [
		res["cost"], CLAIM_COST, res["cost"] / CLAIM_COST])
	_info("逐帧账本：%d 次扣款，Δhp≠4×Δmoney 的异常帧 = %d（撞满血折扣帧 = %d）；hp 下降帧 = %d；顶满血帧 = %d" % [
		res["ledger_pairs"], res["ledger_bad"], res["clamp_frames"], res["damage_frames"],
		res["at_cap_frames"]])

	_report(res["damage_frames"] == 0, "计量窗口内建筑不应受到伤害（采样到 %d 个掉血帧）" % res["damage_frames"])
	_info("探针安全注水量 = %.2f（0 = 窗口全程未逼近满血；>0 时以最长纯段为准）" % res["injected_total"])
	_report(res["at_cap_frames"] == 0, "窗口内不应出现顶到 hp_max 的帧（实际 %d 帧）" % res["at_cap_frames"])
	_report(res["hp_gain"] > 0.0, "维修应回血（实际 +%.3f）" % res["hp_gain"])
	_report(
		absf(res["rate"] - CLAIM_RATE) <= CLAIM_RATE * 0.10,
		"实测 HP/s 应落在申报口径 ±10%%（实际 %.4f，容许 5.4–6.6）" % res["rate"])
	_report(
		absf(res["pure_slope"] - CLAIM_RATE) <= CLAIM_RATE * 0.10,
		"最长纯段 hp 斜率应落在申报口径 ±10%%（实际 %.4f）" % res["pure_slope"])
	_report(
		absf(res["cost"] - CLAIM_COST) <= CLAIM_COST * 0.10,
		"实测 金/HP 应落在申报口径 ±10%%（实际 %.4f，容许 0.225–0.275）" % res["cost"])
	_report(res["ledger_bad"] == 0, "账本恒等：每一次扣款都必须换来 4×Δmoney 的 HP（异常 %d 帧）" % res["ledger_bad"])


# ---------------------------------------------------------------- phase: edges

func _phase_edges() -> void:
	var m := _build_match([Constants.PlayerType.HUMAN, Constants.PlayerType.SIMPLE_CLAIRVOYANT_AI])
	var ready := await _await_match_ready(m, 2)
	_report(ready, "真实对局应就绪")
	if not ready:
		return
	var human: Node = m.get_node("Players").get_child(0)
	var cc := _find_repairable(human)
	_report(cc != null, "应有可维修建筑")
	if cc == null:
		return
	var hp_max := float(cc.hp_max)
	_info("建筑=%s hp_max=%.1f" % [cc.name, hp_max])

	# ---- 边界 1：资金耗尽自动停止 ----
	print("---- 边界1：资金耗尽 ----")
	# 从 1 HP 起步 + 只给 10 金(=40HP)，远小于 79 的满血余量 ⇒ 必然是"钱先耗尽"而不是"先满血"。
	cc.set_hp_without_damage(1.0)
	var cur := int(human.resource_a)
	if cur > 10:
		human.subtract_resources({"resource_a": cur - 10}, "ScriptedAdjustment")
	if cur < 10:
		human.add_resources({"resource_a": 10 - cur}, "ScriptedAdjustment")
	_report(int(human.resource_a) == 10, "起始余额应精确为 10（实际 %d）" % int(human.resource_a))
	var hp0 := float(cc.hp)
	var money0 := int(human.resource_a)
	cc.set_repairing(true)
	var t_start := Time.get_ticks_msec()
	var deadline := t_start + 45000
	while cc.is_repairing() and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	var stop_seconds := float(Time.get_ticks_msec() - t_start) / 1000.0
	var hp1 := float(cc.hp)
	var money1 := int(human.resource_a)
	var spent1 := money0 - money1
	_info("10 金在 %.2fs 内用尽；hp %.2f → %.2f（+%.2f）；余额 %d → %d（花 %d）" % [
		stop_seconds, hp0, hp1, hp1 - hp0, money0, money1, spent1])
	_report(not cc.is_repairing(), "资金耗尽后应自动停止维修（is_repairing() 仍为真即失败）")
	_report(money1 >= 0, "余额不应为负（实际 %d）" % money1)
	_report(money1 < 1, "余额应不足以再结算 1 金（实际 %d）" % money1)
	_report(hp1 < hp_max - 0.5, "本轮必须因资金耗尽而停，不得先撞满血（hp=%.2f/%.2f）" % [hp1, hp_max])
	var expected_gain := 4.0 * float(spent1)
	_report(
		absf((hp1 - hp0) - expected_gain) <= 0.0001,
		"账本恒等：Δhp(%.3f) 必须 = 4×Δmoney(%d)=%.3f" % [hp1 - hp0, spent1, expected_gain])
	# 停止后静默
	var hp_a := float(cc.hp)
	var money_a := int(human.resource_a)
	var quiet := Time.get_ticks_msec() + 2500
	while Time.get_ticks_msec() < quiet:
		await get_tree().process_frame
	_report(
		absf(float(cc.hp) - hp_a) <= 0.0001 and int(human.resource_a) == money_a,
		"停止后 2.5s 内不得再回血/扣款（hp %.3f→%.3f，资金 %d→%d）" % [
			hp_a, float(cc.hp), money_a, int(human.resource_a)])

	# ---- 边界 2：满血自动停止 ----
	print("---- 边界2：满血 ----")
	human.add_resources({"resource_a": 200}, "ScriptedAdjustment")
	cc.set_hp_without_damage(hp_max - 5.0)
	var hp_full0 := float(cc.hp)
	var money_before_full := int(human.resource_a)
	cc.set_repairing(true)
	var t2 := Time.get_ticks_msec()
	while cc.is_repairing() and Time.get_ticks_msec() - t2 < 20000:
		await get_tree().process_frame
	var fill_seconds := float(Time.get_ticks_msec() - t2) / 1000.0
	var money_at_full := int(human.resource_a)
	_info("从 %.2f 补到 %.2f 用 %.2fs；资金 %d → %d" % [
		hp_full0, float(cc.hp), fill_seconds, money_before_full, money_at_full])
	_report(is_equal_approx(float(cc.hp), hp_max), "应恰好在满血停住（hp=%.4f / %.1f）" % [float(cc.hp), hp_max])
	_report(not cc.is_repairing(), "满血后应自动停止维修")
	var hp_b := float(cc.hp)
	var money_b := int(human.resource_a)
	var quiet2 := Time.get_ticks_msec() + 2500
	while Time.get_ticks_msec() < quiet2:
		await get_tree().process_frame
	_report(
		absf(float(cc.hp) - hp_b) <= 0.0001 and int(human.resource_a) == money_b,
		"满血停止后 2.5s 内不得再扣款（资金 %d→%d，hp %.3f→%.3f）" % [
			money_b, int(human.resource_a), hp_b, float(cc.hp)])

	# ---- 边界 3：傀儡端只表现 ----
	print("---- 边界3：联机傀儡端 ----")
	cc.set_hp_without_damage(hp_max * 0.5)
	human.add_resources({"resource_a": 500}, "ScriptedAdjustment")
	var hp_p0 := float(cc.hp)
	var money_p0 := int(human.resource_a)
	# 客户端从快照收到的唯一入口就是 present_repairing（NetSync.gd:506）。
	cc.present_repairing(true)
	var icon = cc.get_node_or_null("RepairStatusIcon")
	_report(icon != null and icon.visible, "present_repairing(true) 应产生可见的维修图标（表现层生效）")
	var pt := Time.get_ticks_msec() + 3000
	while Time.get_ticks_msec() < pt:
		await get_tree().process_frame
	_info("仅 present_repairing(true) 3s：hp %.3f→%.3f，资金 %d→%d，is_repairing=%s" % [
		hp_p0, float(cc.hp), money_p0, int(human.resource_a), str(cc.is_repairing())])
	_report(
		absf(float(cc.hp) - hp_p0) <= 0.0001,
		"只表现不得改本地 HP（%.4f → %.4f）" % [hp_p0, float(cc.hp)])
	_report(
		int(human.resource_a) == money_p0,
		"只表现不得扣本地资金（%d → %d）" % [money_p0, int(human.resource_a)])
	_report(not cc.is_repairing(), "present_repairing 不得置位本地 _repairing")

	# 真正把 is_client_puppet() 拉成 true（无服务端的 ENet 客户端 peer）。
	var puppet_ok := false
	var err := ""
	if ClassDB.class_exists("ENetMultiplayerPeer"):
		var peer := ENetMultiplayerPeer.new()
		var ec := peer.create_client("127.0.0.1", 25999)
		if ec == OK:
			multiplayer.multiplayer_peer = peer
			NetSession._peer = peer
			puppet_ok = NetSession.is_client_puppet()
		else:
			err = "create_client rc=%d" % ec
	else:
		err = "无 ENetMultiplayerPeer"
	_info("傀儡态构造：is_client_puppet()=%s %s" % [str(NetSession.is_client_puppet()), err])
	_report(puppet_ok, "应能把 NetSession.is_client_puppet() 置为 true 以实测傀儡端")

	if puppet_ok:
		# (a) 走真实客户端入口
		cc.set_hp_without_damage(hp_max * 0.5)
		var hp_q0 := float(cc.hp)
		var money_q0 := int(human.resource_a)
		cc.present_repairing(true)
		var qt := Time.get_ticks_msec() + 3000
		while Time.get_ticks_msec() < qt:
			await get_tree().process_frame
		_info("傀儡态 + present_repairing 3s：hp %.3f→%.3f，资金 %d→%d" % [
			hp_q0, float(cc.hp), money_q0, int(human.resource_a)])
		_report(
			absf(float(cc.hp) - hp_q0) <= 0.0001 and int(human.resource_a) == money_q0,
			"傀儡端经真实客户端入口(NetSync→present_repairing)绝不本地回血/扣费")

		# (b) 防御纵深：**若**有人从客户端直接调 set_repairing，会发生什么。
		cc.set_hp_without_damage(hp_max * 0.5)
		var hp_r0 := float(cc.hp)
		var money_r0 := int(human.resource_a)
		cc.set_repairing(true)
		var rt := Time.get_ticks_msec() + 3000
		while Time.get_ticks_msec() < rt:
			await get_tree().process_frame
		var dh := float(cc.hp) - hp_r0
		var dm := money_r0 - int(human.resource_a)
		cc.set_repairing(false)
		_info("傀儡态 + 直接 set_repairing(true) 3s：hp %+.3f，资金 -%d（防御纵深探针）" % [dh, dm])
		_report(
			absf(dh) <= 0.0001 and dm == 0,
			"傀儡端**直接** set_repairing 也不应本地改状态（当前无 is_client_puppet 守卫；失败=防御纵深缺口，非线上缺陷）")

	# 复位，避免影响退出
	multiplayer.multiplayer_peer = null
	NetSession._peer = null


# ---------------------------------------------------------------- phase: shell

func _fire_and_time(shooter_scene: PackedScene, shell_path: String, spawn: Vector3,
		target: Vector3) -> Dictionary:
	var players: Node = _match.get_node("Players")
	var human: Node = players.get_child(0)
	var projectiles: Node = _match.get_node_or_null("Projectiles")
	if projectiles == null:
		return {"ok": false, "why": "无 Projectiles 容器"}
	var unit = shooter_scene.instantiate()
	_match._setup_and_spawn_unit(unit, Transform3D(Basis.IDENTITY, spawn), human, false)
	await get_tree().physics_frame
	await get_tree().physics_frame
	var accepted: bool = unit.request_legacy_ground_force_attack(target)
	var shell = null
	var deadline := Time.get_ticks_msec() + 25000
	while Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
		for child in projectiles.get_children():
			if str(child.scene_file_path) == shell_path:
				shell = child
				break
		if shell != null:
			break
	if shell == null:
		if is_instance_valid(unit):
			unit.queue_free()
		return {"ok": false, "why": "采样窗口内没观察到弹体", "accepted": accepted}
	# 逐帧墙钟采样弹体自己的 global_position（不读任何内部飞行参数）
	var samples: Array = []
	while is_instance_valid(shell) and not shell.is_queued_for_deletion():
		samples.append([Time.get_ticks_msec(), shell.global_position])
		await get_tree().process_frame
	# 落点：弹体自毁后由 ShellExplosion 的位置反推（场景把爆炸抬高了 1.2m）
	var explosion := Vector3.INF
	for _i in 40:
		await get_tree().process_frame
		for child in projectiles.get_children():
			if str(child.scene_file_path) == EXPLOSION_SCENE:
				explosion = child.global_position - Vector3(0.0, 1.2, 0.0)
				break
		if explosion.is_finite():
			break
	if is_instance_valid(unit):
		unit.queue_free()
	# 等容器清空，避免干扰下一次测量
	var drain := Time.get_ticks_msec() + 4000
	while Time.get_ticks_msec() < drain and projectiles.get_child_count() > 0:
		await get_tree().process_frame
	return {"ok": true, "accepted": accepted, "samples": samples, "explosion": explosion}


func _analyze_shell(res: Dictionary) -> Dictionary:
	var samples: Array = res["samples"]
	var n := samples.size()
	if n < 3:
		return {"n": n}
	var t0: int = samples[0][0]
	var first: Vector3 = samples[0][1]
	var last: Vector3 = samples[n - 1][1]
	var span := float(samples[n - 1][0] - t0) / 1000.0
	var chord3 := first.distance_to(last) / span
	var chord_h := Vector2(last.x - first.x, last.z - first.z).length() / span
	# 最小二乘线性回归：水平位移对时间是严格线性的（与 _flight_seconds 无关）
	var mean_t := 0.0
	var mean_x := 0.0
	var mean_z := 0.0
	for s in samples:
		mean_t += float(s[0] - t0) / 1000.0
		mean_x += s[1].x
		mean_z += s[1].z
	mean_t /= float(n)
	mean_x /= float(n)
	mean_z /= float(n)
	var sxx := 0.0
	var sxt := 0.0
	var szt := 0.0
	for s in samples:
		var dt := float(s[0] - t0) / 1000.0 - mean_t
		sxx += dt * dt
		sxt += dt * (s[1].x - mean_x)
		szt += dt * (s[1].z - mean_z)
	var v_fit := sqrt((sxt / sxx) * (sxt / sxx) + (szt / sxx) * (szt / sxx))
	var explosion: Vector3 = res.get("explosion", Vector3.INF)
	var to_explosion := -1.0
	if explosion.is_finite():
		to_explosion = first.distance_to(explosion) / span
	return {
		"n": n, "span": span, "first": first, "last": last,
		"chord3": chord3, "chord_h": chord_h, "fit": v_fit,
		"explosion": explosion, "to_explosion": to_explosion,
	}


func _phase_shell() -> void:
	var m := _build_match([Constants.PlayerType.HUMAN, Constants.PlayerType.SIMPLE_CLAIRVOYANT_AI])
	var ready := await _await_match_ready(m, 2)
	_report(ready, "真实对局应就绪")
	if not ready:
		return
	_info("phase=shell：在真实对局里按墙钟采样弹体 global_position")

	# 重坦（申报 15 m/s）
	var spawn := Vector3(40.0, 0.0, 40.0)
	var target := spawn + Vector3(18.0, 0.0, 0.0)
	var heavy_res := await _fire_and_time(HeavyTankScene, HEAVY_SHELL_SCENE, spawn, target)
	_report(heavy_res.get("ok", false), "应观察到重坦炮弹飞行（%s）" % str(heavy_res.get("why", "")))
	if heavy_res.get("ok", false):
		var a := _analyze_shell(heavy_res)
		_info("重坦炮弹：%d 帧 / 墙钟 %.3fs（%.0f fps）" % [a["n"], a["span"], float(a["n"]) / a["span"]])
		_info("  ① 首末两点 3D 弦速 = %.3f m/s（%s → %s）" % [a["chord3"], str(a["first"]), str(a["last"])])
		_info("  ② 首末两点水平弦速 = %.3f m/s" % a["chord_h"])
		_info("  ③ x/z 线性回归速度 = %.3f m/s" % a["fit"])
		_info("  落点(爆炸反推)=%s；①'（首点→落点） = %.3f m/s" % [str(a["explosion"]), a["to_explosion"]])
		for key in ["chord3", "chord_h", "fit"]:
			_report(
				absf(a[key] - 15.0) <= 15.0 * 0.08,
				"重坦弹速[%s] 应 ≈15 m/s（实际 %.3f，容许 ±8%%）" % [key, a[key]])

	# 对照：普通坦克炮弹。【2026-10-12 口径】除重坦外所有弹种弹速 ×2 ⇒ 12 → 24 m/s；
	# 重坦仍是 15 m/s（上面那条申报值不变），所以这里"对照组"与重坦的相对次序反过来了。
	var tank_res := await _fire_and_time(TankScene, TANK_SHELL_SCENE, Vector3(60.0, 0.0, 60.0),
		Vector3(60.0, 0.0, 60.0) + Vector3(18.0, 0.0, 0.0))
	_report(tank_res.get("ok", false), "应观察到坦克炮弹飞行（%s）" % str(tank_res.get("why", "")))
	if tank_res.get("ok", false):
		var b := _analyze_shell(tank_res)
		_info("坦克炮弹：%d 帧 / 墙钟 %.3fs；① %.3f ② %.3f ③ %.3f m/s" % [
			b["n"], b["span"], b["chord3"], b["chord_h"], b["fit"]])
		_report(
			absf(b["fit"] - 24.0) <= 24.0 * 0.08,
			"对照组坦克炮弹速度应 ≈24 m/s（实际 %.3f）" % b["fit"])


# ---------------------------------------------------------------- 入口

func _ready() -> void:
	await get_tree().process_frame
	var phase := _arg("phase", "rate")
	var fps := int(_arg("fps", "0"))
	var window_seconds := float(_arg("window", "10"))
	# AI 被动：消除"建筑被打"对维修斜率的干扰（这是 NetSession 上既有的测试开关）。
	NetSession.passive_ai_test = true
	if fps > 0:
		Engine.max_fps = fps
	print("[INFO] probe phase=%s fps_cap=%d window=%.1fs engine_max_fps=%d" % [
		phase, fps, window_seconds, Engine.max_fps])
	match phase:
		"rate":
			await _phase_rate(window_seconds)
		"edges":
			await _phase_edges()
		"shell":
			await _phase_shell()
		_:
			_failures += 1
			print("[FAIL] 未知 phase: %s" % phase)
	print("[RESULT] phase=%s failures=%d" % [phase, _failures])
	print("_IndepVerifyRepairSpeed done: %d failure(s)" % _failures)
	SmokeTestExit.request(get_tree(), 0 if _failures == 0 else 1, _match)
