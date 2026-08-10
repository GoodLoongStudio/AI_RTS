extends Control

const Human = preload("res://source/match/players/human/Human.gd")
const SquadCommand = preload("res://source/match/commands/SquadCommand.gd")

const SQUAD_NAMES = {1: "突击队", 2: "侦察队", 3: "支援队"}
const COMMAND_BY_KEY = {
	KEY_Q: SquadCommand.Type.MOVE,
	KEY_W: SquadCommand.Type.ATTACK,
	KEY_E: SquadCommand.Type.DEFEND,
	KEY_R: SquadCommand.Type.SCOUT,
	KEY_D: SquadCommand.Type.RETREAT,
	KEY_F: SquadCommand.Type.STOP,
}
const COMMAND_SLOTS = [
	["Q", "移动", SquadCommand.Type.MOVE],
	["W", "攻击", SquadCommand.Type.ATTACK],
	["E", "防守", SquadCommand.Type.DEFEND],
	["R", "侦察", SquadCommand.Type.SCOUT],
	["D", "撤退", SquadCommand.Type.RETREAT],
	["F", "停止", SquadCommand.Type.STOP],
]

var _controller = null
var _squad_buttons := {}
var _chat_log: RichTextLabel
var _input: LineEdit
var _command_hint: Label


func _ready():
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_build_ui()
	MatchSignals.match_started.connect(_on_match_started)
	_append_ai("指挥界面已加载。等待战局初始化……")


func _unhandled_key_input(event: InputEvent):
	if not event is InputEventKey or not event.pressed or event.echo:
		return
	if _input.has_focus():
		if event.keycode == KEY_ESCAPE:
			_input.release_focus()
		return
	if _controller == null:
		return

	var key = event.physical_keycode if event.physical_keycode != 0 else event.keycode
	if key in [KEY_1, KEY_2, KEY_3]:
		_controller.select_squad(int(key - KEY_0))
		get_viewport().set_input_as_handled()
	elif key == KEY_ENTER:
		_input.grab_focus()
		get_viewport().set_input_as_handled()
	elif key in COMMAND_BY_KEY:
		_controller.begin_command(COMMAND_BY_KEY[key], "hotkey")
		get_viewport().set_input_as_handled()
	elif key == KEY_ESCAPE and _controller.pending_command != null:
		_controller.cancel_pending_command()
		_append_ai("已取消待确认命令。")
		_refresh_squad_ui()
		get_viewport().set_input_as_handled()


