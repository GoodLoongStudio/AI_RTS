extends Node

const MatchScene = preload("res://tests/manual/TestOneUnit.tscn")
const CommandCenterScene = preload("res://source/match/units/CommandCenter.tscn")
const Player = preload("res://source/match/players/Player.gd")
const ReturningToBase = preload("res://source/match/units/actions/ReturningToBase.gd")
const TacticalWithdrawing = preload("res://source/match/units/actions/TacticalWithdrawing.gd")

var _failures := 0


func _ready():
	var match_instance = MatchScene.instantiate()
	add_child(match_instance)
	await get_tree().process_frame
	await get_tree().process_frame

	var human = match_instance.get_node("Players/Human")
	var tank = human.get_node("Tank")
	var gateway = human.get_node("UnitCommandGateway")
	var runtime = match_instance.get_node("CommandRuntime")

	var near_base = CommandCenterScene.instantiate()
	near_base.name = "NearCommandCenter"
	match_instance._setup_and_spawn_unit(
		near_base,
		tank.global_transform.translated(Vector3(-8.0, 0.0, 0.0)),
		human,
		false
	)
	var far_base = CommandCenterScene.instantiate()
	far_base.name = "FarCommandCenter"
	match_instance._setup_and_spawn_unit(
		far_base,
		tank.global_transform.translated(Vector3(14.0, 0.0, 0.0)),
		human,
		false
	)
	_check(await _wait_for_completed_base(near_base), "近处基地应完成运行时注册")
	_check(await _wait_for_completed_base(far_base), "远处基地应完成运行时注册")

	var start_position: Vector3 = tank.global_position
	var result: Dictionary = gateway.SetEngagementStance([tank], "ReturnToBase", human)
	_check(result["status"] == "Accepted", "有已完成己方基地时 V 回基地应被接受")
	_check(
		tank.action != null and tank.action.get_script() == ReturningToBase,
		"V 回基地应创建 ReturningToBase Action"
	)
	_check(
		gateway.GetEngagementStance(tank) == "ReturnToBase",
		"V 回基地应保存 ReturnToBase 姿态"
	)
	var order_id: String = result["unit_results"][0]["order_id"]
	_check(runtime.GetActiveOrderState(tank) == "InProgress", "回基地订单应进入 InProgress")
	var movement = tank.find_child("Movement")
	_check(not movement.get("_is_tactical_withdrawal"), "回基地不得启用战术倒车速度")

	# 先确认已经开始移动，再在抵达前暂停，验证持续订单可被 Halt 保留。
	await get_tree().create_timer(0.25).timeout
	_check(
		tank.global_position.distance_to(start_position) > 0.05,
		"回基地 Action 应沿正常移动路径推进"
	)
	_check(
		tank.global_position.distance_to(near_base.global_position)
			< tank.global_position.distance_to(far_base.global_position),
		"回基地应选择最近的己方基地"
	)

	var halt_result: Dictionary = gateway.HaltMovement([tank], human)
	_check(halt_result["status"] == "Accepted", "停止回基地应被接受")
	_check(runtime.GetOrderState(order_id) == "Suspended", "停止应暂停回基地订单")

	var withdraw_result: Dictionary = gateway.TacticalWithdrawUnits(
		[tank], tank.global_position + Vector3(0.0, 0.0, 3.0), human
	)
	_check(withdraw_result["status"] == "Accepted", "Z 战术后退仍应被接受")
	_check(
		tank.action != null and tank.action.get_script() == TacticalWithdrawing,
		"Z 应继续创建 TacticalWithdrawing Action"
	)

	# 把单位放到基地停靠半径内，确认持续回基地不是一次性移动，
	# 抵达后会停住并把订单转换为 Arrived。
	tank.global_position = near_base.global_position + Vector3(0.0, 0.0, 1.0)
	var arrival_result: Dictionary = gateway.SetEngagementStance([tank], "ReturnToBase", human)
	_check(arrival_result["status"] == "Accepted", "再次设置回基地姿态应被接受")
	var arrival_order_id: String = arrival_result["unit_results"][0]["order_id"]
	await get_tree().process_frame
	await get_tree().process_frame
	_check(runtime.GetOrderState(arrival_order_id) == "Arrived", "抵达基地后订单应为 Arrived")
	_check(
		movement.target_position == Vector3.INF,
		"抵达基地后 Movement 应清除导航目标并停止"
	)
	_check(
		tank.action != null and tank.action.get_script() == ReturningToBase,
		"抵达后仍应保留 ReturningToBase Action 监控持续姿态"
	)

	# 保留姿态期间旧基地被摧毁时，应自动切换到新的最近己方基地并恢复普通速度。
	var replacement_base = CommandCenterScene.instantiate()
	replacement_base.name = "ReplacementCommandCenter"
	match_instance._setup_and_spawn_unit(
		replacement_base,
		tank.global_transform.translated(Vector3(8.0, 0.0, 0.0)),
		human,
		false
	)
	_check(await _wait_for_completed_base(replacement_base), "替代基地应完成运行时注册")
	near_base.queue_free()
	far_base.queue_free()
	_check(
		await _wait_for_replacement_target(tank, movement, replacement_base),
		"旧基地失效后应切换到新基地并重新移动"
	)
	# 先在替代基地内完成第二次抵达，再销毁它；同一持续订单应继续收到 TargetLost。
	tank.global_position = replacement_base.global_position + Vector3(0.0, 0.0, 1.0)
	for _i in range(12):
		await get_tree().process_frame
	_check(
		runtime.GetOrderState(arrival_order_id) == "Arrived",
		"持续姿态在替代基地抵达后仍应保留原订单快照"
	)
	replacement_base.queue_free()
	_check(
		await _wait_for_order_state(runtime, arrival_order_id, "TargetLost"),
		"抵达后基地被摧毁且无替代时同一订单应为 TargetLost"
	)

	# 导航明确报告不可达时，回基地订单必须结束为 Unreachable，不能静默重试成假进行中。
	var unreachable_base = CommandCenterScene.instantiate()
	unreachable_base.name = "UnreachableCommandCenter"
	match_instance._setup_and_spawn_unit(
		unreachable_base,
		tank.global_transform.translated(Vector3(8.0, 0.0, 0.0)),
		human,
		false
	)
	_check(await _wait_for_completed_base(unreachable_base), "不可达测试基地应完成运行时注册")
	var unreachable_result: Dictionary = gateway.SetEngagementStance([tank], "ReturnToBase", human)
	_check(unreachable_result["status"] == "Accepted", "不可达场景回基地姿态应先被接受")
	var unreachable_order_id: String = unreachable_result["unit_results"][0]["order_id"]
	tank.find_child("Movement").emit_signal("movement_ended", "Unreachable")
	await get_tree().process_frame
	_check(
		runtime.GetOrderState(unreachable_order_id) == "Unreachable",
		"导航不可达后回基地订单应为 Unreachable"
	)
	unreachable_base.queue_free()
	await get_tree().process_frame

	var enemy_player = _add_enemy_player(match_instance)
	var enemy_base = CommandCenterScene.instantiate()
	enemy_base.name = "EnemyCommandCenter"
	match_instance._setup_and_spawn_unit(
		enemy_base,
		tank.global_transform.translated(Vector3(4.0, 0.0, 0.0)),
		enemy_player,
		false
	)
	var unfinished_base = CommandCenterScene.instantiate()
	unfinished_base.name = "UnderConstructionCommandCenter"
	match_instance._setup_and_spawn_unit(
		unfinished_base,
		tank.global_transform.translated(Vector3(-4.0, 0.0, 0.0)),
		human,
		true
	)
	await get_tree().process_frame
	_check(unfinished_base.is_under_construction(), "施工中的基地应保持未完成状态")
	var no_base_result: Dictionary = gateway.SetEngagementStance([tank], "ReturnToBase", human)
	_check(no_base_result["status"] == "Rejected", "无完成己方基地时回基地姿态应拒绝")
	_check(
		no_base_result["unit_results"][0]["error_code"] == "CommandCenterNotFound",
		"敌方基地和施工中基地不得被选作回防目标"
	)

	print("Tank return to base smoke test completed: %d failure(s)" % _failures)
	match_instance.queue_free()
	await get_tree().process_frame
	SmokeTestExit.request(get_tree(), 0 if _failures == 0 else 1)


