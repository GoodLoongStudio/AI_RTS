extends CanvasLayer

const OptionsScene = preload("res://source/main-menu/Options.tscn")

var _options_panel: Control = null


func _ready():
	hide()


func _unhandled_input(event):
	if not event.is_action_pressed("toggle_match_menu"):
		return

	if _options_panel != null:
		_close_options_panel()
		get_viewport().set_input_as_handled()
		return

	if ((not visible and not get_tree().paused) or (visible and get_tree().paused)):
		_toggle()
		get_viewport().set_input_as_handled()


func _toggle():
	visible = not visible
	get_tree().paused = visible


func _on_resume_button_pressed():
	_toggle()


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
	get_tree().change_scene_to_file("res://source/main-menu/Main.tscn")
