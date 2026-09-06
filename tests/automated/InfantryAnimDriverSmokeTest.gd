extends Node

## 验证原厂骨架步兵动画驱动：GLB 模型挂载、七段剪辑就绪、
## 待命/移动/受击状态映射正确播放，并确认 Fire 只由真实投射物发射触发。

const MatchScene = preload("res://tests/manual/TestAllUnits.tscn")
const InfantryScene = preload("res://source/match/units/Infantry.tscn")
const TankScene = preload("res://source/match/units/Tank.tscn")
const PlayerScript = preload("res://source/match/players/Player.gd")
const AnimDriver = preload("res://source/match/units/InfantryAnimationDriver.gd")

const ALL_CLIPS := ["Idle", "Run", "Hit", "HitHeavy", "Fire", "Crawl", "Death"]

var _failures := 0

## Fire 进入监视状态：_process 轮询实现，避免协程/闭包生命周期陷阱。
var _monitor_player_id := 0
var _monitor_events: Dictionary = {}
var _monitor_was_fire := false


func _process(_delta):
	if _monitor_player_id == 0:
		return
	var player_now := instance_from_id(_monitor_player_id) as AnimationPlayer
	if player_now == null:
		# 被监视单位已释放：停止监视，不访问已释放对象。
		_monitor_player_id = 0
		return
	var is_fire: bool = player_now.current_animation == "Fire"
	if is_fire and not _monitor_was_fire:
		_monitor_events.fire_entries.append(Time.get_ticks_msec())
	_monitor_was_fire = is_fire


