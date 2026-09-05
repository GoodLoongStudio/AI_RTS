extends Control

## RA3 式联机大厅：左侧 4 个玩家槽位（颜色/昵称/准备状态，房主可加撤 AI），
## 右侧地图卡，顶部昵称，底部连接与开局按钮。槽位状态由服务器全量广播。

const SLOT_EMPTY := 0
const SLOT_HUMAN := 1
const SLOT_AI := 2

@onready var _host_edit: LineEdit = $PanelContainer/MarginContainer/VBoxContainer/HostRow/HostEdit
@onready var _port_edit: LineEdit = $PanelContainer/MarginContainer/VBoxContainer/HostRow/PortEdit
@onready var _status_label: Label = $PanelContainer/MarginContainer/VBoxContainer/StatusLabel
@onready var _ready_button: Button = $PanelContainer/MarginContainer/VBoxContainer/ReadyRow/ReadyButton
@onready var _solo_button: Button = $PanelContainer/MarginContainer/VBoxContainer/ReadyRow/SoloButton
@onready var _join_button: Button = $PanelContainer/MarginContainer/VBoxContainer/JoinRow/JoinButton
@onready var _name_edit: LineEdit = $PanelContainer/MarginContainer/VBoxContainer/TitleRow/NameRow/NameEdit
@onready var _slots_box: VBoxContainer = $PanelContainer/MarginContainer/VBoxContainer/MainRow/SlotsBox

var _slot_rows: Array = []


func _ready() -> void:
	_host_edit.text = NetSession.DEFAULT_HOST
	_port_edit.text = str(NetSession.DEFAULT_PORT)
	_name_edit.text = NetSession.local_player_name
	_status_label.text = NetSession.get_status()
	NetSession.status_changed.connect(_on_status_changed)
	NetSession.lobby_updated.connect(_on_lobby_updated)
	_build_slot_rows()
	_refresh_connection_ui()
	# 调试钩子：-- --autolobby 直接本机开房，供自动化截图与自测。
	if "--autolobby" in OS.get_cmdline_user_args():
		NetSession.host(_port())
	# 调试钩子：-- --autojoin（或 res://autojoin.txt 存在）直接加入默认服务器并立即开局，
	# 供 Godot MCP 一键开出「已在对局中」的游戏窗口。
	if "--autojoin" in OS.get_cmdline_user_args():
		_auto_join_solo()
	# 调试控制端点已改为 autoload 自挂载（project.godot 注册，带 --debugport 才启用），
	# 客户端与专用服进程均可使用，此处不再手动挂载。
	if "--autoshot" in OS.get_cmdline_user_args():
		_auto_screenshot()
	if "--smokeclient" in OS.get_cmdline_user_args():
		# 冒烟监控挂 root（不随场景切换释放），逻辑全在 SmokeClient.gd。
		var smoke := Node.new()
		smoke.set_script(load("res://source/net/SmokeClient.gd"))
		get_tree().root.add_child.call_deferred(smoke)


func _auto_screenshot() -> void:
	await get_tree().create_timer(1.5).timeout
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	img.save_png("G:/AIRTS/临时文件夹/deploy_ai_rts/lobby_preview.png")
	print("LOBBY_SHOT saved")
	get_tree().quit()


func _exit_tree() -> void:
	if NetSession.status_changed.is_connected(_on_status_changed):
		NetSession.status_changed.disconnect(_on_status_changed)
	if NetSession.lobby_updated.is_connected(_on_lobby_updated):
		NetSession.lobby_updated.disconnect(_on_lobby_updated)


func _port() -> int:
	return int(_port_edit.text)


func _build_slot_rows() -> void:
	for i in range(NetSession.MAX_PLAYERS):
		var panel := PanelContainer.new()
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 10)
		var color_rect := ColorRect.new()
		color_rect.custom_minimum_size = Vector2(8, 30)
		color_rect.color = _slot_color(i)
		row.add_child(color_rect)
		var index_label := Label.new()
		index_label.text = "%d" % (i + 1)
		row.add_child(index_label)
		var name_label := Label.new()
		name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		name_label.text = "空位"
		row.add_child(name_label)
		var state_label := Label.new()
		state_label.text = ""
		row.add_child(state_label)
		var toggle_button := Button.new()
		toggle_button.text = "＋AI"
		toggle_button.visible = false
		toggle_button.pressed.connect(_on_slot_toggle_pressed.bind(i))
		row.add_child(toggle_button)
		panel.add_child(row)
		_slots_box.add_child(panel)
		_slot_rows.append({"color": color_rect, "name": name_label, "state": state_label, "toggle": toggle_button})


func _slot_color(i: int) -> Color:
	var colors = Constants.Player.COLORS
	if i < colors.size():
		return colors[i]
	return Color(0.5, 0.5, 0.5)


