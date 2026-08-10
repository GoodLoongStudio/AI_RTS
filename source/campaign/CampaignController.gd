extends Node

var mission_data: Dictionary = {}

var _objective_index := -1
var _transitioning := false
var _mission_started_msec := 0
var _objective_label: Label
var _story_label: Label
var _extract_button: Button
var _ai_hud = null
var _hero = null


func _ready():
	await get_tree().physics_frame
	_mission_started_msec = Time.get_ticks_msec()
	_build_mission_hud()
	_ai_hud = get_parent().get_node_or_null("HUD/AICommandHUD")
	_setup_initial_control()
	if _ai_hud != null:
		_ai_hud.squad_selected.connect(_on_squad_selected)
		_ai_hud.squad_command_executed.connect(_on_squad_command_executed)
		_ai_hud.refresh_control_ui()
	await _play_briefing()
	_set_objective(0)


func _physics_process(_delta: float):
	if _transitioning or _hero == null or not is_instance_valid(_hero):
		return
	var marker_name := _get_current_objective_marker()
	if marker_name.is_empty():
		return
	var marker = get_parent().get_node_or_null("Map/CampaignZones/%s" % marker_name)
	if marker == null:
		return
	var hero_position: Vector3 = _hero.global_position * Vector3(1, 0, 1)
	var marker_position: Vector3 = marker.global_position * Vector3(1, 0, 1)
	if hero_position.distance_to(marker_position) <= float(mission_data.get("objective_radius", 7.5)):
		_reach_objective_location(_objective_index)


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


func _setup_initial_control():
	var controlled_units = get_tree().get_nodes_in_group("controlled_units")
	for unit in controlled_units:
		for squad_id in [1, 2, 3]:
			unit.remove_from_group("unit_group_%d" % squad_id)

	if mission_data.get("initial_control_mode", "squad") == "hero":
		if controlled_units.is_empty():
			return
		_hero = controlled_units[0]
		_hero.add_to_group("unit_group_1")
		Utils.Match.select_units(Utils.Set.from_array([_hero]))
		return

	var mobile_units = controlled_units.filter(func(unit): return unit.find_child("Movement") != null)
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
	var objective_text := str(objectives[index])
	_objective_label.text = "当前目标：%s" % objective_text
	_sync_agent_context(index, objective_text)


func _sync_agent_context(index: int, objective_text: String):
	if _ai_hud == null:
		return
	var suggestion := "按当前任务目标行动，必要时先询问我。"
	var risk := "未知"
	match index:
		0:
			suggestion = "先让先锋单位前往信号门，途中只处理已经确认的威胁。"
			risk = "低 · 尚未获得可靠敌情"
		1:
			suggestion = "进入外围营地前先观察道路和建筑边缘，不要为了探索主动深入未知区域。"
			risk = "中 · 通讯不稳定，外围情况未确认"
		2:
			suggestion = "沿道路推进到废弃车队，优先找到重复求救信号源。"
			risk = "中 · 信号异常，但敌情仍未确认"
		3:
			suggestion = "在车队附近原地警戒，让我读取黑箱信标，不要继续向纵深推进。"
			risk = "中 · 单兵停留读取数据，机动能力暂时降低"
		4:
			suggestion = "携带黑箱信标沿已走过的路线返回外围紧急撤离点。"
			risk = "中 · 已取得关键情报，继续深入收益低于风险"
		5:
			suggestion = "确认信标数据完整后请求撤离，结束本次侦察。"
			risk = "低 · 已到达已确认撤离区域"
	_ai_hud.set_agent_context(objective_text, suggestion, risk)


func _complete_current_objective():
	var objectives: Array = mission_data.get("objectives", [])
	if _objective_index >= 0 and _objective_index < objectives.size():
		_story_label.text = "已完成：%s" % objectives[_objective_index]


func _get_current_objective_marker() -> String:
	var markers: Dictionary = mission_data.get("objective_markers", {})
	return str(markers.get(_objective_index, ""))


func _reach_objective_location(index: int):
	_transitioning = true
	_complete_current_objective()
	match index:
		0:
			_post_story("岚 · AI副官", "已到达信号门。前方进入通讯不稳定区；建议先观察道路和外围营地，不要假定战争迷雾后存在什么。")
			_set_objective(1)
		1:
			_post_story("岚 · AI副官", "外围营地确认无人值守。地面有近期拖拽痕迹，但这些痕迹本身不能证明敌方仍在附近。")
			_post_story("岚 · AI副官", "东侧道路上检测到重复信号。继续向废弃车队推进。")
			_set_objective(2)
		2:
			_post_story("岚 · AI副官", "找到信号源。时间戳异常——这不是实时求救，它已经重复播放了至少 63 小时。")
			_post_story("岚 · AI副官", "车队中有一个仍在工作的黑箱信标。请原地警戒，我开始读取。")
			_set_objective(3)
		4:
			_post_story("岚 · AI副官", "已抵达外围紧急撤离点，信标数据完整。现在可以结束本次侦察。")
			_set_objective(5)
			_extract_button.visible = true
	_transitioning = false


func _on_squad_selected(_squad_id: int):
	pass


func _on_squad_command_executed(squad_id: int, command: String):
	if _transitioning:
		return
	if _objective_index == 3 and squad_id == 1 and command in ["DEFEND", "STOP"]:
		_transitioning = true
		_complete_current_objective()
		_post_story("岚 · AI副官", "先锋单位保持警戒。正在读取黑箱信标……")
		await get_tree().create_timer(2.0).timeout
		_post_story("岚 · AI副官", "读取完成。里面有北辰区域更深处的通讯碎片，但当前单兵继续深入风险过高。")
		_post_story("岚 · AI副官", "先把数据带回去。下一次行动，正式战术小队会接入你的指挥链。")
		_set_objective(4)
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
	result.text = "撤离方式：外围紧急撤离\n作战时间：%02d:%02d\n控制单位：先锋指挥单元\n取得情报：北辰黑箱信标 01\n发现：求救信号并非实时发送\n\n序章完成。下一次进入北辰区域时，战术小队将逐步加入，游戏从单英雄操作过渡到真正的 AI RTS 指挥。" % [elapsed_seconds / 60, elapsed_seconds % 60]
	result.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	result.add_theme_font_size_override("font_size", 19)
	result.size_flags_vertical = Control.SIZE_EXPAND_FILL
	box.add_child(result)

	var return_button := Button.new()
	return_button.text = "返回单人战役"
	return_button.custom_minimum_size = Vector2(0, 56)
	return_button.pressed.connect(func(): get_tree().change_scene_to_file("res://source/campaign/CampaignMenu.tscn"))
	box.add_child(return_button)
