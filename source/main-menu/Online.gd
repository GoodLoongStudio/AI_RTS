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
@onready var _listen_button: Button = $PanelContainer/MarginContainer/VBoxContainer/JoinRow/ListenButton
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
		_on_listen_button_pressed()
	if "--autoshot" in OS.get_cmdline_user_args():
		_auto_screenshot()
	if "--smokeclient" in OS.get_cmdline_user_args():
		_run_smoke_client()


var _smoke_log_fa: FileAccess = null


func _smoke_log(msg: String) -> void:
	print(msg)
	if _smoke_log_fa == null:
		_smoke_log_fa = FileAccess.open("user://smoke_client.log", FileAccess.WRITE)
	if _smoke_log_fa != null:
		_smoke_log_fa.store_line("%d %s" % [Time.get_ticks_msec(), msg])
		_smoke_log_fa.flush()


## 双进程联机冒烟验收：headless 客户端连本机专用服 → 自动开局（AI 补位）→
## 等 go-live 首个快照应用到插值目标 → SMOKE_OK 退出（0），失败 SMOKE_FAIL 退出（1）。
## 用法：godot --headless --path . res://source/main-menu/Online.tscn -- --smokeclient --smokeport 24599
## 注意：开局后本节点会随场景切换被释放，协程必须只用局部变量（self 成员访问即崩）。
func _run_smoke_client() -> void:
	var tree := get_tree()
	var args := OS.get_cmdline_user_args()
	var port := NetSession.DEFAULT_PORT
	var pi := args.find("--smokeport")
	if pi >= 0 and pi + 1 < args.size():
		port = int(args[pi + 1])
	var deadline := Time.get_ticks_msec() + 300_000
	var log_fa: FileAccess = FileAccess.open("user://smoke_client.log", FileAccess.WRITE)
	var logf = func(msg: String) -> void:
		print(msg)
		if log_fa != null:
			log_fa.store_line("%d %s" % [Time.get_ticks_msec(), msg])
			log_fa.flush()
	logf.call("SMOKE: client start, target 127.0.0.1:%d" % port)
	var err := NetSession.join("127.0.0.1", port)
	logf.call("SMOKE: join err=%d" % err)
	if err != OK:
		logf.call("SMOKE_FAIL join")
		tree.quit(1)
		return
	# 等连接+槽位（槽位分配后状态直接跳"已分配阵营槽位"，两种都要认）。
	var waited := 0
	while Time.get_ticks_msec() < deadline:
		await tree.create_timer(0.5).timeout
		waited += 1
		var st := NetSession.get_status()
		if st.begins_with("已连接") or st.begins_with("已分配阵营槽位"):
			break
		if waited % 10 == 0:
			logf.call("SMOKE: 等连接 %ds, status=%s" % [waited, st])
	if not NetSession.is_networked():
		logf.call("SMOKE_FAIL connect")
		tree.quit(1)
		return
	logf.call("SMOKE: connected, status=%s" % NetSession.get_status())
	await tree.create_timer(1.0).timeout
	NetSession.start_solo()
	logf.call("SMOKE: solo start requested")
	# 场景切换后本节点已释放：此后只用局部 tree / logf，绝不碰 self 成员。
	var sync: Node = null
	waited = 0
	while Time.get_ticks_msec() < deadline:
		await tree.create_timer(1.0).timeout
		waited += 1
		sync = tree.root.find_child("NetSync", true, false)
		if sync != null:
			logf.call("SMOKE: NetSync 出现于等待 %ds" % waited)
			break
		if waited % 10 == 0:
			logf.call("SMOKE: 等 NetSync %ds, scene=%s" % [
				waited, tree.current_scene.name if tree.current_scene else "null"])
	if sync == null:
		logf.call("SMOKE_FAIL no NetSync (Match 未加载)")
		tree.quit(1)
		return
	waited = 0
	while Time.get_ticks_msec() < deadline:
		await tree.create_timer(1.0).timeout
		waited += 1
		if not NetSession.is_networked():
			logf.call("SMOKE_FAIL 会话已断开（等待 %ds）" % waited)
			tree.quit(1)
			return
		var targets: Dictionary = sync.get("_interp_target") if sync.get("_interp_target") is Dictionary else {}
		var units := tree.get_nodes_in_group("units").size()
		if targets.size() > 0:
			logf.call("SMOKE_OK units=%d interp_targets=%d" % [units, targets.size()])
			tree.quit(0)
			return
		if waited % 10 == 0:
			logf.call("SMOKE: 等快照 %ds, units=%d" % [waited, units])
	logf.call("SMOKE_FAIL timeout")
	tree.quit(1)


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
	var am_host := NetSession.is_networked() and NetSession.local_slot == 0
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
	_join_button.visible = not connected
	_listen_button.visible = not connected
	_host_edit.get_parent().visible = not connected
	_ready_button.visible = connected
	_name_edit.editable = not connected


func _on_name_edit_text_changed(new_text: String) -> void:
	NetSession.set_local_name(new_text)


func _on_status_changed(text: String) -> void:
	_status_label.text = text


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


func _on_solo_button_pressed() -> void:
	NetSession.start_solo()


func _on_back_button_pressed() -> void:
	if NetSession.is_networked() and not NetSession.is_dedicated_server():
		NetSession.disconnect_session()
	get_tree().change_scene_to_file("res://source/main-menu/Main.tscn")
