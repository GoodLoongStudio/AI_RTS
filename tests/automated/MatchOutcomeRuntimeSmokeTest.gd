extends Node

const MatchOutcomeRuntimeScript = preload(
	"res://source/csharp/GodotAdapter/Match/MatchOutcomeRuntime.cs"
)
const MatchEndHandlerScene = preload("res://source/match/handlers/MatchEndHandler.tscn")
const PlayerVsAiScene = preload("res://tests/manual/TestPlayerVsAI.tscn")

var _failures := 0


## 验证 C# 胜负服务的 Godot 事实桥接、同帧平局和 Legacy 面板映射。
func _ready():
	process_mode = Node.PROCESS_MODE_ALWAYS
	await _test_human_victory_and_spawn_bridge()
	await _test_human_defeat()
	await _test_draw()
	await _test_ai_only_finish()
	await _test_campaign_victory_without_annihilation()
	await _test_campaign_defeat_without_annihilation()
	await _test_locked_outcome_cannot_be_resettled()
	await _test_actual_match_unit_death_path()

	print("Match outcome runtime smoke test completed: %d failure(s)" % _failures)
	SmokeTestExit.request(get_tree(), 0 if _failures == 0 else 1)


## 验证新生成单位会延后淘汰，并在最后一个敌方单位死亡后显示胜利。
func _test_human_victory_and_spawn_bridge():
	var fixture: Dictionary = await _create_fixture(true)
	var runtime = fixture.runtime
	var enemy = fixture.second_player
	var extra_enemy := _add_unit(enemy, "ExtraEnemy")
	MatchSignals.unit_spawned.emit(extra_enemy)
	_kill(fixture.second_unit)
	await get_tree().process_frame

	_check(runtime.InspectOutcome().get("kind", "") == "InProgress",
		"新生成敌军存活时不得提前胜利")
	_kill(extra_enemy)
	await get_tree().process_frame
	await get_tree().process_frame

	_check(runtime.InspectOutcome().get("kind", "") == "Won",
		"最后一个敌军死亡后应产生 Won")
	_check(runtime.InspectOutcome().get("local_result", "") == "Victory",
		"本机歼灭胜利的 local_result 应为 Victory")
	_check(fixture.handler.find_child("Victory").visible,
		"本机 Human 获胜应显示 Victory")
	_check(not fixture.handler.find_child("CampaignSummary").visible,
		"非战役对局不应显示战役结算摘要")
	_check(not fixture.handler.find_child("RestartButton").visible,
		"非战役对局不应显示重开本关")
	await _dispose_fixture(fixture)


## 验证本机 Human 所在阵营淘汰后显示失败。
func _test_human_defeat():
	var fixture: Dictionary = await _create_fixture(true)
	_kill(fixture.first_unit)
	await get_tree().process_frame
	await get_tree().process_frame

	_check(fixture.runtime.InspectOutcome().get("local_result", "") == "Defeat",
		"本机淘汰的 local_result 应为 Defeat")
	_check(fixture.handler.find_child("Defeat").visible,
		"本机 Human 淘汰后应显示 Defeat")
	await _dispose_fixture(fixture)


## 验证同一帧双方全灭只发布平局并复用 Finish 面板。
func _test_draw():
	var fixture: Dictionary = await _create_fixture(true)
	_kill(fixture.first_unit)
	_kill(fixture.second_unit)
	await get_tree().process_frame
	await get_tree().process_frame

	var snapshot: Dictionary = fixture.runtime.InspectOutcome()
	_check(snapshot.get("kind", "") == "Draw", "同帧全灭应判为 Draw")
	_check(snapshot.get("local_result", "") == "Finish", "平局的 local_result 应为 Finish")
	_check(snapshot.get("winning_side_ids", []).is_empty(), "Draw 不应包含胜方")
	_check(fixture.handler.find_child("Finish").visible,
		"当前 Draw 应复用 Finish 面板")
	await _dispose_fixture(fixture)