func _ready():
	var match_instance = MatchScene.instantiate()
	add_child(match_instance)
	await get_tree().process_frame
	await get_tree().process_frame

	var human = match_instance.get_node("Players/Human")
	var gateway = human.get_node("UnitCommandGateway")
	# 先让基线场景停火，避免其他坦克/炮塔提前打死测试目标。
	# Match 的场景单位装载在导航等子系统异步就绪之后，必须等 units 分组
	# 真正 populated 再下发策略；空数组会让整条命令被 EmptyUnitSet 拒绝。
	var human_units := func(): return get_tree().get_nodes_in_group("units").filter(
		func(unit): return unit.get_parent() == human)
	_check(await _wait_until(func(): return human_units.call().size() >= 9, 15.0),
		"基线场景 9 个人类单位应在超时前全部加入 units 分组（实际 %d）" % human_units.call().size())
	var policy_result = gateway.SetFirePolicy(human_units.call(), "HoldFire", human)
	var policy_units = policy_result.get("unit_results", [])
	_check(policy_units.any(func(item): return item.get("accepted", false)),
		"基线场景停火策略应至少被一个单位接受（status=%s）" % policy_result.get("status"))
	_check(gateway.GetFirePolicy(match_instance.get_node("Players/Human/Tank")) == "HoldFire",
		"场景坦克应处于停火，避免击杀测试目标")
	var infantry = InfantryScene.instantiate()
	var spawn_transform := Transform3D(Basis(), human.global_position + Vector3(4, 0, 0))
	MatchSignals.setup_and_spawn_unit.emit(infantry, spawn_transform, human)
	await get_tree().create_timer(0.5).timeout

	_check(infantry.is_in_group("units"), "步兵应加入 units 分组")
	_check(infantry.find_child("SyntyMaterialBinder", true, false) == null,
		"GLB 自带材质，不应再有 SyntyMaterialBinder")
	var player: AnimationPlayer = infantry.find_child("AnimationPlayer", true, false)
	_check(player != null, "GLB 模型应带 AnimationPlayer")
	if player == null:
		_finish(match_instance)
		return
	for clip in ALL_CLIPS:
		_check(player.has_animation(clip), "应有剪辑 %s" % clip)

	await get_tree().create_timer(0.6).timeout
	_check(player.current_animation == "Idle" and player.is_playing(),
		"待命应播 Idle（实际 %s）" % player.current_animation)

	gateway.SetFirePolicy([infantry], "HoldFire", human)
	var destination = infantry.global_position + Vector3(6, 0, 0)
	var move_result = gateway.ForceMoveUnits([infantry], destination, human)
	_check(move_result.get("unit_results", []).any(
		func(item): return item.get("accepted", false)
	), "应接受移动命令")
	# 6 秒窗口内追踪: 单位累计位移且任意时刻出现 Run 剪辑即通过
	# (路径可能中途被障碍截断, 不能假设固定采样点仍在移动)
	var saw_move_clip := false
	var elapsed := 0.0
	var prev_pos: Vector3 = infantry.global_position
	var accumulated := 0.0
	while elapsed < 6.0 and (not saw_move_clip or accumulated <= 1.0):
		await get_tree().create_timer(0.1).timeout
		elapsed += 0.1
		accumulated += infantry.global_position.distance_to(prev_pos)
		prev_pos = infantry.global_position
		var c: String = player.current_animation
		if c == "Run" and player.is_playing():
			saw_move_clip = true
	print("MOVE_DIAG elapsed=%.1f accumulated=%.2fm saw_clip=%s" % [
		elapsed, accumulated, saw_move_clip])
	_check(accumulated > 1.0, "单位应实际位移（%.2fm）" % accumulated)
	_check(saw_move_clip, "移动中应出现 Run 剪辑")
	if DisplayServer.get_name() != "headless":
		await _screenshot("G:/AIRTS/tmp_logs/anim_verify_r2/driver_moving.png", infantry.global_position)

	infantry.hp = infantry.hp - 1
	await get_tree().process_frame
	await get_tree().process_frame
	_check(player.current_animation == "Hit",
		"受击应短暂覆盖为 Hit（实际 %s）" % player.current_animation)
	_check(infantry.hp > 0, "受击测试不应把步兵打死")
	_check(absf(player.get_animation("Hit").length - 0.3) < 0.001, "轻受击长度应为 0.3s")
	await get_tree().create_timer(0.1).timeout
	infantry.hp = infantry.hp - 1
	_check(player.current_animation_position < 0.02, "连续子弹应立即重启冲击，不能被同名动作吞掉")
	await get_tree().create_timer(0.12).timeout
	_check(player.current_animation == "Hit", "连续中弹后的短促受击应仍在播放")

	gateway.StopUnits([infantry], human)
	elapsed = 0.0
	while elapsed < 6.0:
		await get_tree().create_timer(0.2).timeout
		elapsed += 0.2
		if player.current_animation == "Idle":
			break
	_check(player.current_animation == "Idle",
		"停止且受击窗口过后应回 Idle（实际 %s）" % player.current_animation)

	await _test_fire_events(match_instance, human, gateway)
	# 掉血量不再决定死亡表现；未致死的高伤害不能把活人播成尸体。
	infantry.hp = 100
	await get_tree().process_frame
	await get_tree().process_frame
	infantry.hp = 69
	await get_tree().process_frame
	await get_tree().process_frame
	_check(player.current_animation == "Hit", "未致死高伤害应使用短促受击，不能炸飞后复活")
	await get_tree().create_timer(0.4).timeout
	_check(player.current_animation == "Idle", "存活受击结束后恢复 Idle")

	# 走真实投射物落点结算，验证炮弹/步枪资源上的命中标签确实传到动画。
	gateway.SetFirePolicy(get_tree().get_nodes_in_group("units").filter(func(unit): return unit.get_parent() == human), "HoldFire", human)
	var enemy := Node3D.new()
	enemy.name = "ReactionTestEnemy"
	enemy.set_script(PlayerScript)
	enemy.set("color", Color.RED)
	enemy.add_to_group("players")
	match_instance.get_node("Players").add_child(enemy)
	var cannon = TankScene.instantiate()
	MatchSignals.setup_and_spawn_unit.emit(cannon, Transform3D(Basis(), infantry.global_position + Vector3(3, 0, 0)), enemy)
	await get_tree().process_frame
	gateway.SetFirePolicy([cannon], "HoldFire", enemy)
	infantry.hp = 1
	var runtime = match_instance.get_node("ProjectileRuntime")
	var muzzle: Node3D = cannon.find_child("ProjectileOrigin", true, false)
	var blast_direction: Vector3 = infantry.global_position - muzzle.global_position
	blast_direction.y = 0.0
	blast_direction = blast_direction.normalized()
	runtime.LaunchEntity(cannon, infantry)
	await get_tree().create_timer(0.75).timeout
	_check(not is_instance_valid(infantry), "致死爆炸应立即移除战斗单位")
	var visuals := get_tree().get_nodes_in_group("infantry_death_visuals")
	_check(visuals.size() == 1, "单位销毁后仍应保留一个死亡视觉")
	if visuals.size() == 1:
		var visual: Node3D = visuals[0]
		var death_player: AnimationPlayer = visual.find_child("AnimationPlayer", true, false)
		_check(visual.get_meta("death_clip") == "HitHeavy", "真实炮弹致死应选择爆炸击飞死亡")
		_check(not visual.is_in_group("units") and visual.find_children("*", "CollisionObject3D", true, false).is_empty(), "死亡视觉不得继续参战或保留碰撞")
		_check(visual.global_basis.z.normalized().dot(blast_direction) > 0.99, "炸飞方向应背离炮弹来向")
		_check(death_player != null and death_player.is_playing(), "死亡视觉应继续播放腾空过程")
		if DisplayServer.get_name() != "headless":
			await _screenshot("G:/AIRTS/tmp_logs/anim_verify_r2/blast_airborne.png", visual.global_position + blast_direction * 0.45)
		# 按真实剪辑长度等待播放结束，不硬编码固定等待。
		var blast_clip_length: float = death_player.get_animation("HitHeavy").length
		await get_tree().create_timer(blast_clip_length + 0.3).timeout
		# 生命期观察只捕获实例 ID：视觉节点可能已释放，闭包不得持有对象引用，
		# 否则报 "Lambda capture ... was freed" 且把断言失败掩盖成运行期错误。
		var blast_visual_id := visual.get_instance_id()
		var blast_player_id := death_player.get_instance_id()
		var blast_settled := func():
			var visual_now = instance_from_id(blast_visual_id)
			var player_now = instance_from_id(blast_player_id)
			return (
				visual_now != null and player_now != null
				and not player_now.is_playing()
				and player_now.assigned_animation == "HitHeavy"
			)
		_check(await _wait_until(blast_settled, 2.0), "炸飞播完后应保持死亡姿态，不重播或站起")
		if DisplayServer.get_name() != "headless":
			var held_visual = instance_from_id(blast_visual_id)
			if held_visual != null:
				await _screenshot("G:/AIRTS/tmp_logs/anim_verify_r2/blast_death_hold.png",
					held_visual.global_position + blast_direction * 0.45)
		var blast_freed := func(): return instance_from_id(blast_visual_id) == null
		var freed := await _wait_until(
			blast_freed,
			blast_clip_length + AnimDriver.DEATH_HOLD_SECONDS + 2.0
		)
		_check(freed, "死亡视觉应在定格后清理")

	var shooter = InfantryScene.instantiate()
	var victim = InfantryScene.instantiate()
	MatchSignals.setup_and_spawn_unit.emit(shooter, Transform3D(Basis(), human.global_position + Vector3(4, 0, 0)), enemy)
	MatchSignals.setup_and_spawn_unit.emit(victim, Transform3D(Basis(), human.global_position + Vector3(6, 0, 0)), human)
	await get_tree().process_frame
	gateway.SetFirePolicy([shooter], "HoldFire", enemy)
	gateway.SetFirePolicy([victim], "HoldFire", human)
	victim.hp = 0.25
	runtime.LaunchEntity(shooter, victim)
	await get_tree().create_timer(0.75).timeout
	_check(not is_instance_valid(victim), "致死子弹应移除战斗单位")
	visuals = get_tree().get_nodes_in_group("infantry_death_visuals")
	_check(visuals.size() == 1 and visuals[0].get_meta("death_clip") == "Death", "真实步枪致死应普通倒地，不能因血量比例而被当成爆炸")
	# 断言失败后不得继续索引空数组：只有视觉确实存在才继续清理校验。
	if visuals.size() >= 1:
		var death_anim: AnimationPlayer = visuals[0].find_child("AnimationPlayer", true, false)
		var death_clip_length: float = death_anim.get_animation("Death").length
		var death_group_empty := func(): return get_tree().get_nodes_in_group("infantry_death_visuals").is_empty()
		var death_cleaned := await _wait_until(
			death_group_empty,
			death_clip_length + AnimDriver.DEATH_HOLD_SECONDS + 2.0
		)
		_check(death_cleaned, "普通死亡视觉也应自动清理")

	if DisplayServer.get_name() != "headless":
		await _screenshot("G:/AIRTS/tmp_logs/anim_verify_r2/driver_idle.png", shooter.global_position)

	_finish(match_instance)


