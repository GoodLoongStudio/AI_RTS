extends Control

signal squad_selected(squad_id)
signal squad_command_executed(squad_id, command)
signal player_text_submitted(text)

const SQUAD_NAMES = {1: "突击队", 2: "侦察队", 3: "支援队"}
const COMMAND_ACTIONS = {
	"legacy.command_move": "MOVE",
	"legacy.command_attack": "ATTACK",
	"legacy.command_defend": "DEFEND",
	"legacy.command_scout": "SCOUT",
	"legacy.command_retreat": "RETREAT",
	"legacy.command_stop": "STOP",
}
const COMMAND_LABELS = {
	"MOVE": "移动", "ATTACK": "攻击", "DEFEND": "防守",
	"SCOUT": "侦察", "RETREAT": "撤退", "STOP": "停止"
}
const F1_DOUBLE_TAP_MS := 350

var control_mode := "squad"
var hero_name := "先锋指挥单元"
var active_squad := 1
var pending_command := ""
var squad_status := {1: "待命", 2: "待命", 3: "待命"}

var _squad_buttons := {}
var _command_buttons := []
var _chat_log: RichTextLabel
var _input: LineEdit
var _command_hint: Label
var _agent_state: Label
var _context_label: Label
var _hero_focus_card: Button
var _last_f1_press_msec := -100000
var _hero_camera_locked := false
var _current_objective := "等待战区任务同步"
var _current_suggestion := "保持待命，等待新的任务信息。"
var _current_risk := "未知"
var _mock_agent_busy := false
@onready var _input_runtime = find_parent("Match").get_node("InputBindingRuntime")


func _ready():
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_build_ui()
	_input_runtime.connect("ActionPressed", _on_input_action_pressed)
	MatchSignals.terrain_targeted.connect(_on_terrain_targeted)
	MatchSignals.unit_targeted.connect(_on_unit_targeted)
	MatchSignals.unit_died.connect(_on_unit_died)
	if _is_hero_mode():
		_append_ai("先锋链路已上线。你可以直接告诉我想做什么，也可以问我‘下一步做什么’或‘风险怎么样’。")
	else:
		_append_ai("指挥链路已上线。你可以直接下达自然语言命令，也可以让我评估当前风险和下一步行动。")
	_refresh_squad_ui()
	_refresh_agent_context()
	set_interface_visible(false)


func set_interface_visible(should_show: bool):
	visible = should_show
	if not should_show:
		pending_command = ""
		if _input != null:
			_input.release_focus()
	_input_runtime.SetContextActive("LegacyAgent", should_show)


func is_interface_visible() -> bool:
	return visible


func _on_input_action_pressed(action_id: String):
	if not visible:
		return
	if action_id == "text.cancel":
		_input.release_focus()
		return
	if action_id == "global.cancel":
		if pending_command != "":
			pending_command = ""
			_refresh_squad_ui()
		return
	if action_id == "legacy.hero_focus" and _is_hero_mode():
		_handle_hero_focus_hotkey()
		return
	if _input.has_focus():
		return
	if action_id.begins_with("legacy.squad_"):
		var squad_id := int(action_id.trim_prefix("legacy.squad_"))
		if squad_id == 1 or not _is_hero_mode():
			_select_squad(squad_id)
	elif action_id == "legacy.chat_focus":
		_input.grab_focus()
	elif COMMAND_ACTIONS.has(action_id):
		_begin_command(COMMAND_ACTIONS[action_id])