## 验证无 Human 的 AI 对局保留真实胜方但只显示普通结束。
func _test_ai_only_finish():
	var fixture: Dictionary = await _create_fixture(false)
	_kill(fixture.second_unit)
	await get_tree().process_frame
	await get_tree().process_frame

	var snapshot: Dictionary = fixture.runtime.InspectOutcome()
	_check(snapshot.get("kind", "") == "Won", "无 Human 对局仍应保留 Won")
	_check(snapshot.get("winning_side_ids", []).size() == 1,
		"无 Human 对局仍应包含真实胜方")
	_check(snapshot.get("local_human_side_id", "").is_empty(),
		"无 Human 对局应显式返回空本机阵营")
	_check(fixture.handler.find_child("Finish").visible,
		"无 Human 对局应显示 Finish")
	await _dispose_fixture(fixture)


## 验证战役目标完成可在敌军仍存活时锁定 Victory。
func _test_campaign_victory_without_annihilation():
	var fixture: Dictionary = await _create_fixture(true)
	_check(fixture.runtime.DeclareCampaignVictory(), "战役胜利入口应成功锁定终局")
	await get_tree().process_frame

	var snapshot: Dictionary = fixture.runtime.InspectOutcome()
	_check(snapshot.get("kind", "") == "Won", "战役胜利应为 Won")
	_check(snapshot.get("local_result", "") == "Victory", "战役胜利的 local_result 应为 Victory")
	_check(snapshot.get("surviving_side_ids", []).size() == 2,
		"战役胜利不得要求先歼灭敌军")
	_check(fixture.handler.find_child("Victory").visible,
		"战役胜利应走统一 Victory 面板")
	_check(not fixture.runtime.DeclareCampaignVictory(),
		"终态后再次宣告战役胜利应失败")
	await _dispose_fixture(fixture)


## 验证战役失败可在本机单位仍存活时锁定 Defeat。
func _test_campaign_defeat_without_annihilation():
	var fixture: Dictionary = await _create_fixture(true)
	_check(fixture.runtime.DeclareCampaignDefeat(), "战役失败入口应成功锁定终局")
	await get_tree().process_frame

	var snapshot: Dictionary = fixture.runtime.InspectOutcome()
	_check(snapshot.get("kind", "") == "Won", "战役失败仍应保留真实胜方")
	_check(snapshot.get("local_result", "") == "Defeat", "战役失败的 local_result 应为 Defeat")
	_check(not snapshot.get("local_human_side_id", "") in snapshot.get("winning_side_ids", []),
		"战役失败时本机阵营不得列为胜方")
	_check(snapshot.get("surviving_side_ids", []).size() == 2,
		"战役失败不得要求先歼灭本机单位")
	_check(fixture.handler.find_child("Defeat").visible,
		"战役失败应走统一 Defeat 面板")
	_check(not fixture.runtime.DeclareCampaignDefeat(),
		"终态后再次宣告战役失败应失败")
	await _dispose_fixture(fixture)


## 验证胜利锁定后失败宣告不得改写结果或切换面板。
func _test_locked_outcome_cannot_be_resettled():
	var fixture: Dictionary = await _create_fixture(true)
	_check(fixture.runtime.DeclareCampaignVictory(), "锁定测试应先宣告胜利")
	await get_tree().process_frame
	var locked: Dictionary = fixture.runtime.InspectOutcome()
	_check(fixture.runtime.IsOutcomeLocked(), "胜利后 IsOutcomeLocked 应为真")
	_check(not fixture.runtime.DeclareCampaignDefeat(), "锁定后宣告失败应被拒绝")
	var after: Dictionary = fixture.runtime.InspectOutcome()
	_check(after.get("kind", "") == locked.get("kind", ""), "锁定后 kind 不得变化")
	_check(after.get("version", -1) == locked.get("version", -2), "锁定后 version 不得变化")
	_check(after.get("winning_side_ids", []) == locked.get("winning_side_ids", []),
		"锁定后胜方不得变化")
	_check(fixture.handler.find_child("Victory").visible, "二次结算不得撤掉 Victory")
	_check(not fixture.handler.find_child("Defeat").visible, "二次结算不得改出 Defeat")
	await _dispose_fixture(fixture)


