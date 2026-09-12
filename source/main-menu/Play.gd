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
	# 防御性 viewport 适配：菜单面板被 CenterContainer 居中，但若 viewport 极端窄/矮
	# （如窗口被手动缩很小），custom_minimum_size 写死的宽高仍会越过 viewport 边界，
	# 导致顶部/底部被裁。clamp 到 viewport - margin 让 panel 永远在屏内。
	_clamp_to_viewport()
	get_viewport().size_changed.connect(_clamp_to_viewport)


## 把 panel 的 custom_minimum_size clamp 到 viewport - margin。
## 配合 CenterContainer + PanelContainer(clip_contents=true) + ScrollContainer：
## - viewport 够大：panel 用 .tscn 写死的最小尺寸，居中显示
## - viewport 太小：panel 缩到 viewport - 边距，超出内容靠 ScrollContainer 滚动
func _clamp_to_viewport() -> void:
	var panel := get_node_or_null("CenterContainer/PanelContainer")
	if panel == null:
		return
	var viewport_rect := get_viewport().get_visible_rect()
	var margin := 40.0
	var max_w := maxf(360.0, viewport_rect.size.x - margin * 2.0)
	var max_h := maxf(360.0, viewport_rect.size.y - margin * 2.0)
	var cur: Vector2 = panel.custom_minimum_size
	panel.custom_minimum_size = Vector2(minf(cur.x, max_w), minf(cur.y, max_h))


func _unhandled_input(event: InputEvent):
	if event.is_action_pressed("toggle_match_menu") and _options_panel != null:
		_close_options_panel()
		get_viewport().set_input_as_handled()


func _setup_settings_button():
	var button_box = $CenterContainer/PanelContainer/MarginContainer/ScrollContainer/VBoxContainer/VBoxContainer
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
	# ALL_MAPS = 静态登记 + 工作台生成地图动态发现（见 MatchConstants.gd）
	var maps = Utils.Dict.items(Constants.Match.ALL_MAPS)
	maps.sort_custom(func(map_a, map_b): return map_a[1]["players"] < map_b[1]["players"])
	_map_paths = maps.map(func(map): return map[0])
	_map_list.clear()
	for map_path in _map_paths:
		_map_list.add_item(Constants.Match.ALL_MAPS[map_path]["name"])
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
	# 【模式隔离】自定义对局 = 本机开房（本机即服即玩）。
	# 此前这里没有任何网络初始化：NetSession 是 autoload 全局单例，一旦玩家先玩过
	# 联机 demo（_peer = 连着服务器），进入自定义对局时 _peer 原封不动 →
	# 新局自以为仍在联机、命令被转发到服务器 → 表现为"自定义局和联机局混在一起"。
	# host() 内部第一步就是 _reset_peer()，因此顺带清掉残留连接，一举两得。
	NetSession.clear_auto_start_intent()
	var err := NetSession.host()
	if err != OK:
		push_error("自定义对局本机开房失败（端口 %d 可能被占用）：%s"
			% [NetSession.DEFAULT_PORT, err])
		show()
		return
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
	var map = Constants.Match.ALL_MAPS[_map_paths[index]]
	_map_details.text = "[u]Players:[/u] {0}\n[u]Size:[/u] {1}x{2}".format(
		[map["players"], map["size"].x, map["size"].y]
	)
	_align_player_controls_visibility_to_map(map)