func _build_ui():
	var left := VBoxContainer.new()
	left.position = Vector2(18, 210)
	left.size = Vector2(255, 360)
	left.add_theme_constant_override("separation", 8)
	left.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(left)

	var left_title := Label.new()
	left_title.text = "先锋单位" if _is_hero_mode() else "作战小队"
	left_title.add_theme_font_size_override("font_size", 22)
	left.add_child(left_title)
	for squad_id in _control_ids():
		var card := Button.new()
		card.custom_minimum_size = Vector2(250, 82)
		card.text = "%s\n待命" % _control_display(squad_id)
		card.alignment = HORIZONTAL_ALIGNMENT_LEFT
		card.pressed.connect(_select_squad.bind(squad_id))
		left.add_child(card)
		_squad_buttons[squad_id] = card

	if _is_hero_mode():
		_build_hero_focus_card()

	var right := PanelContainer.new()
	right.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	right.position = Vector2(-450, 62)
	right.size = Vector2(430, 690)
	right.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(right)
	var right_box := VBoxContainer.new()
	right_box.add_theme_constant_override("separation", 7)
	right.add_child(right_box)

	var title_row := HBoxContainer.new()
	right_box.add_child(title_row)
	var ai_title := Label.new()
	ai_title.text = "岚 · AI副官"
	ai_title.add_theme_font_size_override("font_size", 22)
	ai_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_row.add_child(ai_title)
	_agent_state = Label.new()
	_agent_state.text = "● 战术链路在线"
	title_row.add_child(_agent_state)

	_context_label = Label.new()
	_context_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_context_label.custom_minimum_size = Vector2(405, 66)
	right_box.add_child(_context_label)

	var quick_row := HBoxContainer.new()
	quick_row.add_theme_constant_override("separation", 6)
	right_box.add_child(quick_row)
	var next_button := Button.new()
	next_button.text = "下一步？"
	next_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	next_button.pressed.connect(_ask_mock_agent.bind("NEXT"))
	quick_row.add_child(next_button)
	var risk_button := Button.new()
	risk_button.text = "风险？"
	risk_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	risk_button.pressed.connect(_ask_mock_agent.bind("RISK"))
	quick_row.add_child(risk_button)
	var status_button := Button.new()
	status_button.text = "战况？"
	status_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	status_button.pressed.connect(_ask_mock_agent.bind("STATUS"))
	quick_row.add_child(status_button)

	_chat_log = RichTextLabel.new()
	_chat_log.bbcode_enabled = true
	_chat_log.fit_content = false
	_chat_log.scroll_active = true
	_chat_log.custom_minimum_size = Vector2(405, 430)
	right_box.add_child(_chat_log)
	_command_hint = Label.new()
	_command_hint.text = "AI理解：%s · 待命" % _control_display(1)
	_command_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	right_box.add_child(_command_hint)

	var bottom := PanelContainer.new()
	bottom.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	bottom.offset_left = 290
	bottom.offset_right = -470
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
	_command_buttons.clear()
	for item in [
		["legacy.command_move", "移动", "MOVE"],
		["legacy.command_attack", "攻击", "ATTACK"],
		["legacy.command_defend", "防守", "DEFEND"],
		["legacy.command_scout", "侦察", "SCOUT"],
		["legacy.command_retreat", "撤退", "RETREAT"],
		["legacy.command_stop", "停止", "STOP"]
	]:
		var button := Button.new()
		button.custom_minimum_size = Vector2(105, 62)
		button.pressed.connect(_begin_command.bind(item[2]))
		cmd_row.add_child(button)
		_command_buttons.append({"button": button, "action_id": item[0], "label": item[1]})
	_refresh_command_captions()
	var input_row := HBoxContainer.new()
	bottom_box.add_child(input_row)
	_input = LineEdit.new()
	if _is_hero_mode():
		_input.placeholder_text = "对岚说：去前面看看；下一步做什么；这里危险吗……"
	else:
		_input.placeholder_text = "对岚说：二队向右侦察；评估风险；一队原地防守……"
	_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_input.text_submitted.connect(_on_text_submitted)
	_input.focus_entered.connect(_input_runtime.EnterTextInputMode)
	_input.focus_exited.connect(_input_runtime.ExitTextInputMode)
	input_row.add_child(_input)
	var send := Button.new()
	send.text = "发送"
	send.pressed.connect(func(): _on_text_submitted(_input.text))
	input_row.add_child(send)


func _build_hero_focus_card():
	# Placeholder portrait card. The actual portrait can replace this button later.
	_hero_focus_card = Button.new()
	_hero_focus_card.name = "HeroFocusCard"
	_hero_focus_card.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	_hero_focus_card.offset_left = 190.0
	_hero_focus_card.offset_right = 280.0
	_hero_focus_card.offset_top = -160.0
	_hero_focus_card.offset_bottom = -54.0
	_hero_focus_card.text = "F1\n先锋\n双击锁定"
	_hero_focus_card.tooltip_text = "单击 F1：选中先锋英雄\n双击 F1：锁定/解除镜头跟随"
	_hero_focus_card.mouse_filter = Control.MOUSE_FILTER_STOP
	_hero_focus_card.pressed.connect(_select_hero)
	_hero_focus_card.gui_input.connect(_on_hero_focus_card_gui_input)
	add_child(_hero_focus_card)


func _handle_hero_focus_hotkey():
	_select_hero()
	var now_msec := Time.get_ticks_msec()
	if now_msec - _last_f1_press_msec <= F1_DOUBLE_TAP_MS:
		_last_f1_press_msec = -100000
		_toggle_hero_camera_lock()
	else:
		_last_f1_press_msec = now_msec
		_update_hero_focus_card()


