extends Node

const MatchSettings = preload("res://source/data-model/MatchSettings.gd")
const PlayerSettings = preload("res://source/data-model/PlayerSettings.gd")
const CampaignMission = preload("res://source/campaign/CampaignMission.gd")

var _failures: Array[String] = []


func _ready():
	await get_tree().process_frame
	await _run_test()


func _run_test():
	if OS.get_environment("AI_RTS_FORCE_TEST_FAILURE") == "1":
		_check(false, "强制失败探针")

	# Use non-default values so the smoke test proves Match camera settings come from
	# the dedicated camera configuration instead of merely matching scene defaults.
	Globals.set_camera_option("edge_scroll_enabled", true)
	Globals.set_camera_option("movement_speed", 1.7)
	Globals.set_camera_option("edge_margin", 60.0)
	Globals.set_camera_option("bottom_edge_margin", 90.0)
	Globals.set_camera_option("smoothing", 12.0)
	Globals.set_camera_option("zoom_step", 1.5)
	Globals.save_camera_options()

	var persisted_camera_config := ConfigFile.new()
	_check(persisted_camera_config.load(Globals.CAMERA_CONFIG_PATH) == OK, "camera.cfg 未成功保存")
	_check(is_equal_approx(float(persisted_camera_config.get_value("camera", "movement_speed")), 1.7), "camera.cfg 移动速度未持久化")
	_check(is_equal_approx(float(persisted_camera_config.get_value("camera", "bottom_edge_margin")), 90.0), "camera.cfg 底边范围未持久化")

	await _verify_menu_settings_entry_points()

	var mission := CampaignMission.echo_extraction()
	var settings := MatchSettings.new()

	var human := PlayerSettings.new()
	human.controller = Constants.PlayerType.HUMAN
	human.color = Constants.Player.COLORS[0]
	settings.players.append(human)

	var enemy := PlayerSettings.new()
	enemy.controller = Constants.PlayerType.SIMPLE_CLAIRVOYANT_AI
	enemy.color = Constants.Player.COLORS[1]
	settings.players.append(enemy)

	settings.visible_player = 0
	settings.visibility = MatchSettings.Visibility.PER_PLAYER

	var campaign_map = load(mission["map_path"]).instantiate()
	var a_match = load("res://source/match/Match.tscn").instantiate()
	a_match.settings = settings
	a_match.map = campaign_map
	a_match.campaign_data = mission
	get_tree().root.add_child(a_match)

	for _frame in range(12):
		await get_tree().process_frame
		await get_tree().physics_frame

	var controlled_units = get_tree().get_nodes_in_group("controlled_units")
	var group_1 = get_tree().get_nodes_in_group("legacy_ai_squad_1")
	var group_2 = get_tree().get_nodes_in_group("legacy_ai_squad_2")
	var group_3 = get_tree().get_nodes_in_group("legacy_ai_squad_3")
	var ai_hud = a_match.get_node_or_null("HUD/AICommandHUD")
	var ai_hud_toggle = a_match.get_node_or_null("HUD/AICommandHUDToggle")
	var camera = a_match.get_node_or_null("IsometricCamera3D")
	var pause_menu = a_match.get_node_or_null("Menu")

	_check(a_match.get_node_or_null("CampaignController") != null, "CampaignController 未加载")
	_check(ai_hud != null, "AICommandHUD 未加载")
	_check(ai_hud_toggle != null, "AICommandHUD 显示切换按钮未加载")
	_check(not ai_hud.visible, "AICommandHUD 应默认隐藏")
	_check(camera.edge_scroll_enabled, "应对局启用鼠标边缘滚屏")
	_check(ai_hud.control_mode == "hero", "AICommandHUD 未进入单英雄模式")
	_check(controlled_units.size() == 1, "序章开局应且仅应生成一个玩家可控英雄")
	_check(not get_tree().get_nodes_in_group("adversary_units").is_empty(), "未生成敌方单位")
	_check(group_1.size() == 1, "先锋英雄应加入独立 Legacy AI Squad 1")
	_check(group_2.is_empty(), "单英雄序章不应建立第二小队")
	_check(group_3.is_empty(), "单英雄序章不应建立第三小队")
	_check(a_match.map.size == Vector2(600, 450), "回声撤离超大灰盒地图尺寸不正确")
	_check(a_match.get_node_or_null("Map/CampaignZones/SignalGate") != null, "灰盒地图缺少 SignalGate")
	_check(a_match.get_node_or_null("Map/CampaignZones/PerimeterCamp") != null, "灰盒地图缺少 PerimeterCamp")
	_check(a_match.get_node_or_null("Map/CampaignZones/AbandonedConvoy") != null, "灰盒地图缺少 AbandonedConvoy")
	_check(a_match.get_node_or_null("Map/CampaignZones/EmergencyExtraction") != null, "灰盒地图缺少 EmergencyExtraction")
	var communication_station = a_match.get_node_or_null("Map/CampaignZones/CommunicationStation")
	var tunnel_extraction = a_match.get_node_or_null("Map/CampaignZones/TunnelExtraction")
	_check(communication_station != null, "超大地图缺少 CommunicationStation")
	_check(tunnel_extraction != null, "超大地图缺少 TunnelExtraction")
	_check(communication_station.position.x > 500.0 and communication_station.position.z > 350.0, "通讯站未被拉到大战区深处")
	_check(tunnel_extraction.position.z > 400.0, "地下撤离点未使用超大地图纵深")

	_check(camera != null, "RTS 镜头未加载")
	_check(camera.edge_scroll_enabled, "功能开关打开后应对局启用边缘滚屏")
	_check(is_equal_approx(camera.movement_speed, 1.7), "镜头移动速度设置未应用")
	_check(is_equal_approx(camera.screen_margin_for_movement, 60.0), "边缘触发范围设置未应用")
	_check(is_equal_approx(camera.bottom_screen_margin_for_movement, 90.0), "底边触发范围设置未应用")
	_check(is_equal_approx(camera.movement_acceleration, 12.0), "镜头平滑度设置未应用")
	_check(is_equal_approx(camera.movement_deceleration, 16.8), "镜头减速平滑度未按设置派生")
	_check(is_equal_approx(camera.zoom_step, 1.5), "滚轮缩放速度设置未应用")

	_check(pause_menu != null, "战斗暂停菜单未加载")
	_check(
		pause_menu.get_node_or_null("CenterContainer/PanelContainer/MarginContainer/VBoxContainer/SettingsButton") != null,
		"战斗暂停菜单缺少设置入口"
	)
	var input_runtime = a_match.get_node("InputBindingRuntime")
	_check(not pause_menu.visible, "开局暂停菜单应关闭")
	input_runtime.emit_signal("ActionPressed", "global.cancel")
	_check(not pause_menu.visible, "Esc 不得打开暂停菜单")
	_check(not get_tree().paused, "Esc 不得把对局打进暂停")
	input_runtime.emit_signal("ActionPressed", "global.toggle_menu")
	_check(pause_menu.visible, "F10 应打开暂停菜单")
	_check(get_tree().paused, "F10 打开菜单后应对局暂停")
	input_runtime.emit_signal("ActionPressed", "global.toggle_menu")
	_check(pause_menu.visible, "菜单已打开时 F10 应保持打开")
	input_runtime.emit_signal("ActionPressed", "global.cancel")
	_check(not pause_menu.visible, "Esc 应从暂停菜单返回对局")
	_check(not get_tree().paused, "Esc 关闭菜单后应对局恢复")
	pause_menu._on_settings_button_pressed()
	await get_tree().process_frame
	_check(pause_menu._options_panel != null, "战斗中未能打开统一设置面板")
	_check(pause_menu._options_panel.embedded_mode, "战斗设置面板未使用嵌入模式")
	Globals.set_camera_option("movement_speed", 2.2)
	pause_menu._options_panel._apply_camera_options_live()
	_check(is_equal_approx(camera.movement_speed, 2.2), "战斗中镜头设置没有即时应用")
	pause_menu._close_options_panel()
	Globals.set_camera_option("movement_speed", 1.7)
	camera._apply_user_camera_options()

	var test_viewport_size := Vector2(1920, 1080)
	var center_scroll = camera._calculate_edge_scroll_vector(Vector2(960, 540), test_viewport_size)
	var left_scroll = camera._calculate_edge_scroll_vector(Vector2(1, 540), test_viewport_size)
	var right_scroll = camera._calculate_edge_scroll_vector(Vector2(1919, 540), test_viewport_size)
	var top_scroll = camera._calculate_edge_scroll_vector(Vector2(960, 1), test_viewport_size)
	var bottom_scroll = camera._calculate_edge_scroll_vector(Vector2(960, 1079), test_viewport_size)
	var bottom_inner_scroll = camera._calculate_edge_scroll_vector(Vector2(960, 1020), test_viewport_size)
	_check(center_scroll.is_zero_approx(), "鼠标位于屏幕中央时镜头不应边缘滚动")
	_check(left_scroll.x < -0.9, "屏幕左边缘滚动方向错误")
	_check(right_scroll.x > 0.9, "屏幕右边缘滚动方向错误")
	_check(top_scroll.y < -0.9, "屏幕上边缘滚动方向错误")
	_check(bottom_scroll.y > 0.9, "屏幕下边缘滚动方向错误")
	_check(bottom_inner_scroll.y > 0.0, "屏幕下方扩展触发区未生效")
	_check(camera.bottom_screen_margin_for_movement > camera.screen_margin_for_movement, "底边触发区应比普通边缘更宽")

	var campaign = a_match.get_node("CampaignController")
	var outcome_runtime = a_match.get_node("MatchOutcomeRuntime")
	var sim_before_pause: int = a_match.get_simulation_msec()
	var mission_elapsed_before: int = campaign.GetMissionElapsedSeconds()
	var hero_before := Vector3.ZERO
	if _hero_of_match(a_match) != null:
		hero_before = _hero_of_match(a_match).global_position
	get_tree().paused = true
	await get_tree().create_timer(0.55, true, true).timeout
	_check(a_match.is_simulation_paused(), "F10 等价的树暂停应冻结战局")
	_check(a_match.get_simulation_msec() == sim_before_pause, "暂停期间战役模拟时钟不得增加")
	_check(
		campaign.GetMissionElapsedSeconds() == mission_elapsed_before,
		"暂停期间战役作战时间不得增加"
	)
	if _hero_of_match(a_match) != null:
		_check(
			_hero_of_match(a_match).global_position.is_equal_approx(hero_before),
			"暂停期间战役英雄不得继续移动"
		)
	get_tree().paused = false
	await get_tree().physics_frame
	await get_tree().physics_frame
	_check(a_match.get_simulation_msec() > sim_before_pause, "恢复后战役模拟时钟应继续推进")
	campaign._on_extract_pressed()
	await get_tree().process_frame
	await get_tree().process_frame
	var outcome: Dictionary = outcome_runtime.InspectOutcome()
	_check(outcome.get("kind", "") == "Won", "请求撤离应锁定 MatchOutcome Won")
	_check(outcome.get("local_result", "") == "Victory", "撤离结算数据源应为 Victory")
	_check(a_match.get_node_or_null("HUD/CampaignResult") == null,
		"默认胜负链路不应再叠战役自建结算层")
	var match_end = a_match.get_node_or_null("Handlers/MatchEndHandler")
	_check(match_end != null and match_end.find_child("Victory").visible,
		"战役胜利应显示统一 Victory")
	var victory_summary = match_end.find_child("CampaignSummary")
	_check(victory_summary != null and victory_summary.visible, "战役胜利应显示统一任务结果")
	_check("任务结果：成功" in victory_summary.text, "胜利结算文案必须来自 Outcome 成功")
	_check("Won" in victory_summary.text and "Victory" in victory_summary.text,
		"胜利结算必须写出权威终态")
	_check(outcome_runtime.IsOutcomeLocked(), "撤离后应对局结果已锁定")
	var locked_version = outcome.get("version", -1)
	campaign._on_extract_pressed()
	var still_alive_heroes = get_tree().get_nodes_in_group("campaign_hero").filter(
		func(unit): return a_match.is_ancestor_of(unit)
	)
	if not still_alive_heroes.is_empty():
		campaign._on_unit_died(still_alive_heroes[0])
	var after_lock: Dictionary = outcome_runtime.InspectOutcome()
	_check(after_lock.get("version", -2) == locked_version, "锁定后再次撤离或阵亡不得改写版本")
	_check(after_lock.get("kind", "") == "Won", "锁定后 kind 必须保持")
	_check(outcome.get("local_human_side_id", "") in after_lock.get("winning_side_ids", []),
		"锁定后不得把胜方改成敌方")
	_check(a_match.get_node_or_null("HUD/CampaignResult") == null,
		"锁定后不得再叠战役结算层")
	_check(match_end.find_child("Victory").visible, "锁定后 Victory 必须保持")
	_check(not match_end.find_child("Defeat").visible, "锁定后不得改出 Defeat")
	_check(victory_summary.text.count("任务结果：") == 1, "锁定后不得追加第二份任务结果")
	var restart_button = match_end.find_child("RestartButton")
	_check(restart_button != null and restart_button.visible, "战役结算应提供重开本关")
	_check(match_end.find_child("ExitButton").text == "返回单人战役", "战役结算离开应返回战役界面")
	get_tree().paused = false
	restart_button.pressed.emit()
	var restarted = await _wait_for_campaign_match(a_match)
	_check(restarted != null, "重开本关应加载新的战役对局")
	if restarted != null:
		var restarted_outcome: Dictionary = restarted.get_node("MatchOutcomeRuntime").InspectOutcome()
		_check(restarted_outcome.get("kind", "") == "InProgress", "重开后不得沿用已锁定终局")
		_check(not restarted.get_node("MatchOutcomeRuntime").IsOutcomeLocked(),
			"重开后 IsOutcomeLocked 应为假")
		_check(restarted.get_node_or_null("CampaignController") != null, "重开后应有新的战役控制器")
		_check(not restarted.get_node("Handlers/MatchEndHandler").visible,
			"重开后结算面板应关闭")
		restarted.queue_free()
	elif is_instance_valid(a_match):
		a_match.queue_free()
	await get_tree().process_frame
	await get_tree().process_frame

	if _failures.is_empty():
		print("CAMPAIGN_SMOKE_TEST_OK: 回声撤离 600x450 超大地图、单英雄和全局设置入口均已验证")
	else:
		printerr("CAMPAIGN_SMOKE_TEST_FAILED: %d assertion(s) failed" % _failures.size())
	await _verify_hero_death_enters_defeat()
	SmokeTestExit.request(get_tree(), 0 if _failures.is_empty() else 1)