## 验证真实 Match 与 Unit.gd 的 tree_exited 死亡通知能够触发 Victory。
func _test_actual_match_unit_death_path():
	get_tree().paused = false
	var match_instance = PlayerVsAiScene.instantiate()
	add_child(match_instance)
	await get_tree().process_frame
	await get_tree().process_frame
	var human = match_instance.get_node("Players/Human")
	var enemy_players: Array = match_instance.get_node("Players").get_children().filter(
		func(player): return player != human and player.is_in_group("players")
	)
	for player in enemy_players:
		player.process_mode = Node.PROCESS_MODE_DISABLED
	var enemy_units: Array = get_tree().get_nodes_in_group("units").filter(
		func(unit): return match_instance.is_ancestor_of(unit) and unit.player != human
	)
	_check(not enemy_units.is_empty(), "真实 Match 应至少生成一个敌方单位")
	for unit in enemy_units:
		unit.call("_handle_unit_death")
	await get_tree().process_frame
	await get_tree().process_frame

	var runtime = match_instance.get_node("MatchOutcomeRuntime")
	var snapshot: Dictionary = runtime.InspectOutcome()
	_check(snapshot.get("kind", "") == "Won",
		"真实 Unit.gd 死亡入口清空敌军后应产生 Won")
	var handler = match_instance.get_node_or_null("Handlers/MatchEndHandler")
	_check(handler != null, "胜负专项 TestPlayerVsAI 不得移除 MatchEndHandler")
	if handler != null:
		_check(handler.find_child("Victory").visible,
			"真实 Match 清空敌军后应显示 Victory")
	get_tree().paused = false
	match_instance.queue_free()
	await get_tree().process_frame


## 创建含两名参与者、两单位、C# Runtime 和现有结束面板的最小对局。
func _create_fixture(has_human: bool) -> Dictionary:
	get_tree().paused = false
	var match_root := Node.new()
	match_root.name = "Match"
	var players := Node.new()
	players.name = "Players"
	match_root.add_child(players)
	var first_player := _add_player(players, "FirstPlayer")
	var second_player := _add_player(players, "SecondPlayer")
	var first_unit := _add_unit(first_player, "FirstUnit")
	var second_unit := _add_unit(second_player, "SecondUnit")
	var runtime = MatchOutcomeRuntimeScript.new()
	runtime.name = "MatchOutcomeRuntime"
	match_root.add_child(runtime)
	var handler = MatchEndHandlerScene.instantiate()
	handler.name = "MatchEndHandler"
	match_root.add_child(handler)
	add_child(match_root)
	await get_tree().process_frame

	runtime.Initialize(players, first_player if has_human else null)
	var initial: Dictionary = runtime.InspectOutcome()
	_check(initial.get("kind", "") == "InProgress", "双方初始存活时应继续对局")
	_check(initial.get("surviving_side_ids", []).size() == 2,
		"初始快照应包含两个存活阵营")
	return {
		"match_root": match_root,
		"runtime": runtime,
		"handler": handler,
		"first_player": first_player,
		"second_player": second_player,
		"first_unit": first_unit,
		"second_unit": second_unit,
	}


## 创建一个参与者节点并加入权威 players group。
func _add_player(players: Node, player_name: String) -> Node:
	var player := Node.new()
	player.name = player_name
	player.add_to_group("players")
	players.add_child(player)
	return player


## 创建一个直接归属玩家的计分实体。
func _add_unit(player: Node, unit_name: String) -> Node:
	var unit := Node.new()
	unit.name = unit_name
	unit.add_to_group("units")
	player.add_child(unit)
	return unit


## 发布权威死亡事实并移除对应测试节点。
func _kill(unit: Node):
	unit.queue_free()


## 恢复暂停并释放当前最小对局，使 Runtime 解除全局信号订阅。
func _dispose_fixture(fixture: Dictionary):
	get_tree().paused = false
	fixture.match_root.queue_free()
	await get_tree().process_frame


## 累计断言失败并输出可定位原因。
func _check(condition: bool, message: String):
	if condition:
		return
	_failures += 1
	push_error(message)