func _on_hero_focus_card_gui_input(event: InputEvent):
	if (
		event is InputEventMouseButton
		and event.pressed
		and event.button_index == MOUSE_BUTTON_LEFT
		and event.double_click
	):
		_select_hero()
		_toggle_hero_camera_lock()
		accept_event()


func _select_hero():
	var hero: Node3D = _get_hero_unit()
	if hero == null:
		_append_ai("先锋英雄尚未接入战场。")
		return
	active_squad = 1
	Utils.Match.select_units(Utils.Set.from_array([hero]))
	_refresh_squad_ui()
	squad_selected.emit(1)


func _toggle_hero_camera_lock():
	var hero: Node3D = _get_hero_unit()
	if hero == null:
		_append_ai("无法锁定镜头：先锋英雄尚未接入战场。")
		return
	var camera: Camera3D = get_viewport().get_camera_3d()
	if camera == null:
		_append_ai("无法锁定镜头：当前没有可用的主摄像机。")
		return

	if _hero_camera_locked:
		if camera.has_method("clear_follow_target"):
			camera.clear_follow_target()
		_hero_camera_locked = false
		_append_ai("镜头已解除先锋英雄跟随。")
	else:
		if camera.has_method("set_follow_target"):
			camera.set_follow_target(hero)
		elif camera.has_method("set_position_safely"):
			camera.set_position_safely(hero.global_position)
		_hero_camera_locked = true
		_append_ai("镜头已锁定先锋英雄。双击 F1 可解除跟随。")
	_update_hero_focus_card()


func _get_hero_unit() -> Node3D:
	var hero_units = get_tree().get_nodes_in_group("campaign_hero")
	for unit in hero_units:
		if unit is Node3D and unit.is_in_group("controlled_units"):
			return unit as Node3D
	return null


func _update_hero_focus_card():
	if _hero_focus_card == null:
		return
	_hero_focus_card.text = (
		"F1\n先锋\n跟随中"
		if _hero_camera_locked
		else "F1\n先锋\n双击锁定"
	)


func _select_squad(squad_id: int):
	if squad_id not in _control_ids():
		return
	active_squad = squad_id
	var units = _get_squad_units(squad_id)
	if units.is_empty():
		if _is_hero_mode():
			_append_ai("先锋单位尚未接入战场。")
		else:
			_append_ai("%d %s 尚未由任务系统建立。" % [squad_id, SQUAD_NAMES[squad_id]])
	else:
		Utils.Match.select_units(Utils.Set.from_array(units))
	_refresh_squad_ui()
	squad_selected.emit(squad_id)


func _get_squad_units(squad_id: int) -> Array:
	return get_tree().get_nodes_in_group("legacy_ai_squad_%d" % squad_id).filter(
		func(unit): return unit.is_in_group("controlled_units")
	)


func _begin_command(command: String):
	if _get_squad_units(active_squad).is_empty():
		_append_ai("无法执行：%s 还没有可控单位。" % _control_display(active_squad))
		return
	match command:
		"DEFEND":
			_execute_defend()
		"STOP":
			_execute_stop()
		"MOVE", "SCOUT", "RETREAT":
			pending_command = command
			_append_ai("理解你的意图：让%s%s。请在地图上右键指定位置，我会把目标交给 RTS 执行层。" % [_control_display(active_squad), COMMAND_LABELS[command]])
		"ATTACK":
			pending_command = command
			_append_ai("理解你的意图：让%s攻击指定目标。请右键选择敌方单位。" % _control_display(active_squad))
	_refresh_squad_ui()


func _execute_defend():
	var units = _get_squad_units(active_squad).filter(
		func(unit): return unit.attack_range != null
	)
	if units.is_empty() or not _submit_public_squad_command(
		func(gateway, player):
			return gateway.SetEngagementStance(
				units,
				"Guard" if _is_hero_mode() else "HoldGround",
				player
			)
	):
		_append_ai("命令未执行：当前小队没有可设置防守姿态的单位或公共命令入口不可用。")
		return
	squad_status[active_squad] = "警戒中" if _is_hero_mode() else "固守中"
	pending_command = ""
	_append_ai("命令已下达：%s原地警戒。我会继续关注任务状态。" % _control_display(active_squad))
	_refresh_squad_ui()
	squad_command_executed.emit(active_squad, "DEFEND")


