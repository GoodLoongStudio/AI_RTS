extends Node

const MatchSettings = preload("res://source/data-model/MatchSettings.gd")
const PlayerSettings = preload("res://source/data-model/PlayerSettings.gd")
const CampaignMission = preload("res://source/campaign/CampaignMission.gd")


func _ready():
	await get_tree().process_frame
	await _run_test()


func _run_test():
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

	assert(a_match.get_node_or_null("CampaignController") != null, "CampaignController 未加载")
	assert(ai_hud != null, "AICommandHUD 未加载")
	assert(ai_hud.control_mode == "hero", "AICommandHUD 未进入单英雄模式")
	assert(controlled_units.size() == 1, "序章开局应且仅应生成一个玩家可控英雄")
	assert(not get_tree().get_nodes_in_group("adversary_units").is_empty(), "未生成敌方单位")
	assert(group_1.size() == 1, "先锋英雄应加入 unit_group_1")
	assert(group_2.is_empty(), "单英雄序章不应建立第二小队")
	assert(group_3.is_empty(), "单英雄序章不应建立第三小队")
	assert(a_match.map.size == Vector2(150, 110), "回声撤离灰盒地图尺寸不正确")
	assert(a_match.get_node_or_null("Map/CampaignZones/SignalGate") != null, "灰盒地图缺少 SignalGate")
	assert(a_match.get_node_or_null("Map/CampaignZones/PerimeterCamp") != null, "灰盒地图缺少 PerimeterCamp")
	assert(a_match.get_node_or_null("Map/CampaignZones/AbandonedConvoy") != null, "灰盒地图缺少 AbandonedConvoy")
	assert(a_match.get_node_or_null("Map/CampaignZones/EmergencyExtraction") != null, "灰盒地图缺少 EmergencyExtraction")

	print("CAMPAIGN_SMOKE_TEST_OK: 回声撤离灰盒地图已启动，单英雄/AI HUD/剧情控制器/关键区域均存在")
	a_match.queue_free()
	await get_tree().process_frame
	await get_tree().process_frame
	get_tree().quit(0)