func _on_lobby_updated(slots: Array) -> void:
	var am_host := NetSession.is_room_owner()
	for i in range(_slot_rows.size()):
		if i >= slots.size():
			continue
		var entry: Dictionary = slots[i]
		var kind := int(entry.get("kind", NetSession.SLOT_EMPTY))
		var row: Dictionary = _slot_rows[i]
		var name_label: Label = row["name"]
		var state_label: Label = row["state"]
		var toggle: Button = row["toggle"]
		match kind:
			NetSession.SLOT_HUMAN:
				name_label.text = str(entry.get("name", "指挥官"))
				state_label.text = "已准备" if bool(entry.get("ready", false)) else "未准备"
			NetSession.SLOT_AI:
				name_label.text = "简单 AI"
				state_label.text = "补位"
			_:
				name_label.text = "空位"
				state_label.text = ""
		# 只有房主能切空槽 ↔ AI；人类占用的槽不可动。
		if am_host and not NetSession.is_dedicated_server():
			toggle.visible = kind != NetSession.SLOT_HUMAN
			toggle.text = "撤 AI" if kind == NetSession.SLOT_AI else "＋AI"
		else:
			toggle.visible = false
	_refresh_connection_ui()


func _on_slot_toggle_pressed(slot: int) -> void:
	if slot >= NetSession.last_lobby_slots.size():
		return
	var kind := int(NetSession.last_lobby_slots[slot].get("kind", NetSession.SLOT_EMPTY))
	var next_kind := NetSession.SLOT_EMPTY if kind == NetSession.SLOT_AI else NetSession.SLOT_AI
	NetSession.host_set_slot_kind(slot, next_kind)


func _refresh_connection_ui() -> void:
	var connected := NetSession.is_networked()
	var is_host := NetSession.is_room_owner()
	# 两段式流程（2026-09-05）：未连接只给「加入局服」；
	# 进房后才出现 地图/槽位/准备，开局按钮仅房主可见。
	_join_button.visible = not connected
	_host_edit.get_parent().visible = not connected
	_ready_button.visible = connected
	var solo_btn := get_node_or_null("PanelContainer/MarginContainer/VBoxContainer/ReadyRow/SoloButton") as Button
	if solo_btn != null:
		solo_btn.visible = connected and is_host
	var main_row := get_node_or_null("PanelContainer/MarginContainer/VBoxContainer/MainRow")
	if main_row != null:
		main_row.visible = connected
	_name_edit.editable = not connected


func _on_name_edit_text_changed(new_text: String) -> void:
	NetSession.set_local_name(new_text)


func _on_status_changed(text: String) -> void:
	_status_label.text = text


func _on_join_button_pressed() -> void:
	# 加入局服 = 只进大厅，绝不自动开局：先清掉任何残留的单人开局意图。
	NetSession.clear_auto_start_intent()
	var err := NetSession.join(_host_edit.text.strip_edges(), _port())
	if err != OK:
		_status_label.text = "连接失败：%s" % err


func _on_ready_button_pressed() -> void:
	NetSession.set_ready(true)
	_ready_button.text = "已准备"


func _on_solo_button_pressed() -> void:
	# “立即开局（单人测试）”明确进入被动 AI 测试局：AI 可发展，但不主动攻击。
	NetSession.start_solo(true, true)


## 调试钩子：--autojoin 或 res://autojoin.txt 存在时，直接加入默认服务器并立即开局，
## 供 Godot MCP 一键开出「已在对局中」的游戏窗口（免去人工点菜单）。
func _auto_join_solo() -> void:
	# 冒烟测试可通过 --smokehost/--smokeport 指向本机专用服；普通
	# --autojoin 仍使用大厅默认的云端地址。
	var args := OS.get_cmdline_user_args()
	var host := NetSession.DEFAULT_HOST
	var port := NetSession.DEFAULT_PORT
	var host_index := args.find("--smokehost")
	if host_index >= 0 and host_index + 1 < args.size():
		host = str(args[host_index + 1])
	var port_index := args.find("--smokeport")
	if port_index >= 0 and port_index + 1 < args.size():
		port = int(args[port_index + 1])
	_host_edit.text = host
	_port_edit.text = str(port)
	_on_join_button_pressed()
	var waited := 0
	while waited < 60:
		await get_tree().create_timer(1.0).timeout
		waited += 1
		if not NetSession.is_networked():
			continue
		if NetSession.local_slot >= 0:
			if args.has("--autojoin-lobby"):
				_status_label.text = "已连接，等待调试开局…"
				return
			_status_label.text = "自动开局中…"
			NetSession.start_solo()
			return
	_status_label.text = "自动加入超时"


func _on_back_button_pressed() -> void:
	# 复核 2026-09-02：返回在任何连接状态下都必须生效。先断会话（幂等安全），
	# 切场景用 call_deferred 排到帧末——断连过程中的信号重入不再可能打断导航。
	if NetSession.is_networked() and not NetSession.is_dedicated_server():
		NetSession.disconnect_session()
	get_tree().change_scene_to_file.call_deferred("res://source/main-menu/Main.tscn")