func _execute_stop():
	var units = _get_squad_units(active_squad)
	if not _submit_public_squad_command(
		func(gateway, player): return gateway.StopUnits(units, player)
	):
		_append_ai("命令未执行：公共停止命令拒绝或入口不可用。")
		return
	squad_status[active_squad] = "待命"
	pending_command = ""
	_append_ai("命令已下达：%s停止当前任务，重新进入待命。" % _control_display(active_squad))
	_refresh_squad_ui()
	squad_command_executed.emit(active_squad, "STOP")


## 通过小队拥有者的公共 Gateway 提交冻结 HUD 命令，至少一个单位接受时返回 true。
func _submit_public_squad_command(submit: Callable) -> bool:
	var units = _get_squad_units(active_squad)
	if units.is_empty():
		return false
	var player = units[0].player
	var gateway = player.find_child("UnitCommandGateway")
	if gateway == null:
		push_error("Legacy AI HUD cannot find UnitCommandGateway")
		return false
	var result: Dictionary = submit.call(gateway, player)
	return result.get("status", "Rejected") in ["Accepted", "PartiallyAccepted"]


func _on_unit_died(unit):
	var camera = find_parent("Match").get_node_or_null("IsometricCamera3D")
	if camera != null and camera.get_follow_target() == unit:
		camera.clear_follow_target()
		_hero_camera_locked = false
	_refresh_squad_ui()


func _on_terrain_targeted(_position):
	if pending_command not in ["MOVE", "SCOUT", "RETREAT"]:
		return
	var executed_command = pending_command
	var label = COMMAND_LABELS[executed_command]
	squad_status[active_squad] = "%s中" % label
	_append_ai("已确认地图目标。%s开始%s；路线由底层 RTS 系统执行。" % [_control_display(active_squad), label])
	pending_command = ""
	_refresh_squad_ui()
	squad_command_executed.emit(active_squad, executed_command)


func _on_unit_targeted(unit, _target_position):
	if pending_command != "ATTACK":
		return
	if not unit.is_in_group("adversary_units"):
		_append_ai("这个目标不是已确认敌方单位，我不会替你执行攻击。")
		return
	squad_status[active_squad] = "交战中"
	_append_ai("敌方目标已确认。%s开始集火 %s。" % [_control_display(active_squad), unit.type])
	pending_command = ""
	_refresh_squad_ui()
	squad_command_executed.emit(active_squad, "ATTACK")


func _on_text_submitted(text: String):
	var command_text := text.strip_edges()
	if command_text.is_empty() or _mock_agent_busy:
		return
	player_text_submitted.emit(command_text)
	_append_player(command_text)
	_input.clear()
	_mock_agent_busy = true
	_set_agent_state("● 岚正在分析……")
	await get_tree().create_timer(0.28).timeout

	var question := _parse_ai_question(command_text)
	if not question.is_empty():
		_respond_to_ai_question(question)
		_mock_agent_busy = false
		_set_agent_state("● 战术链路在线")
		return

	var squad_id = _parse_squad(command_text)
	if squad_id != -1:
		_select_squad(squad_id)
	var command = _parse_command(command_text)
	if command.is_empty():
		_append_ai("我理解到这是一个战术意图，但当前模拟链路还不能安全转换成执行命令。你可以直接说‘去前面看看’、‘原地警戒’、‘攻击目标’，或者问我‘下一步做什么’。")
		_mock_agent_busy = false
		_set_agent_state("● 战术链路在线")
		return
	_append_ai("我的理解：%s需要%s。%s" % [_control_display(active_squad), COMMAND_LABELS[command], _command_reasoning(command)])
	_begin_command(command)
	_mock_agent_busy = false
	_set_agent_state("● 战术链路在线")


func _parse_ai_question(text: String) -> String:
	if text.contains("下一步") or text.contains("怎么办") or text.contains("做什么") or text.contains("去哪") or text.contains("建议"):
		return "NEXT"
	if text.contains("风险") or text.contains("危险") or text.contains("安全吗") or text.contains("敌情"):
		return "RISK"
	if text.contains("战况") or text.contains("情况") or text.contains("状态") or text.contains("任务是什么") or text.contains("目标是什么"):
		return "STATUS"
	return ""


func _ask_mock_agent(question: String):
	if _mock_agent_busy:
		return
	_mock_agent_busy = true
	_set_agent_state("● 岚正在分析……")
	await get_tree().create_timer(0.22).timeout
	_respond_to_ai_question(question)
	_mock_agent_busy = false
	_set_agent_state("● 战术链路在线")


