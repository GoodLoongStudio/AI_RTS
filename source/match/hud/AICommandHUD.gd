extends Control

signal squad_selected(squad_id)
signal squad_command_executed(squad_id, command)
signal player_text_submitted(text)

const WaitingForTargets = preload("res://source/match/units/actions/WaitingForTargets.gd")

const SQUAD_NAMES = {1: "突击队", 2: "侦察队", 3: "支援队"}
const COMMAND_KEYS = {KEY_Q: "MOVE", KEY_W: "ATTACK", KEY_E: "DEFEND", KEY_R: "SCOUT", KEY_D: "RETREAT", KEY_F: "STOP"}
const COMMAND_LABELS = {
	"MOVE": "移动", "ATTACK": "攻击", "DEFEND": "防守",
	"SCOUT": "侦察", "RETREAT": "撤退", "STOP": "停止"
}

var active_squad := 1
var pending_command := ""
var squad_status := {1: "待命", 2: "待命", 3: "待命"}

var _squad_buttons := {}
var _status_labels := {}
var _chat_log: RichTextLabel
var _input: LineEdit
var _command_hint: Label


func _ready():
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_build_ui()
	MatchSignals.terrain_targeted.connect(_on_terrain_targeted)
	MatchSignals.unit_targeted.connect(_on_unit_targeted)
	_append_ai("指挥链路已上线。数字键选择小队，QWERDF 下达战斗命令；Enter 可直接输入自然语言。")
	_refresh_squad_ui()


func _unhandled_key_input(event: InputEvent):
	if not event.pressed or event.echo:
		return
	if _input.has_focus():
		if event.keycode == KEY_ESCAPE:
			_input.release_focus()
		return
	match event.keycode:
		KEY_1, KEY_2, KEY_3:
			_select_squad(int(event.keycode - KEY_0))
		KEY_ENTER:
			_input.grab_focus()
		KEY_Q, KEY_W, KEY_E, KEY_R, KEY_D, KEY_F:
			_begin_command(COMMAND_KEYS[event.keycode])


func _build_ui():
	var left := VBoxContainer.new()
	left.position = Vector2(18, 210)
	left.size = Vector2(255, 360)
	left.add_theme_constant_override("separation", 8)
	left.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(left)

	var left_title := Label.new()
	left_title.text = "作战小队"
	left_title.add_theme_font_size_override("font_size", 22)
	left.add_child(left_title)
	for squad_id in [1, 2, 3]:
		var card := Button.new()
		card.custom_minimum_size = Vector2(250, 82)
		card.text = "%d  %s\n待命" % [squad_id, SQUAD_NAMES[squad_id]]
		card.alignment = HORIZONTAL_ALIGNMENT_LEFT
		card.pressed.connect(_select_squad.bind(squad_id))
		left.add_child(card)
		_squad_buttons[squad_id] = card

	var right := PanelContainer.new()
	right.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	right.position = Vector2(-430, 80)
	right.size = Vector2(410, 610)
	right.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(right)
	var right_box := VBoxContainer.new()
	right_box.add_theme_constant_override("separation", 8)
	right.add_child(right_box)
	var ai_title := Label.new()
	ai_title.text = "AI 指挥频道"
	ai_title.add_theme_font_size_override("font_size", 22)
	right_box.add_child(ai_title)
	_chat_log = RichTextLabel.new()
	_chat_log.bbcode_enabled = true
	_chat_log.fit_content = false
	_chat_log.scroll_active = true
	_chat_log.custom_minimum_size = Vector2(390, 470)
	right_box.add_child(_chat_log)
	_command_hint = Label.new()
	_command_hint.text = "当前：1 突击队 · 待命"
	right_box.add_child(_command_hint)

	var bottom := PanelContainer.new()
	bottom.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	bottom.offset_left = 290
	bottom.offset_right = -450
	bottom.offset_top = -160
	bottom.offset_bottom = -18
	bottom.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(bottom)
	var bottom_box := VBoxContainer.new()
	bottom_box.add_theme_constant_override("separation", 8)
	bottom.add_child(bottom_box)
	var cmd_row := HBoxContainer.new()
	cmd_row.alignment = BoxContainer.ALIGNMENT_CENTER
	cmd_row.add_theme_constant_override("separation", 8)
	bottom_box.add_child(cmd_row)
	for item in [["Q", "移动", "MOVE"], ["W", "攻击", "ATTACK"], ["E", "防守", "DEFEND"], ["R", "侦察", "SCOUT"], ["D", "撤退", "RETREAT"], ["F", "停止", "STOP"]]:
		var button := Button.new()
		button.custom_minimum_size = Vector2(105, 62)
		button.text = "%s\n%s" % [item[0], item[1]]
		button.pressed.connect(_begin_command.bind(item[2]))
		cmd_row.add_child(button)
	var input_row := HBoxContainer.new()
	bottom_box.add_child(input_row)
	_input = LineEdit.new()
	_input.placeholder_text = "告诉 AI：二队向右侦察；一队原地防守，不要追击……"
	_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_input.text_submitted.connect(_on_text_submitted)
	input_row.add_child(_input)
	var send := Button.new()
	send.text = "发送"
	send.pressed.connect(func(): _on_text_submitted(_input.text))
	input_row.add_child(send)


func _select_squad(squad_id: int):
	active_squad = squad_id
	var units = _get_squad_units(squad_id)
	if units.is_empty():
		_append_ai("%d %s 尚未编组。先框选单位并用 Ctrl+%d 保存编组。" % [squad_id, SQUAD_NAMES[squad_id], squad_id])
	else:
		Utils.Match.select_units(Utils.Set.from_array(units))
	_refresh_squad_ui()
	squad_selected.emit(squad_id)


