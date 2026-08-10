extends Node

var mission_data: Dictionary = {}

var _objective_index := -1
var _transitioning := false
var _mission_started_msec := 0
var _objective_label: Label
var _story_label: Label
var _extract_button: Button
var _ai_hud = null


func _ready():
	await get_tree().physics_frame
	_mission_started_msec = Time.get_ticks_msec()
	_build_mission_hud()
	_auto_assign_squads()
	_ai_hud = get_parent().get_node_or_null("HUD/AICommandHUD")
	if _ai_hud != null:
		_ai_hud.squad_selected.connect(_on_squad_selected)
		_ai_hud.squad_command_executed.connect(_on_squad_command_executed)
	await _play_briefing()
	_set_objective(0)


func _build_mission_hud():
	var hud = get_parent().get_node("HUD")
	var panel := PanelContainer.new()
	panel.name = "CampaignMissionHUD"
	panel.position = Vector2(300, 22)
	panel.size = Vector2(650, 142)
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud.add_child(panel)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	panel.add_child(box)

	var title := Label.new()
	title.text = "%s  ·  %s" % [mission_data.get("chapter", "单人战役"), mission_data.get("title", "任务")]
	title.add_theme_font_size_override("font_size", 19)
	box.add_child(title)

	_objective_label = Label.new()
	_objective_label.text = "当前目标：等待任务简报"
	_objective_label.add_theme_font_size_override("font_size", 20)
	box.add_child(_objective_label)

	_story_label = Label.new()
	_story_label.text = "AI 副官正在建立战区态势……"
	_story_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_story_label)

	_extract_button = Button.new()
	_extract_button.text = "请求撤离"
	_extract_button.visible = false
	_extract_button.mouse_filter = Control.MOUSE_FILTER_STOP
	_extract_button.pressed.connect(_on_extract_pressed)
	box.add_child(_extract_button)


func _auto_assign_squads():
	var mobile_units = get_tree().get_nodes_in_group("controlled_units").filter(
		func(unit): return unit.find_child("Movement") != null
	)
	for unit in mobile_units:
		for squad_id in [1, 2, 3]:
			unit.remove_from_group("unit_group_%d" % squad_id)
	for index in range(min(3, mobile_units.size())):
		mobile_units[index].add_to_group("unit_group_%d" % (index + 1))


func _play_briefing():
	for line in mission_data.get("briefing", []):
		_post_story(line[0], line[1])
		await get_tree().create_timer(1.25).timeout


func _set_objective(index: int):
	_objective_index = index
	var objectives: Array = mission_data.get("objectives", [])
	if index < 0 or index >= objectives.size():
		_objective_label.text = "当前目标：任务完成"
		return
	_objective_label.text = "当前目标：%s" % objectives[index]


func _complete_current_objective():
	var objectives: Array = mission_data.get("objectives", [])
	if _objective_index >= 0 and _objective_index < objectives.size():
		_story_label.text = "已完成：%s" % objectives[_objective_index]


func _on_squad_selected(squad_id: int):
	if _objective_index == 0 and squad_id == 2:
		_complete_current_objective()
		_post_story("岚 · AI副官", "侦察二队已接入指挥链。建议让他们先覆盖外围营地区域。")
		_set_objective(1)


func _on_squad_command_executed(squad_id: int, command: String):
	if _transitioning:
		return
	if _objective_index == 1 and squad_id == 2 and command in ["SCOUT", "MOVE"]:
		_transitioning = true
		_complete_current_objective()
		_post_story("隼 · 侦察队长", "收到。二队前出，保持低姿态。")
		await get_tree().create_timer(2.5).timeout
		_post_story("岚 · AI副官", "发现求救信号源。但时间戳异常——这不是实时求救，它已经重复播放了至少 63 小时。")
		_post_story("岚 · AI副官", "附近存在无法确认的热源。建议一队先建立防御，不要追击。")
		_set_objective(2)
		_transitioning = false
		return

	if _objective_index == 2 and squad_id == 1 and command == "DEFEND":
		_complete_current_objective()
		_post_story("磐石 · 突击队长", "一队就地展开。我们守住这里，不主动追出去。")
		_post_story("隼 · 侦察队长", "前面有一支废弃车队。我看到了一个还在工作的信标。")
		_set_objective(3)
		return

	if _objective_index == 3 and squad_id == 1 and command == "MOVE":
		_transitioning = true
		_complete_current_objective()
		_post_story("岚 · AI副官", "突击一队开始前推。当前没有足够证据确认敌方规模。")
		await get_tree().create_timer(2.5).timeout
		_post_story("隼 · 侦察队长", "确认了，是侦察队留下的黑箱信标。外壳受损，但核心数据还能读取。")
		_post_story("岚 · AI副官", "我们已经取得第一份可靠情报。继续深入的风险正在上升，现阶段可以撤离。")
		_set_objective(4)
		_extract_button.visible = true
		_transitioning = false


func _post_story(speaker: String, text: String):
	_story_label.text = "%s：%s" % [speaker, text]
	if _ai_hud != null:
		_ai_hud.post_agent_message(speaker, text)


func _on_extract_pressed():
	_extract_button.disabled = true
	_complete_current_objective()
	for line in mission_data.get("epilogue", []):
		_post_story(line[0], line[1])
	_show_result()


func _show_result():
	var hud = get_parent().get_node("HUD")
	var overlay := ColorRect.new()
	overlay.name = "CampaignResult"
	overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	overlay.color = Color(0.02, 0.03, 0.05, 0.88)
	overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	hud.add_child(overlay)

	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.position = Vector2(-310, -230)
	panel.size = Vector2(620, 460)
	overlay.add_child(panel)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 14)
	panel.add_child(box)

	var title := Label.new()
	title.text = "任务完成 · 回声撤离"
	title.add_theme_font_size_override("font_size", 30)
	box.add_child(title)

	var elapsed_seconds := int((Time.get_ticks_msec() - _mission_started_msec) / 1000.0)
	var result := Label.new()
	result.text = "撤离方式：外围紧急撤离\n作战时间：%02d:%02d\n取得情报：北辰黑箱信标 01\n发现：求救信号并非实时发送\n\n本次序章已完成。后续版本将把此流程接入专用北辰战役地图、幸存者事件、地下维修通道与多种撤离路线。" % [elapsed_seconds / 60, elapsed_seconds % 60]
	result.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	result.add_theme_font_size_override("font_size", 19)
	result.size_flags_vertical = Control.SIZE_EXPAND_FILL
	box.add_child(result)

	var return_button := Button.new()
	return_button.text = "返回单人战役"
	return_button.custom_minimum_size = Vector2(0, 56)
	return_button.pressed.connect(func(): get_tree().change_scene_to_file("res://source/campaign/CampaignMenu.tscn"))
	box.add_child(return_button)
