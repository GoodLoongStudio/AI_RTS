extends Node

## 验证原厂骨架步兵动画驱动：GLB 模型挂载、七段剪辑就绪、
## 待命/移动/受击状态映射正确播放。攻击（Fire）映射与移动共用
## 后缀匹配代码路径，由既有战斗类冒烟测试覆盖动作本身。

const MatchScene = preload("res://tests/manual/TestAllUnits.tscn")
const InfantryScene = preload("res://source/match/units/Infantry.tscn")
const TankScene = preload("res://source/match/units/Tank.tscn")
const PlayerScript = preload("res://source/match/players/Player.gd")

const ALL_CLIPS := ["Idle", "Run", "Hit", "HitHeavy", "Fire", "Crawl", "Death"]

var _failures := 0


func _ready():
	var match_instance = MatchScene.instantiate()
	add_child(match_instance)
	await get_tree().process_frame
	await get_tree().process_frame

	var human = match_instance.get_node("Players/Human")
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

	var gateway = human.get_node("UnitCommandGateway")
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
		await _screenshot("G:/AIRTS/tmp_logs/anim_verify/driver_moving.png", infantry.global_position)

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
		_check(death_player.is_playing(), "死亡视觉应继续播放腾空过程")
		if DisplayServer.get_name() != "headless":
			await _screenshot("G:/AIRTS/tmp_logs/anim_verify/blast_airborne.png", visual.global_position + blast_direction * 0.45)
		await get_tree().create_timer(1.75).timeout
		_check(is_instance_valid(visual) and not death_player.is_playing() and death_player.assigned_animation == "HitHeavy", "炸飞播完后应保持死亡姿态，不重播或站起")
		if DisplayServer.get_name() != "headless":
			await _screenshot("G:/AIRTS/tmp_logs/anim_verify/blast_death_hold.png", visual.global_position + blast_direction * 0.45)
		await get_tree().create_timer(1.0).timeout
		_check(not is_instance_valid(visual), "死亡视觉应在定格后清理")

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
	await get_tree().create_timer(3.5).timeout
	_check(get_tree().get_nodes_in_group("infantry_death_visuals").is_empty(), "普通死亡视觉也应自动清理")

	if DisplayServer.get_name() != "headless":
		await _screenshot("G:/AIRTS/tmp_logs/anim_verify/driver_idle.png", shooter.global_position)

	_finish(match_instance)


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
