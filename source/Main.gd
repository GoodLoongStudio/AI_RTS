extends Control

@onready var _logos = find_child("Logos")


func _ready():
	if NetSession.try_start_from_cmdline():
		if _logos != null:
			_logos.queue_free()
		var status := Label.new()
		status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		status.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		status.set_anchors_preset(Control.PRESET_FULL_RECT)
		status.text = NetSession.get_status()
		NetSession.status_changed.connect(func(text): status.text = text)
		add_child(status)
		return
	_logos.tree_exited.connect(
		get_tree().change_scene_to_file.bind("res://source/main-menu/Main.tscn")
	)