func _verify_hero_death_enters_defeat():
	var mission := CampaignMission.echo_extraction()
	var settings := MatchSettings.new()
	var human := PlayerSettings.new()
	human.controller = Constants.PlayerType.HUMAN
	human.color = Constants.Player.COLORS[0]
	settings.players.append(human)
	var enemy := PlayerSettings.new()
	enemy.controller = Constants.PlayerType.SIMPLE_CLAIRVOYANT_AI
	enemy.color = Constants.Player.COLORS[1]
	settings.players.append(enemy)
	settings.visible_player = 0
	settings.visibility = MatchSettings.Visibility.PER_PLAYER
	var campaign_map = load(mission["map_path"]).instantiate()
	var a_match = load("res://source/match/Match.tscn").instantiate()
	a_match.settings = settings
	a_match.map = campaign_map
	a_match.campaign_data = mission
	get_tree().root.add_child(a_match)
	for _frame in range(8):
		await get_tree().process_frame
		await get_tree().physics_frame
	var heroes = get_tree().get_nodes_in_group("campaign_hero").filter(
		func(unit): return a_match.is_ancestor_of(unit)
	)
	_check(not heroes.is_empty(), "失败链路应找到战役英雄")
	if not heroes.is_empty():
		heroes[0].call("_handle_unit_death")
	await get_tree().process_frame
	await get_tree().process_frame
	var outcome: Dictionary = a_match.get_node("MatchOutcomeRuntime").InspectOutcome()
	_check(outcome.get("kind", "") == "Won", "英雄死亡应锁定 MatchOutcome 终局")
	_check(outcome.get("local_result", "") == "Defeat", "英雄死亡结算数据源应为 Defeat")
	_check(not outcome.get("local_human_side_id", "") in outcome.get("winning_side_ids", []),
		"英雄死亡后本机不得列为胜方")
	_check(a_match.get_node_or_null("HUD/CampaignResult") == null,
		"默认失败链路不应叠战役自建结算层")
	var match_end = a_match.get_node_or_null("Handlers/MatchEndHandler")
	_check(match_end != null and match_end.find_child("Defeat").visible,
		"战役失败应显示统一 Defeat")
	var defeat_summary = match_end.find_child("CampaignSummary")
	_check(defeat_summary != null and defeat_summary.visible, "战役失败应显示统一任务结果")
	_check("任务结果：失败" in defeat_summary.text, "失败结算文案必须来自 Outcome 失败")
	var defeat_runtime = a_match.get_node("MatchOutcomeRuntime")
	_check(defeat_runtime.IsOutcomeLocked(), "英雄死亡后应对局结果已锁定")
	var defeat_version = outcome.get("version", -1)
	a_match.get_node("CampaignController")._on_extract_pressed()
	var after_defeat: Dictionary = defeat_runtime.InspectOutcome()
	_check(after_defeat.get("version", -2) == defeat_version, "失败锁定后撤离不得改写版本")
	_check(not after_defeat.get("local_human_side_id", "") in after_defeat.get("winning_side_ids", []),
		"失败锁定后撤离不得改成胜利")
	_check(a_match.get_node_or_null("HUD/CampaignResult") == null,
		"失败锁定后不得再叠战役结算层")
	_check(match_end.find_child("Defeat").visible, "失败锁定后 Defeat 必须保持")
	_check(not match_end.find_child("Victory").visible, "失败锁定后不得改出 Victory")
	_check(match_end.find_child("RestartButton").visible, "失败结算也应提供重开本关")
	get_tree().paused = false
	a_match.queue_free()
	await get_tree().process_frame
	await get_tree().process_frame


