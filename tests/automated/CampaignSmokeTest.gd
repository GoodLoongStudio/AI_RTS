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
	var group_1 = get_tree().get_nodes_in_group("unit_group_1")
	var group_2 = get_tree().get_nodes_in_group("unit_group_2")
	var group_3 = get_tree().get_nodes_in_group("unit_group_3")
	var ai_hud = a_match.get_node_or_null("HUD/AICommandHUD")
	var camera = a_match.get_node_or_null("IsometricCamera3D")
	var pause_menu = a_match.get_node_or_null("Menu")

	_check(a_match.get_node_or_null("CampaignController") != null, "CampaignController 未加载")
	_check(ai_hud != null, "AICommandHUD 未加载")
	_check(ai_hud.control_mode == "hero", "AICommandHUD 未进入单英雄模式")
	_check(controlled_units.size() == 1, "序章开局应且仅应生成一个玩家可控英雄")
	_check(not get_tree().get_nodes_in_group("adversary_units").is_empty(), "未生成敌方单位")
	_check(group_1.size() == 1, "先锋英雄应加入 unit_group_1")
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
	_check(camera.edge_scroll_enabled, "边缘滚屏设置未应用")
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

	if _failures.is_empty():
		print("CAMPAIGN_SMOKE_TEST_OK: 回声撤离 600x450 超大地图、单英雄和全局设置入口均已验证")
	else:
		printerr("CAMPAIGN_SMOKE_TEST_FAILED: %d assertion(s) failed" % _failures.size())
	a_match.queue_free()
	await get_tree().process_frame
	await get_tree().process_frame
	get_tree().quit(0 if _failures.is_empty() else 1)


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