## 命令链验证追击/连射；直接调用真实投射物运行时，精确覆盖中弹与移动的同帧竞争。
func _test_fire_events(match_instance, human, gateway):
	var enemy := Node3D.new()
	enemy.name = "FireTimingEnemy"
	enemy.set_script(PlayerScript)
	enemy.set("color", Color.RED)
	enemy.add_to_group("players")
	match_instance.get_node("Players").add_child(enemy)
	var attacker = InfantryScene.instantiate()
	var target = InfantryScene.instantiate()
	MatchSignals.setup_and_spawn_unit.emit(
		attacker, Transform3D(Basis(), human.global_position + Vector3(4, 0, 0)), human)
	MatchSignals.setup_and_spawn_unit.emit(
		target, Transform3D(Basis(), human.global_position + Vector3(16, 0, 0)), enemy)
	gateway.SetFirePolicy([attacker], "HoldFire", human)
	gateway.SetFirePolicy([target], "HoldFire", enemy)
	target.hp = 1000
	await get_tree().create_timer(0.5).timeout
	var player: AnimationPlayer = attacker.find_child("AnimationPlayer", true, false)
	var runtime = match_instance.get_node("ProjectileRuntime")
	var projectiles = match_instance.get_node("Projectiles")
	# Dictionary 是引用容器，信号闭包更新后等待协程也能观察到。
	# fired_msec/fire_entries 供"进入 Fire 必须有真实发射事件兜底"的全程监视。
	var events := {"fired": 0, "spawned": 0, "ordered": true,
		"fired_msec": [], "fire_entries": [], "stop_monitor": false}
	var on_spawn := func(_projectile): events.spawned += 1
	projectiles.child_entered_tree.connect(on_spawn)
	attacker.attack_fired.connect(func():
		events.fired += 1
		events.fired_msec.append(Time.get_ticks_msec())
		events.ordered = events.ordered and events.spawned == events.fired)
	_begin_fire_entry_monitor(player.get_instance_id(), events)
	gateway.SetFirePolicy([attacker], "FireAtWill", human)
	var result = gateway.AttackUnits([attacker], target, human)
	_check(result.get("unit_results", []).any(
		func(item): return item.get("accepted", false)), "射程外普通攻击命令应被接受")
	var saw_run := false
	var premature_fire := false
	var deadline := Time.get_ticks_msec() + 12000
	while events.fired == 0 and Time.get_ticks_msec() < deadline:
		if not is_instance_valid(attacker) or not is_instance_valid(target):
			break
		if attacker.global_position.distance_to(target.global_position) > attacker.attack_range + 1.0:
			saw_run = saw_run or player.current_animation == "Run"
			premature_fire = premature_fire or player.current_animation == "Fire"
		await get_tree().process_frame
	_check(saw_run and not premature_fire, "射程外追击应播放 Run，不能提前播放 Fire")
	_check(events.fired > 0, "进入射程后应由真实投射物发出 attack_fired")
	if events.fired == 0 or not is_instance_valid(attacker) or not is_instance_valid(target):
		projectiles.child_entered_tree.disconnect(on_spawn)
		if is_instance_valid(attacker):
			attacker.queue_free()
		enemy.queue_free()
		return
	_check(await _wait_until(func(): return player.current_animation == "Fire", 2.0),
		"停稳后的实际发射应播放 Fire")

	# 放慢播放，让两个真实发射事件落在同一段 Fire 内，验证同名动作重启。
	player.speed_scale = 0.25
	await _wait_for_shot(events, events.fired + 1)
	await get_tree().create_timer(0.2).timeout
	var previous_position := player.current_animation_position
	await _wait_for_shot(events, events.fired + 1)
	_check(player.current_animation == "Fire" and previous_position > 0.03
		and player.current_animation_position < previous_position,
		"连续真实发射应重启仍在播放的 Fire")

	# 保留攻击 Action，仅延长下一次冷却；验证单发结束不会自动循环。
	attacker.attack_interval = 10.0
	player.speed_scale = 2.0
	await _wait_for_shot(events, events.fired + 1)
	var count_after_shot: int = events.fired
	var fire_seconds := player.get_animation("Fire").length / player.speed_scale
	await get_tree().create_timer(fire_seconds * 0.6).timeout
	_check(player.current_animation == "Fire", "二倍速 Fire 不应被计时器二次缩短")
	await get_tree().create_timer(fire_seconds * 0.4 + 0.1).timeout
	_check(player.current_animation == "Idle" and events.fired == count_after_shot
		and attacker.action != null,
		"仍处攻击冷却时，单发结束应回 Idle 且不能自行重播")
	gateway.SetFirePolicy([attacker], "HoldFire", human)
	gateway.StopUnits([attacker], human)
	player.speed_scale = 1.0
	await get_tree().create_timer(0.2).timeout

	# 同样的事件必须覆盖地面发射，不能只在 OrdinaryAttacking 上触发。
	var count_before_ground: int = events.fired
	runtime.LaunchGround(attacker, attacker.global_position + Vector3(0, 0, 2))
	_check(events.fired == count_before_ground + 1, "真实地面发射应恰好触发一次 attack_fired")
	_check(await _wait_until(func(): return player.current_animation == "Fire", 0.5),
		"地面射击也应播放 Fire")
	# 暂停整个场景树时 Fire 必须原地保持，恢复后正常收尾，不能提前结束或卡死。
	var position_at_pause: float = player.current_animation_position
	get_tree().paused = true
	await get_tree().create_timer(0.3).timeout
	_check(player.current_animation == "Fire"
		and absf(player.current_animation_position - position_at_pause) < 0.02,
		"暂停期间 Fire 应保持原进度不推进")
	get_tree().paused = false
	await get_tree().create_timer(player.get_animation("Fire").length + 0.2).timeout
	_check(player.current_animation == "Idle", "恢复后 Fire 应正常收尾回 Idle，不卡死")
	# 受击必须抢占 Fire，受击期间的新发射也不得覆盖 Hit 或事后补播。
	attacker.hp -= 0.1
	runtime.LaunchEntity(attacker, target)
	await get_tree().process_frame
	await get_tree().process_frame
	_check(player.current_animation == "Hit", "同帧中弹与开火应保留 Hit 优先级")
	await get_tree().create_timer(player.get_animation("Hit").length + 0.1).timeout
	_check(player.current_animation == "Idle", "受击结束不得补播已丢弃的开火事件")

	runtime.LaunchEntity(attacker, target)
	_check(await _wait_until(func(): return player.current_animation == "Fire", 0.5),
		"受击后新的真实发射应再次播放 Fire")
	var move_origin: Vector3 = attacker.global_position
	gateway.ForceMoveUnits([attacker], move_origin + Vector3(-6, 0, 0), human)
	# 注意：GDScript 解析器不接受 lambda 体跨行且后续还有实参的写法，
	# 复杂条件必须先落成独立 Callable 变量。生命期观察只捕获实例 ID，
	# 断言失败后的再次求值不得访问已释放的对象捕获。
	var attacker_id := attacker.get_instance_id()
	var attacker_player_id := player.get_instance_id()
	var run_with_displacement := func():
		var unit_now = instance_from_id(attacker_id)
		var player_now = instance_from_id(attacker_player_id)
		return (
			unit_now != null and player_now != null
			and player_now.current_animation == "Run"
			and unit_now.global_position.distance_to(move_origin) > 0.1
		)
	_check(await _wait_until(run_with_displacement, 2.0),
		"射击后移动应切换 Run，并产生实际位移")
	# 此处只隔离表现层竞争，发射仍创建真实子弹，不伪造信号或直接播放剪辑。
	runtime.LaunchEntity(attacker, target)
	await get_tree().process_frame
	await get_tree().process_frame
	_check(player.current_animation == "Run", "移动中的发射不得抢占全身 Run 造成站姿滑行")
	gateway.StopUnits([attacker], human)
	# 复现回归：移动开火后立即停止，回到 Idle 的过程中不得补播 Fire。
	# 旧实现只断言最终 Idle，掩盖了中途经 Fire 的错误表现。
	var replayed_fire := false
	var stop_deadline := Time.get_ticks_msec() + 800
	while Time.get_ticks_msec() < stop_deadline:
		if player.current_animation == "Fire":
			replayed_fire = true
			break
		if player.current_animation == "Idle":
			break
		await get_tree().process_frame
	_check(not replayed_fire, "移动开火后停止不得补播旧射击（应直接回 Idle）")
	var stopped_idle := func():
		var player_now = instance_from_id(attacker_player_id)
		return player_now != null and player_now.current_animation == "Idle"
	_check(await _wait_until(stopped_idle, 2.0),
		"移动停止后应回 Idle，不补播移动中的射击")
	await get_tree().create_timer(player.get_animation("Fire").length + 0.1).timeout
	_check(player.current_animation == "Idle", "无新发射时应保持 Idle")
	# 强制实体攻击在停火策略下也必须走同一条真实发射链（追击后站定开火）。
	attacker.attack_interval = 0.6
	attacker.remove_meta("next_attack_availability_time")
	var forced_result = gateway.ForceAttackUnits([attacker], target, human)
	_check(forced_result.get("unit_results", []).any(
		func(item): return item.get("accepted", false)), "强制实体攻击命令应被接受")
	var count_before_forced: int = events.fired
	_check(await _wait_until(func(): return events.fired > count_before_forced, 4.0),
		"停火策略下的强制实体攻击仍应由真实投射物触发 attack_fired")
	_check(await _wait_until(func(): return player.current_animation == "Fire", 0.5),
		"强制实体攻击也应播放 Fire")
	gateway.StopUnits([attacker], human)
	await get_tree().create_timer(0.2).timeout
	# 强制地面攻击同样复用统一发射事件；步兵 can_force_fire_ground=true。
	attacker.remove_meta("next_attack_availability_time")
	var forced_ground_result = gateway.ForceAttackGround(
		[attacker], attacker.global_position + Vector3(0, 0, 2), human)
	_check(forced_ground_result.get("unit_results", []).any(
		func(item): return item.get("accepted", false)), "强制地面攻击命令应被接受")
	var count_before_forced_ground: int = events.fired
	_check(await _wait_until(func(): return events.fired > count_before_forced_ground, 3.0),
		"强制地面攻击应由真实投射物触发 attack_fired")
	_check(await _wait_until(func(): return player.current_animation == "Fire", 0.5),
		"强制地面攻击也应播放 Fire")
	_check(events.ordered and events.fired == events.spawned and events.fired >= 8,
		"每个开火事件之前必须已有真实投射物，且一弹一事件（%d/%d）" % [events.fired, events.spawned])
	# 停止监视并核对全程：每一次动画进入 Fire 都必须有 0.3s 内的真实
	# 发射事件兜底；移动开火残余补播等回归会以"无来源进入"暴露。
	_monitor_player_id = 0
	_check(_all_fire_entries_backed(events),
		"每次进入 Fire 播放都必须有真实发射事件兜底（全程监视）")
	projectiles.child_entered_tree.disconnect(on_spawn)
	attacker.queue_free()
	enemy.queue_free()
	await get_tree().process_frame