func _respond_to_ai_question(question: String):
	match question:
		"NEXT":
			_append_ai("建议：%s\n理由：这一步与当前任务目标直接相关，我不会假设战争迷雾外存在未确认目标。" % _current_suggestion)
		"RISK":
			_append_ai("当前风险评估：%s。这个判断只基于任务脚本已经确认的信息；未知区域仍按未知处理。" % _current_risk)
		"STATUS":
			_append_ai("当前目标：%s\n%s状态：%s。" % [_current_objective, _control_display(active_squad), squad_status[active_squad]])


func _command_reasoning(command: String) -> String:
	match command:
		"SCOUT":
			return "我会把它当成侦察意图，而不是直接假定前方存在敌人。"
		"RETREAT":
			return "这是脱离当前区域的意图，具体撤退位置仍由你确认。"
		"DEFEND":
			return "这是原地保持警戒的安全命令，不需要额外目标点。"
		"STOP":
			return "这是立即中断当前任务的安全命令。"
		"ATTACK":
			return "攻击必须由你确认一个已识别敌方目标。"
		_:
			return "移动方向需要你在地图上确认，避免 AI 擅自决定路线。"


func _parse_squad(text: String) -> int:
	if _is_hero_mode():
		return 1
	for pair in [[1, ["一队", "1队", "第一队"]], [2, ["二队", "2队", "第二队"]], [3, ["三队", "3队", "第三队"]]]:
		for token in pair[1]:
			if text.contains(token):
				return pair[0]
	return -1


func _parse_command(text: String) -> String:
	if text.contains("不要追") or text.contains("防守") or text.contains("守住") or text.contains("原地守") or text.contains("警戒"):
		return "DEFEND"
	if text.contains("侦察") or text.contains("探路") or text.contains("搜索") or text.contains("看看"):
		return "SCOUT"
	if text.contains("撤退") or text.contains("撤离") or text.contains("后撤") or text.contains("返回"):
		return "RETREAT"
	if text.contains("停止") or text.contains("停下") or text.contains("待命"):
		return "STOP"
	if text.contains("攻击") or text.contains("集火") or text.contains("打掉"):
		return "ATTACK"
	if text.contains("移动") or text.contains("前进") or text.contains("去") or text.contains("绕"):
		return "MOVE"
	return ""


func _refresh_command_captions():
	for item in _command_buttons:
		var key := ""
		if _input_runtime != null and _input_runtime.has_method("GetBinding"):
			key = str(_input_runtime.GetBinding(item.action_id)).strip_edges()
		item.button.text = "%s\n%s" % [key if not key.is_empty() else "-", item.label]


func _refresh_squad_ui():
	for squad_id in _control_ids():
		if not _squad_buttons.has(squad_id):
			continue
		var prefix = "▶ " if squad_id == active_squad else ""
		var count = _get_squad_units(squad_id).size()
		_squad_buttons[squad_id].text = "%s%s  · %d\n%s" % [prefix, _control_display(squad_id), count, squad_status[squad_id]]
	_command_hint.text = "AI理解：%s · %s%s" % [_control_display(active_squad), squad_status[active_squad], " · 等待你确认目标" if not pending_command.is_empty() else ""]
	_update_hero_focus_card()


func refresh_control_ui():
	_refresh_squad_ui()


func set_agent_context(objective: String, suggestion: String, risk: String):
	_current_objective = objective
	_current_suggestion = suggestion
	_current_risk = risk
	_refresh_agent_context()


func _refresh_agent_context():
	if _context_label == null:
		return
	_context_label.text = "当前态势：%s\n风险：%s" % [_current_objective, _current_risk]


func _set_agent_state(text: String):
	if _agent_state != null:
		_agent_state.text = text


func post_agent_message(speaker: String, text: String):
	_chat_log.append_text("[color=#8ee6b2]%s[/color]\n%s\n\n" % [speaker, text])
	_chat_log.scroll_to_line(_chat_log.get_line_count())


func _append_player(text: String):
	_chat_log.append_text("[color=#a8c7ff]你[/color]\n%s\n\n" % text)
	_chat_log.scroll_to_line(_chat_log.get_line_count())


func _append_ai(text: String):
	post_agent_message("岚 · AI副官", text)


func _is_hero_mode() -> bool:
	return control_mode == "hero"


func _control_ids() -> Array:
	return [1] if _is_hero_mode() else [1, 2, 3]


func _control_display(squad_id: int) -> String:
	if _is_hero_mode():
		return hero_name
	return "%d %s" % [squad_id, SQUAD_NAMES[squad_id]]
