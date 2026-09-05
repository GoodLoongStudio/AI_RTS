extends Node

## 验证步兵动画驱动（v2）：GLB 模型挂载、九段剪辑就绪、
## 待命/移动/受击状态映射正确播放。攻击（Fire）映射与移动共用
## 后缀匹配代码路径，由既有战斗类冒烟测试覆盖动作本身。

const MatchScene = preload("res://tests/manual/TestAllUnits.tscn")
const InfantryScene = preload("res://source/match/units/Infantry.tscn")

const ALL_CLIPS := ["Idle", "Walk", "Run", "Attack", "Fire", "Gather", "Build", "Hit", "Death"]

var _failures := 0


func _ready():
	var match_instance = MatchScene.instantiate()
	add_child(match_instance)
	await get_tree().process_frame
	await get_tree().process_frame

	var human = match_instance.get_node("Players/Human")
	var infantry = InfantryScene.instantiate()
	infantry.global_transform = Transform3D(Basis(), human.global_position + Vector3(4, 0, 0))
	human.add_child(infantry)
	MatchSignals.setup_and_spawn_unit.emit(infantry, infantry.global_transform, human)
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
	# 6 秒窗口内追踪: 单位累计位移且任意时刻出现 Walk/Run 剪辑即通过
	# (路径可能中途被障碍截断, 不能假设固定采样点仍在移动)
	var saw_move_clip := false
	var elapsed := 0.0
	var prev_pos: Vector3 = infantry.global_position
	var accumulated := 0.0
	while elapsed < 6.0 and not saw_move_clip:
		await get_tree().create_timer(0.1).timeout
		elapsed += 0.1
		accumulated += infantry.global_position.distance_to(prev_pos)
		prev_pos = infantry.global_position
		var c: String = player.current_animation
		if (c == "Walk" or c == "Run") and player.is_playing():
			saw_move_clip = true
	print("MOVE_DIAG elapsed=%.1f accumulated=%.2fm saw_clip=%s" % [
		elapsed, accumulated, saw_move_clip])
	_check(accumulated > 1.0, "单位应实际位移（%.2fm）" % accumulated)
	_check(saw_move_clip, "移动中应出现 Walk/Run 剪辑")
	if DisplayServer.get_name() != "headless":
		await _screenshot("G:/AIRTS/tmp_logs/anim_verify/driver_moving.png")

	infantry.hp = infantry.hp - 1
	await get_tree().process_frame
	await get_tree().process_frame
	_check(player.current_animation == "Hit",
		"受击应短暂覆盖为 Hit（实际 %s）" % player.current_animation)
	_check(infantry.hp > 0, "受击测试不应把步兵打死")

	gateway.StopUnits([infantry], human)
	elapsed = 0.0
	while elapsed < 6.0:
		await get_tree().create_timer(0.2).timeout
		elapsed += 0.2
		if player.current_animation == "Idle":
			break
	_check(player.current_animation == "Idle",
		"停止且受击窗口过后应回 Idle（实际 %s）" % player.current_animation)

	if DisplayServer.get_name() != "headless":
		await _screenshot("G:/AIRTS/tmp_logs/anim_verify/driver_idle.png")

	_finish(match_instance)


func _screenshot(path: String):
	await RenderingServer.frame_post_draw
	var image := get_viewport().get_texture().get_image()
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	image.save_png(path)
	print("SCREENSHOT_SAVED ", path)


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
