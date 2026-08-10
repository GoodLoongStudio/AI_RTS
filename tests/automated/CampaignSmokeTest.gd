extends Node

const MatchSettings = preload("res://source/data-model/MatchSettings.gd")
const PlayerSettings = preload("res://source/data-model/PlayerSettings.gd")
const CampaignMission = preload("res://source/campaign/CampaignMission.gd")


func _ready():
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

	var map = load(mission["map_path"]).instantiate()
	var a_match = load("res://source/match/Match.tscn").instantiate()
	a_match.settings = settings
	a_match.map = map
	a_match.campaign_data = mission
	get_tree().root.add_child(a_match)

	for _frame in range(10):
		await get_tree().process_frame
		await get_tree().physics_frame

	assert(a_match.get_node_or_null("CampaignController") != null, "CampaignController 未加载")
	assert(a_match.get_node_or_null("HUD/AICommandHUD") != null, "AICommandHUD 未加载")
	assert(not get_tree().get_nodes_in_group("controlled_units").is_empty(), "未生成玩家可控单位")
	assert(not get_tree().get_nodes_in_group("adversary_units").is_empty(), "未生成敌方单位")
	assert(not get_tree().get_nodes_in_group("unit_group_1").is_empty(), "突击一队未自动编组")
	assert(not get_tree().get_nodes_in_group("unit_group_2").is_empty(), "侦察二队未自动编组")
	assert(not get_tree().get_nodes_in_group("unit_group_3").is_empty(), "支援三队未自动编组")

	print("CAMPAIGN_SMOKE_TEST_OK: 回声撤离战役 Match 已启动，HUD/Controller/三支小队均存在")
	a_match.queue_free()
	await get_tree().process_frame
	await get_tree().process_frame
	get_tree().quit(0)
