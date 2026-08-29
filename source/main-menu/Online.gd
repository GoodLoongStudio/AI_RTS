extends Control

@onready var _host_edit: LineEdit = $PanelContainer/MarginContainer/VBoxContainer/HostRow/HostEdit
@onready var _port_edit: LineEdit = $PanelContainer/MarginContainer/VBoxContainer/HostRow/PortEdit
@onready var _status_label: Label = $PanelContainer/MarginContainer/VBoxContainer/StatusLabel
@onready var _ready_button: Button = $PanelContainer/MarginContainer/VBoxContainer/ReadyButton


func _ready() -> void:
	_host_edit.text = NetSession.DEFAULT_HOST
	_port_edit.text = str(NetSession.DEFAULT_PORT)
	_status_label.text = NetSession.get_status()
	NetSession.status_changed.connect(_on_status_changed)


func _exit_tree() -> void:
	if NetSession.status_changed.is_connected(_on_status_changed):
		NetSession.status_changed.disconnect(_on_status_changed)


func _on_status_changed(text: String) -> void:
	_status_label.text = text


func _port() -> int:
	return int(_port_edit.text)


func _on_join_button_pressed() -> void:
	var err := NetSession.join(_host_edit.text.strip_edges(), _port())
	if err != OK:
		_status_label.text = "连接失败：%s" % err


func _on_listen_button_pressed() -> void:
	var err := NetSession.host(_port())
	if err != OK:
		_status_label.text = "开房失败：%s（端口被占用？）" % err


func _on_ready_button_pressed() -> void:
	NetSession.set_ready(true)
	_ready_button.text = "已准备"


func _on_back_button_pressed() -> void:
	if NetSession.is_networked() and not NetSession.is_dedicated_server():
		NetSession.disconnect_session()
	get_tree().change_scene_to_file("res://source/main-menu/Main.tscn")
