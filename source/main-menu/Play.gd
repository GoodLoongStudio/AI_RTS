extends "res://source/main-menu/MatchSetupPage.gd"

## 单机模式页（统一大厅布局的 offline 实例，共享布局见 MatchSetupPage.tscn/.gd）。
##
## 与在线匹配同一套视觉与结构，但：
##   - 默认本机房主（不需要连接/昵称/准备流程）；
##   - 隐藏服务器地址、端口、连接状态、准备按钮等在线控件；
##   - 玩家槽位用下拉选 指挥官 / 简单 AI / 中等 AI / 困难 AI / 空位；
##   - 开始 = NetSession.host()（本机开房）+ 原 Loading.tscn 单机开局链路。
##
## 注：ESC 回退与设置面板管线（_on_escape / _open_options_panel / _options_panel）
## 由共享基类提供，EscReturnSmokeTest 依赖该契约，勿删。


## 旧 Play 页的玩家设置组装（改用槽位卡片中的下拉，语义不变）。
func _create_match_settings():
	var match_settings = MatchSettings.new()
	var spawn_index_offset := 0
	for i in range(_slot_selects.size()):
		var player_controller: int = _slot_controller_id(_slot_selects[i])
		if player_controller != Constants.PlayerType.NONE:
			var player_settings = PlayerSettings.new()
			player_settings.controller = player_controller
			player_settings.difficulty = Constants.rule_ai_difficulty(player_controller)
			player_settings.color = Constants.Player.COLORS[i]
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


func _on_start_button_pressed() -> void:
	_begin_offline_match(_random_map_mode)


func _on_random_match_requested() -> void:
	_set_random_map_mode(true)


func _begin_offline_match(random_map: bool) -> void:
	# 【模式隔离】自定义对局 = 本机开房（本机即服即玩）。
	# NetSession 是 autoload 全局单例，一旦玩家先玩过联机（_peer 连着服务器），
	# 进入自定义对局时 _peer 原封不动 → 新局自以为仍在联机、命令被转发到服务器
	# → 表现为"自定义局和联机局混在一起"。host() 内部第一步就是 _reset_peer()，
	# 因此顺带清掉残留连接，一举两得。
	NetSession.clear_auto_start_intent()
	var port := _local_host_port()
	var err := NetSession.host(port)
	if err != OK:
		push_error("自定义对局本机开房失败（端口 %d 可能被占用）：%s" % [port, err])
		show()
		return
	hide()
	var new_scene = LoadingScene.instantiate()
	new_scene.match_settings = _create_match_settings()
	new_scene.generate_random_map = random_map
	new_scene.map_path = selected_map_path()
	if not random_map:
		NetSession.selected_map_path = str(new_scene.map_path)
	get_parent().add_child(new_scene)
	get_tree().current_scene = new_scene
	queue_free()


## 本机开房端口：--port N 优先（供自动化验收隔离端口），默认与云端同款端口。
func _local_host_port() -> int:
	var args := OS.get_cmdline_user_args()
	var index := args.find("--port")
	if index >= 0 and index + 1 < args.size() and str(args[index + 1]).is_valid_int():
		return int(args[index + 1])
	return NetSession.DEFAULT_PORT