func _build_ui():
	var left := VBoxContainer.new()
	left.set_anchors_preset(Control.PRESET_TOP_LEFT)
	left.offset_left = 18
	left.offset_top = 170
	left.offset_right = 278
	left.offset_bottom = 490
	left.add_theme_constant_override("separation", 8)
	left.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(left)

	var squad_header := Label.new()
	squad_header.text = "作战小队"
	squad_header.add_theme_font_size_override("font_size", 22)
	left.add_child(squad_header)
	for squad_id in [1, 2, 3]:
		var card := Button.new()
		card.custom_minimum_size = Vector2(255, 76)
		card.text = "%d  %s\n未编组 · 待命" % [squad_id, SQUAD_NAMES[squad_id]]
		card.alignment = HORIZONTAL_ALIGNMENT_LEFT
		card.pressed.connect(_on_squad_button_pressed.bind(squad_id))
		left.add_child(card)
		_squad_buttons[squad_id] = card

	var right := PanelContainer.new()
	right.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	right.offset_left = -440
	right.offset_top = 70
	right.offset_right = -18
	right.offset_bottom = 700
	right.mouse_filter = Control.MOUSE_FILTER_STOP
	right.add_theme_stylebox_override("panel", _make_panel_style(Color(0.035, 0.045, 0.06, 0.93)))
	add_child(right)

	var right_margin := MarginContainer.new()
	right_margin.add_theme_constant_override("margin_left", 14)
	right_margin.add_theme_constant_override("margin_top", 12)
	right_margin.add_theme_constant_override("margin_right", 14)
	right_margin.add_theme_constant_override("margin_bottom", 12)
	right.add_child(right_margin)
	var right_box := VBoxContainer.new()
	right_box.add_theme_constant_override("separation", 8)
	right_margin.add_child(right_box)
	var ai_title := Label.new()
	ai_title.text = "岚 · AI 指挥频道"
	ai_title.add_theme_font_size_override("font_size", 22)
	right_box.add_child(ai_title)
	var ai_subtitle := Label.new()
	ai_subtitle.text = "事实 / 建议 / 命令执行"
	ai_subtitle.modulate = Color(0.65, 0.72, 0.8)
	right_box.add_child(ai_subtitle)
	_chat_log = RichTextLabel.new()
	_chat_log.bbcode_enabled = true
	_chat_log.fit_content = false
	_chat_log.scroll_active = true
	_chat_log.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_chat_log.custom_minimum_size = Vector2(390, 470)
	right_box.add_child(_chat_log)
	_command_hint = Label.new()
	_command_hint.text = "等待战局……"
	_command_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	right_box.add_child(_command_hint)

	var bottom := PanelContainer.new()
	bottom.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	bottom.offset_left = 290
	bottom.offset_top = -168
	bottom.offset_right = -458
	bottom.offset_bottom = -18
	bottom.mouse_filter = Control.MOUSE_FILTER_STOP
	bottom.add_theme_stylebox_override("panel", _make_panel_style(Color(0.035, 0.045, 0.06, 0.94)))
	add_child(bottom)

	var bottom_margin := MarginContainer.new()
	bottom_margin.add_theme_constant_override("margin_left", 12)
	bottom_margin.add_theme_constant_override("margin_top", 10)
	bottom_margin.add_theme_constant_override("margin_right", 12)
	bottom_margin.add_theme_constant_override("margin_bottom", 10)
	bottom.add_child(bottom_margin)
	var bottom_box := VBoxContainer.new()
	bottom_box.add_theme_constant_override("separation", 8)
	bottom_margin.add_child(bottom_box)
	var cmd_row := HBoxContainer.new()
	cmd_row.alignment = BoxContainer.ALIGNMENT_CENTER
	cmd_row.add_theme_constant_override("separation", 8)
	bottom_box.add_child(cmd_row)
	for item in COMMAND_SLOTS:
		var button := Button.new()
		button.custom_minimum_size = Vector2(104, 60)
		button.text = "%s\n%s" % [item[0], item[1]]
		button.pressed.connect(_on_command_button_pressed.bind(item[2]))
		cmd_row.add_child(button)

	var input_row := HBoxContainer.new()
	input_row.add_theme_constant_override("separation", 8)
	bottom_box.add_child(input_row)
	_input = LineEdit.new()
	_input.placeholder_text = "告诉 AI：二队向右侦察；一队原地防守，不要追击……"
	_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_input.text_submitted.connect(_on_text_submitted)
	input_row.add_child(_input)
	var send := Button.new()
	send.text = "发送"
	send.custom_minimum_size = Vector2(74, 0)
	send.pressed.connect(_on_send_pressed)
	input_row.add_child(send)


func _make_panel_style(color: Color) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = color
	style.corner_radius_top_left = 8
	style.corner_radius_top_right = 8
	style.corner_radius_bottom_left = 8
	style.corner_radius_bottom_right = 8
	style.border_width_left = 1
	style.border_width_top = 1
	style.border_width_right = 1
	style.border_width_bottom = 1
	style.border_color = Color(0.23, 0.31, 0.42, 0.85)
	return style


func _on_match_started():
	_bind_controller()
	if _controller == null:
		_append_ai("未找到玩家小队命令控制器，AI 指挥功能已降级。")
		return
	_append_ai("指挥链路已上线。1～3 选择小队，QWERDF 下达战斗命令，Enter 输入自然语言。")
	_refresh_squad_ui()


func _bind_controller():
	for player in get_tree().get_nodes_in_group("players"):
		if player is Human:
			_controller = player.find_child("SquadCommandController")
			break
	if _controller == null:
		return
	_controller.active_squad_changed.connect(_on_active_squad_changed)
	_controller.command_target_requested.connect(_on_command_target_requested)
	_controller.command_executed.connect(_on_command_executed)
	_controller.command_rejected.connect(_on_command_rejected)


