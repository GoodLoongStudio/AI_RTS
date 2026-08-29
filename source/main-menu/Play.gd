extends Control

const MatchSettings = preload("res://source/data-model/MatchSettings.gd")
const PlayerSettings = preload("res://source/data-model/PlayerSettings.gd")
const LoadingScene = preload("res://source/main-menu/Loading.tscn")
const OptionsScene = preload("res://source/main-menu/Options.tscn")

var _map_paths = []
var _options_panel: Control = null

@onready var _start_button = find_child("StartButton")
@onready var _map_list = find_child("MapList")
@onready var _map_details = find_child("MapDetailsLabel")


func _ready():
	_setup_map_list()
	_on_map_list_item_selected(0)
	_setup_settings_button()
	var option_nodes = find_child("GridContainer").find_children("OptionButton*")
	for option_node_id in range(option_nodes.size()):
		option_nodes[option_node_id].item_selected.connect(_on_player_selected.bind(option_node_id))


func _unhandled_input(event: InputEvent):
	if event.is_action_pressed("toggle_match_menu") and _options_panel != null:
		_close_options_panel()
		get_viewport().set_input_as_handled()


func _setup_settings_button():
	var button_box = $PanelContainer/MarginContainer/VBoxContainer/VBoxContainer
	var settings_button := Button.new()
	settings_button.name = "SettingsButton"
	settings_button.text = "设置"
	settings_button.custom_minimum_size = Vector2(0, 44)
	settings_button.pressed.connect(_open_options_panel)
	button_box.add_child(settings_button)
	button_box.move_child(settings_button, 1)


func _open_options_panel():
	if _options_panel != null:
		return
	_options_panel = OptionsScene.instantiate()
	_options_panel.embedded_mode = true
	_options_panel.close_requested.connect(_close_options_panel)
	add_child(_options_panel)


func _close_options_panel():
	if _options_panel == null:
		return
	_options_panel.queue_free()
	_options_panel = null


func _setup_map_list():
	var maps = Utils.Dict.items(Constants.Match.MAPS)
	maps.sort_custom(func(map_a, map_b): return map_a[1]["players"] < map_b[1]["players"])
	_map_paths = maps.map(func(map): return map[0])
	_map_list.clear()
	for map_path in _map_paths:
		_map_list.add_item(Constants.Match.MAPS[map_path]["name"])
	_map_list.select(0)


func _create_match_settings():
	var match_settings = MatchSettings.new()

	var option_nodes = find_child("GridContainer").find_children("OptionButton*")
	var spawn_index_offset = 0
	for option_node_id in range(option_nodes.size()):
		var player_controller = option_nodes[option_node_id].selected
		if player_controller != Constants.PlayerType.NONE:
			var player_settings = PlayerSettings.new()
			player_settings.controller = player_controller
			player_settings.color = Constants.Player.COLORS[option_node_id]
			player_settings.spawn_index_offset = spawn_index_offset
			match_settings.players.append(player_settings)
			spawn_index_offset = 0
		else:
			spawn_index_offset += 1

	match_settings.visible_player = -1
	for player_id in range(match_settings.players.size()):
		var player = match_settings.players[player_id]
		if player.controller == Constants.PlayerType.HUMAN:
			match_settings.visible_player = player_id
	if match_settings.visible_player >= 0:
		match_settings.local_player_index = match_settings.visible_player
	if match_settings.visible_player == -1:
		match_settings.visibility = match_settings.Visibility.ALL_PLAYERS

	return match_settings


func _get_selected_map_path():
	return _map_paths[_map_list.get_selected_items()[0]]


func _on_start_button_pressed():
	hide()
	var new_scene = LoadingScene.instantiate()
	new_scene.match_settings = _create_match_settings()
	new_scene.map_path = _get_selected_map_path()
	get_parent().add_child(new_scene)
	get_tree().current_scene = new_scene
	queue_free()


func _on_back_button_pressed():
	get_tree().change_scene_to_file("res://source/main-menu/Main.tscn")


func _align_player_controls_visibility_to_map(map):
	var option_nodes = find_child("GridContainer").find_children("OptionButton*")
	var label_nodes = find_child("GridContainer").find_children("Label*")
	assert(option_nodes.size() == label_nodes.size())
	for node_id in range(option_nodes.size()):
		option_nodes[node_id].visible = node_id < map["players"]
		label_nodes[node_id].visible = node_id < map["players"]


func _on_player_selected(selected_option_id, selected_player_id):
	_start_button.disabled = false
	if selected_option_id == Constants.PlayerType.HUMAN:
		var option_nodes = find_child("GridContainer").find_children("OptionButton*")
		for option_node_id in range(option_nodes.size()):
			if (
				option_node_id != selected_player_id
				and option_nodes[option_node_id].selected == Constants.PlayerType.HUMAN
			):
				option_nodes[option_node_id].selected = (Constants.PlayerType.SIMPLE_CLAIRVOYANT_AI)
	elif selected_option_id == Constants.PlayerType.NONE:
		var option_buttons = find_child("GridContainer").find_children("OptionButton*")
		var option_nodes_with_player_controllers = option_buttons.filter(
			func(option_node): return option_node.selected != Constants.PlayerType.NONE
		)
		if option_nodes_with_player_controllers.size() < 2:
			_start_button.disabled = true


func _on_map_list_item_selected(index):
	var map = Constants.Match.MAPS[_map_paths[index]]
	_map_details.text = "[u]Players:[/u] {0}\n[u]Size:[/u] {1}x{2}".format(
		[map["players"], map["size"].x, map["size"].y]
	)
	_align_player_controls_visibility_to_map(map)