func _wait_for_shot(events: Dictionary, count: int):
	_check(await _wait_until(func(): return events.fired >= count, 2.0),
		"应等到第 %d 次真实发射" % count)
	# 开火事件由本帧位移采样后消费；等待表现层处理完毕再读播放位置。
	await get_tree().process_frame
	await get_tree().process_frame


## 启动 Fire 进入监视（Fire 播放中的同名重启不算进入）。
## 观察只持有实例 ID，被监视单位释放后 _process 中安全停止。
func _begin_fire_entry_monitor(player_id: int, events: Dictionary) -> void:
	_monitor_player_id = player_id
	_monitor_events = events
	_monitor_was_fire = false


## 校验每次进入 Fire 播放都有真实发射事件兜底。
## 合法表现链路：事件 → 挂起窗口(250ms，窗口内等速度滤波归零) → 消费播放，
## 被动推挤可拖满整个窗口再消费，故容差取 400ms（250ms 窗口 + 过渡 + 帧调度）。
## 停止后补播旧射击的回归会以"无来源进入"在此暴露。
func _all_fire_entries_backed(events: Dictionary) -> bool:
	var unbacked := 0
	for entry_msec in events.fire_entries:
		var backed := false
		for shot_msec in events.fired_msec:
			if shot_msec <= entry_msec and entry_msec - shot_msec <= 400:
				backed = true
				break
		if not backed:
			unbacked += 1
			print("FIRE_ENTRY_UNBACKED entry=%d shots=%s" % [entry_msec, events.fired_msec])
	print("FIRE_MONITOR entries=%s" % [events.fire_entries])
	print("FIRE_MONITOR shots=%s" % [events.fired_msec])
	return unbacked == 0


func _wait_until(condition: Callable, timeout_seconds: float) -> bool:
	var deadline := Time.get_ticks_msec() + int(timeout_seconds * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if condition.call():
			return true
		await get_tree().process_frame
	return condition.call()


func _screenshot(path: String, focus: Vector3):
	# 审核相机对准实际测试对象，避免主相机保留编辑器位置而截到空地。
	var camera := Camera3D.new()
	camera.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	add_child(camera)
	camera.global_position = focus + Vector3(3, 3, -4)
	camera.look_at(focus + Vector3(0, 0.4, 0))
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 4.0
	camera.current = true
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var image := get_viewport().get_texture().get_image()
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	image.save_png(path)
	print("SCREENSHOT_SAVED ", path)
	camera.queue_free()


func _check(condition: bool, message: String):
	if condition:
		print("PASS ", message)
	else:
		_failures += 1
		push_error("FAIL " + message)
		print("FAIL ", message)


func _finish(match_instance):
	print("InfantryAnimDriverSmokeTest completed: %d failure(s)" % _failures)
	match_instance.queue_free()
	await get_tree().process_frame
	SmokeTestExit.request(get_tree(), 1 if _failures > 0 else 0)
