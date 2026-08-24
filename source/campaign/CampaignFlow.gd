extends RefCounted

const MatchSettings = preload("res://source/data-model/MatchSettings.gd")
const PlayerSettings = preload("res://source/data-model/PlayerSettings.gd")
const LoadingScene = preload("res://source/main-menu/Loading.tscn")


static func create_default_settings() -> MatchSettings:
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
	return settings


static func start_mission(tree: SceneTree, mission: Dictionary, scene_to_free: Node = null) -> void:
	if tree == null or mission.is_empty():
		return
	tree.paused = false
	var loading = LoadingScene.instantiate()
	loading.match_settings = create_default_settings()
	loading.map_path = mission.get("map_path", "")
	loading.campaign_data = mission
	tree.root.add_child(loading)
	tree.current_scene = loading
	if scene_to_free != null and is_instance_valid(scene_to_free):
		scene_to_free.queue_free()


static func restart_from_match(tree: SceneTree, match_root: Node) -> bool:
	if match_root == null or not is_instance_valid(match_root):
		return false
	var mission = match_root.get("campaign_data")
	if typeof(mission) != TYPE_DICTIONARY or mission.is_empty():
		return false
	start_mission(tree, mission, match_root)
	return true


static func return_to_campaign_menu(tree: SceneTree) -> void:
	if tree == null:
		return
	tree.paused = false
	tree.change_scene_to_file("res://source/campaign/CampaignMenu.tscn")
