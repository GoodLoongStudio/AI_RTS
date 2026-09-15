extends Control

@onready var _logos = find_child("Logos")


func _ready():
	# 独立运行时默认贴靠屏幕左侧，占用一半宽度，给 Codex/日志窗口
	# 留出右侧空间；嵌入 Godot 编辑器时这些调用由引擎忽略。
	var play_map := _play_map_from_cmdline()
	if play_map != "":
		if _logos != null:
			_logos.queue_free()
		call_deferred("_start_local_playtest", play_map)
		return
	if NetSession.try_start_from_cmdline():
		if _logos != null:
			_logos.queue_free()
		var status := Label.new()
		status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		status.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		status.set_anchors_preset(Control.PRESET_FULL_RECT)
		status.text = NetSession.get_status()
		# 用对象方法的 Callable，而不是闭包：闭包捕获的标签被释放后，emit 会报
		# "Lambda capture at index 0 was freed"（2026-09-10 服务器因客户端断线崩溃的根因）；
		# 对象方法 Callable 在对象销毁时自动断开连接。
		NetSession.status_changed.connect(status.set_text)
		add_child(status)
		return
	_logos.tree_exited.connect(
		get_tree().change_scene_to_file.bind("res://source/main-menu/Main.tscn")
	)


func _play_map_from_cmdline() -> String:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--play-map="):
			return arg.substr(11)
	return ""


func _playtest_host_port() -> int:
	var args := OS.get_cmdline_user_args()
	var port_index := args.find("--port")
	if port_index >= 0 and port_index + 1 < args.size():
		return int(args[port_index + 1])
	# 评图开房不要占用玩家局服 24567 / 24571。
	return 24691


func _start_local_playtest(map_path: String) -> void:
	if _logos != null:
		_logos.queue_free()
	NetSession.clear_auto_start_intent()
	var err := NetSession.host(_playtest_host_port())
	if err != OK:
		push_error("评图开房失败（端口可能被占用）：%s" % err)
		get_tree().change_scene_to_file("res://source/main-menu/Main.tscn")
		return
	var MatchSettings = load("res://source/data-model/MatchSettings.gd")
	var PlayerSettings = load("res://source/data-model/PlayerSettings.gd")
	var LoadingScene = load("res://source/main-menu/Loading.tscn")
	var match_settings = MatchSettings.new()
	# 评图/对局默认开战争迷雾。只有显式 `--no-fog` 才整图敞亮。
	# `--play-fog` 保留给旧脚本，语义与默认相同。
	if OS.get_cmdline_user_args().has("--no-fog"):
		match_settings.visibility = match_settings.Visibility.FULL
	else:
		match_settings.visibility = match_settings.Visibility.PER_PLAYER
	match_settings.visible_player = 0
	match_settings.local_player_index = 0
	var human = PlayerSettings.new()
	human.controller = Constants.PlayerType.HUMAN
	human.color = Constants.Player.COLORS[0]
	var ai = PlayerSettings.new()
	ai.controller = Constants.PlayerType.SIMPLE_CLAIRVOYANT_AI
	ai.color = Constants.Player.COLORS[1]
	match_settings.players.append(human)
	match_settings.players.append(ai)
	var loading = LoadingScene.instantiate()
	loading.match_settings = match_settings
	loading.map_path = map_path
	var tree := get_tree()
	tree.root.add_child(loading)
	tree.current_scene = loading
	queue_free()