func _hero_of_match(a_match: Node) -> Node3D:
	var heroes = get_tree().get_nodes_in_group("campaign_hero").filter(
		func(unit): return a_match.is_ancestor_of(unit) and unit is Node3D
	)
	if heroes.is_empty():
		return null
	return heroes[0]


func _wait_for_campaign_match(previous_match: Node) -> Node:
	for _frame in range(80):
		await get_tree().process_frame
		await get_tree().physics_frame
		var scene = get_tree().current_scene
		if (
			scene != null
			and scene != previous_match
			and scene.get_node_or_null("CampaignController") != null
			and scene.get_node_or_null("MatchOutcomeRuntime") != null
		):
			for _settle in range(8):
				await get_tree().process_frame
				await get_tree().physics_frame
			return scene
	return null


func _check(condition: bool, message: String):
	if condition:
		return
	_failures.append(message)
	printerr("ASSERTION_FAILED: %s" % message)


func _verify_menu_settings_entry_points():
	var campaign_menu = load("res://source/campaign/CampaignMenu.tscn").instantiate()
	get_tree().root.add_child(campaign_menu)
	await get_tree().process_frame
	_check(campaign_menu.find_child("SettingsButton", true, false) != null, "单人战役界面缺少设置入口")
	campaign_menu._on_settings_pressed()
	await get_tree().process_frame
	_check(campaign_menu._options_panel != null, "单人战役界面未能打开统一设置面板")
	_check(campaign_menu._options_panel.embedded_mode, "单人战役设置面板未使用嵌入模式")
	campaign_menu._close_options_panel()
	campaign_menu.queue_free()
	await get_tree().process_frame

	var play_menu = load("res://source/main-menu/Play.tscn").instantiate()
	get_tree().root.add_child(play_menu)
	await get_tree().process_frame
	_check(play_menu.find_child("SettingsButton", true, false) != null, "自定义战斗配置页缺少设置入口")
	play_menu._open_options_panel()
	await get_tree().process_frame
	_check(play_menu._options_panel != null, "自定义战斗配置页未能打开统一设置面板")
	_check(play_menu._options_panel.embedded_mode, "自定义战斗设置面板未使用嵌入模式")
	play_menu._close_options_panel()
	play_menu.queue_free()
	await get_tree().process_frame