func _check(condition: bool, message: String):
	if condition:
		return
	_failures += 1
	push_error("Tank return to base assertion failed: %s" % message)


func _add_enemy_player(match_instance):
	var enemy_player := Node3D.new()
	enemy_player.name = "ReturnToBaseEnemy"
	enemy_player.set_script(Player)
	enemy_player.color = Color.RED
	enemy_player.add_to_group("players")
	match_instance.get_node("Players").add_child(enemy_player)
	return enemy_player


func _wait_for_completed_base(base) -> bool:
	for _i in range(120):
		if (
			is_instance_valid(base)
			and base.is_inside_tree()
			and base.has_method("is_constructed")
			and base.is_constructed()
			and str(base.unit_type_id) == "command_center"
		):
			return true
		await get_tree().process_frame
	return false


func _wait_for_replacement_target(tank, movement, replacement_base) -> bool:
	for _i in range(90):
		if (
			is_instance_valid(tank)
			and tank.action != null
			and tank.action.get_script() == ReturningToBase
			and not movement.get("_is_tactical_withdrawal")
			and movement.target_position != Vector3.INF
			and movement.target_position.distance_to(replacement_base.global_position) < 0.1
		):
			return true
		await get_tree().process_frame
	return false


func _wait_for_order_state(runtime, order_id: String, expected: String) -> bool:
	for _i in range(60):
		if runtime.GetOrderState(order_id) == expected:
			return true
		await get_tree().process_frame
	return runtime.GetOrderState(order_id) == expected