func _get_squad_units(squad_id: int) -> Array:
	return get_tree().get_nodes_in_group("unit_group_%d" % squad_id).filter(
		func(unit): return unit.is_in_group("controlled_units")
	)


func _begin_command(command: String):
	if _get_squad_units(active_squad).is_empty():
		_append_ai("无法执行：%d %s 还没有单位。" % [active_squad, SQUAD_NAMES[active_squad]])
		return
	match command:
		"DEFEND":
			_execute_defend()
		"STOP":
			_execute_stop()
		"MOVE", "SCOUT", "RETREAT":
			pending_command = command
			_append_ai("已理解：%d %s → %s。请在地图上右键指定位置。" % [active_squad, SQUAD_NAMES[active_squad], COMMAND_LABELS[command]])
		"ATTACK":
			pending_command = command
			_append_ai("已理解：%d %s → 攻击。请右键指定敌方目标。" % [active_squad, SQUAD_NAMES[active_squad]])
	_refresh_squad_ui()


func _execute_defend():
	for unit in _get_squad_units(active_squad):
		if unit.attack_range != null:
			unit.action = WaitingForTargets.new()
	squad_status[active_squad] = "固守中"
	pending_command = ""
	_append_ai("执行：%d %s 原地防守；不会主动追击超出视野的目标。" % [active_squad, SQUAD_NAMES[active_squad]])
	_refresh_squad_ui()
	squad_command_executed.emit(active_squad, "DEFEND")


func _execute_stop():
	for unit in _get_squad_units(active_squad):
		unit.action = null
	squad_status[active_squad] = "待命"
	pending_command = ""
	_append_ai("执行：%d %s 停止当前任务。" % [active_squad, SQUAD_NAMES[active_squad]])
	_refresh_squad_ui()
	squad_command_executed.emit(active_squad, "STOP")


func _on_terrain_targeted(_position):
	if pending_command not in ["MOVE", "SCOUT", "RETREAT"]:
		return
	var executed_command = pending_command
	var label = COMMAND_LABELS[executed_command]
	squad_status[active_squad] = "%s中" % label
	_append_ai("执行确认：%d %s %s。路线已交给现有 RTS 移动系统。" % [active_squad, SQUAD_NAMES[active_squad], label])
	pending_command = ""
	_refresh_squad_ui()
	squad_command_executed.emit(active_squad, executed_command)


func _on_unit_targeted(unit):
	if pending_command != "ATTACK":
		return
	if not unit.is_in_group("adversary_units"):
		_append_ai("目标无效：请选择敌方单位。")
		return
	squad_status[active_squad] = "交战中"
	_append_ai("执行确认：%d %s 集火 %s。" % [active_squad, SQUAD_NAMES[active_squad], unit.type])
	pending_command = ""
	_refresh_squad_ui()
	squad_command_executed.emit(active_squad, "ATTACK")


func _on_text_submitted(text: String):
	var command_text := text.strip_edges()
	if command_text.is_empty():
		return
	player_text_submitted.emit(command_text)
	_append_player(command_text)
	_input.clear()
	var squad_id = _parse_squad(command_text)
	if squad_id != -1:
		_select_squad(squad_id)
	var command = _parse_command(command_text)
	if command.is_empty():
		_append_ai("我没有把这句话映射到安全命令。当前支持：移动、攻击、防守、侦察、撤退、停止。")
		return
	_append_ai("解析结果：%d %s · %s。" % [active_squad, SQUAD_NAMES[active_squad], COMMAND_LABELS[command]])
	_begin_command(command)


func _parse_squad(text: String) -> int:
	for pair in [[1, ["一队", "1队", "第一队"]], [2, ["二队", "2队", "第二队"]], [3, ["三队", "3队", "第三队"]]]:
		for token in pair[1]:
			if text.contains(token):
				return pair[0]
	return -1


func _parse_command(text: String) -> String:
	if text.contains("不要追") or text.contains("防守") or text.contains("守住") or text.contains("原地守"):
		return "DEFEND"
	if text.contains("侦察") or text.contains("探路") or text.contains("搜索"):
		return "SCOUT"
	if text.contains("撤退") or text.contains("撤离") or text.contains("后撤"):
		return "RETREAT"
	if text.contains("停止") or text.contains("停下") or text.contains("待命"):
		return "STOP"
	if text.contains("攻击") or text.contains("集火") or text.contains("打掉"):
		return "ATTACK"
	if text.contains("移动") or text.contains("前进") or text.contains("去") or text.contains("绕"):
		return "MOVE"
	return ""


func _refresh_squad_ui():
	for squad_id in [1, 2, 3]:
		var prefix = "▶ " if squad_id == active_squad else ""
		var count = _get_squad_units(squad_id).size()
		_squad_buttons[squad_id].text = "%s%d  %s  · %d\n%s" % [prefix, squad_id, SQUAD_NAMES[squad_id], count, squad_status[squad_id]]
	_command_hint.text = "当前：%d %s · %s%s" % [active_squad, SQUAD_NAMES[active_squad], squad_status[active_squad], " · 等待目标" if not pending_command.is_empty() else ""]


func post_agent_message(speaker: String, text: String):
	_chat_log.append_text("[color=#8ee6b2]%s[/color]\n%s\n\n" % [speaker, text])


func _append_player(text: String):
	_chat_log.append_text("[color=#a8c7ff]你[/color]\n%s\n\n" % text)


func _append_ai(text: String):
	post_agent_message("岚 · AI副官", text)