func _on_squad_button_pressed(squad_id: int):
	if _controller != null:
		_controller.select_squad(squad_id)


func _on_command_button_pressed(command_type: int):
	if _controller != null:
		_controller.begin_command(command_type, "ui")


func _on_send_pressed():
	_on_text_submitted(_input.text)


func _on_text_submitted(text: String):
	var command_text := text.strip_edges()
	if command_text.is_empty() or _controller == null:
		return
	_append_player(command_text)
	_input.clear()
	_input.release_focus()

	var squad_id = _parse_squad(command_text)
	if squad_id != -1:
		_controller.select_squad(squad_id)
	var command_type = _parse_command(command_text)
	if command_type == -1:
		_append_ai("没有把这句话映射到安全命令。当前支持：移动、攻击、防守、侦察、撤退、停止。")
		return
	_append_ai(
		"解析：%d %s · %s。"
		% [_controller.active_squad, SQUAD_NAMES[_controller.active_squad], SquadCommand.type_label(command_type)]
	)
	_controller.begin_command(command_type, "text", command_text)


func _parse_squad(text: String) -> int:
	for pair in [[1, ["一队", "1队", "第一队"]], [2, ["二队", "2队", "第二队"]], [3, ["三队", "3队", "第三队"]]]:
		for token in pair[1]:
			if text.contains(token):
				return pair[0]
	return -1


func _parse_command(text: String) -> int:
	if text.contains("不要追") or text.contains("防守") or text.contains("守住") or text.contains("原地守"):
		return SquadCommand.Type.DEFEND
	if text.contains("侦察") or text.contains("探路") or text.contains("搜索"):
		return SquadCommand.Type.SCOUT
	if text.contains("撤退") or text.contains("撤离") or text.contains("后撤"):
		return SquadCommand.Type.RETREAT
	if text.contains("停止") or text.contains("停下") or text.contains("待命"):
		return SquadCommand.Type.STOP
	if text.contains("攻击") or text.contains("集火") or text.contains("打掉"):
		return SquadCommand.Type.ATTACK
	if text.contains("移动") or text.contains("前进") or text.contains("去") or text.contains("绕"):
		return SquadCommand.Type.MOVE
	return -1


func _on_active_squad_changed(_squad_id: int):
	_refresh_squad_ui()


func _on_command_target_requested(command, target_kind: String):
	var target_text = "地图位置" if target_kind == "terrain" else "敌方目标"
	_append_ai(
		"已理解：%d %s → %s。请右键指定%s。"
		% [command.squad_id, SQUAD_NAMES[command.squad_id], SquadCommand.type_label(command.type), target_text]
	)
	_refresh_squad_ui()


func _on_command_executed(_command, message: String):
	_append_ai("执行：%s" % message)
	_refresh_squad_ui()


func _on_command_rejected(_command, reason: String):
	_append_ai("无法执行：%s" % reason)
	_refresh_squad_ui()


func _refresh_squad_ui():
	if _controller == null:
		return
	for squad_id in [1, 2, 3]:
		var prefix = "▶ " if squad_id == _controller.active_squad else ""
		var count = _controller.get_squad_units(squad_id).size()
		var roster = "%d 单位" % count if count > 0 else "未编组"
		_squad_buttons[squad_id].text = "%s%d  %s\n%s · %s" % [
			prefix,
			squad_id,
			SQUAD_NAMES[squad_id],
			roster,
			_controller.get_squad_status(squad_id),
		]
	var suffix = " · 等待目标" if _controller.pending_command != null else ""
	_command_hint.text = "当前：%d %s · %s%s" % [
		_controller.active_squad,
		SQUAD_NAMES[_controller.active_squad],
		_controller.get_squad_status(_controller.active_squad),
		suffix,
	]


func _append_player(text: String):
	_chat_log.append_text("[color=#a8c7ff]你[/color]\n%s\n\n" % text)


func _append_ai(text: String):
	_chat_log.append_text("[color=#8ee6b2]岚 · AI副官[/color]\n%s\n\n" % text)
