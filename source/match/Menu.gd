extends CanvasLayer

const OptionsScene = preload("res://source/main-menu/Options.tscn")
const EscapeRouter = preload("res://source/ui/EscapeRouter.gd")

var _options_panel: Control = null


func _ready():
	hide()
	get_parent().get_node("InputBindingRuntime").connect("ActionPressed", _on_input_action_pressed)


func _on_input_action_pressed(action_id: String):
	if action_id == "global.toggle_menu":
		_open()
		return
	if action_id == "global.cancel":
		# 面板/菜单已打开：同步逐级返回（不依赖他人认领）。
		if _options_panel != null or visible:
			_cancel_or_return()
			return
		# 菜单未打开：本帧末尾再决定是否唤出。放置/目标选择/待发命令等
		# "取消"消费者会先同步认领 ESC（EscapeRouter.claim()）；
		# 无人认领时 ESC 与 F10 等价——唤出暂停菜单（2026-09-14 用户要求）。
		_open_if_unclaimed.call_deferred()


## 本帧末尾的兜底唤出：只有无人认领 ESC 时才打开菜单。
func _open_if_unclaimed():
	if visible:
		return
	if EscapeRouter.is_claimed_this_frame():
		return
	_open()


func _open():
	if visible:
		return
	visible = true
	get_tree().paused = true
	# 联机对局无法真正暂停（服务器继续推进战局）：在标题上明确告知玩家，
	# 避免误以为"暂停了就是安全的"（2026-09-14）。
	var title = $CenterContainer/PanelContainer/MarginContainer/VBoxContainer/Title
	if title != null:
		title.text = (
			"菜单（联机中，战斗仍在继续）"
			if NetSession.should_forward_commands()
			else "游戏暂停"
		)


func _close():
	if _options_panel != null:
		_close_options_panel()
	if not visible:
		return
	visible = false
	get_tree().paused = false


func _cancel_or_return():
	if _options_panel != null:
		_close_options_panel()
		return
	if visible:
		_close()


func _on_resume_button_pressed():
	_close()


func _on_settings_button_pressed():
	if _options_panel != null:
		return
	$CenterContainer.hide()
	_options_panel = OptionsScene.instantiate()
	_options_panel.embedded_mode = true
	_options_panel.close_requested.connect(_close_options_panel)
	add_child(_options_panel)


func _close_options_panel():
	if _options_panel == null:
		return
	_options_panel.queue_free()
	_options_panel = null
	$CenterContainer.show()
	_apply_camera_settings_to_active_match()


func _apply_camera_settings_to_active_match():
	var match_root = get_parent()
	if match_root == null:
		return
	var camera = match_root.get_node_or_null("IsometricCamera3D")
	if camera != null and camera.has_method("_apply_user_camera_options"):
		camera.call("_apply_user_camera_options")


func _on_exit_button_pressed():
	MatchSignals.match_aborted.emit()
	await get_tree().create_timer(1.74).timeout  # Give voice narrator some time to finish.
	get_tree().paused = false
	# 退出战斗必须**断开会话**（单机 listen server / 联机房间），否则残留状态会让
	# 「在线匹配」误判"已连接/房主"（单机）或让下一局被服务器忽略（联机）——2026-09-14。
	NetSession.disconnect_if_networked()
	get_tree().change_scene_to_file("res://source/main-menu/Main.tscn")
