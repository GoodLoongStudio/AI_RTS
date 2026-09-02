extends PanelContainer

var actions_controller: Node = null
var _targeting_command := ""
var _input_runtime = null
var _skill_slot_ids: Array[String] = []

const _SKILL_CAPTIONS := {
	"demo_self_heal": "治疗",
	"demo_unit_pulse": "脉冲",
}

@onready var _force_move_button: Button = %ForceMoveButton
@onready var _halt_button: Button = %HaltButton
@onready var _force_attack_button: Button = %ForceAttackButton
@onready var _tactical_withdraw_button: Button = %TacticalWithdrawButton
@onready var _ground_attack_move_button: Button = %GroundAttackMoveButton
@onready var _aggressive_button: Button = %AggressiveButton
@onready var _guard_button: Button = %GuardButton
@onready var _hold_ground_button: Button = %HoldGroundButton
@onready var _return_to_base_button: Button = %ReturnToBaseButton
@onready var _hold_fire_button: Button = %HoldFireButton
@onready var _clear_rally_point_button: Button = %ClearRallyPointButton
@onready var _feedback_label: Label = %FeedbackLabel
@onready var _skill_slots: HBoxContainer = %SkillSlots
@onready var _selected_info_label: Label = %SelectedInfoLabel

## 选中摘要的单位类型显示名（RA3 情境窗口的单位名栏等价物）。
const _UNIT_DISPLAY_NAMES := {
	"worker": "工人",
	"tank": "坦克",
	"command_center": "指挥中心",
	"vehicle_factory": "车辆工厂",
	"aircraft_factory": "航空工厂",
	"helicopter": "直升机",
	"drone": "无人机",
	"anti_ground_turret": "对地炮",
	"anti_air_turret": "对空炮",
}


func _ready():
	assert(actions_controller != null, "TraditionalUnitCommandHUD requires UnitActionsController")
	_force_move_button.pressed.connect(_on_force_move_pressed)
	_force_attack_button.pressed.connect(_on_force_attack_pressed)
	_tactical_withdraw_button.pressed.connect(_on_tactical_withdraw_pressed)
	_ground_attack_move_button.pressed.connect(_on_ground_attack_move_pressed)
	_halt_button.pressed.connect(_on_halt_pressed)
	_aggressive_button.pressed.connect(func(): _set_engagement_stance("Aggressive"))
	_guard_button.pressed.connect(func(): _set_engagement_stance("Guard"))
	_hold_ground_button.pressed.connect(func(): _set_engagement_stance("HoldGround"))
	_return_to_base_button.pressed.connect(func(): _set_engagement_stance("ReturnToBase"))
	_hold_fire_button.pressed.connect(_toggle_hold_fire)
	_clear_rally_point_button.pressed.connect(actions_controller.clear_selected_rally_points)
	actions_controller.command_targeting_changed.connect(_on_command_targeting_changed)
	actions_controller.command_feedback.connect(_on_command_feedback)
	_input_runtime = find_parent("Match").get_node_or_null("InputBindingRuntime")
	if _input_runtime != null:
		_input_runtime.connect("ActionPressed", _on_input_action_pressed)
	MatchSignals.unit_selected.connect(func(_unit): _refresh_availability())
	MatchSignals.unit_deselected.connect(func(_unit): _refresh_availability())
	MatchSignals.unit_died.connect(func(_unit): _refresh_availability.call_deferred())
	_refresh_command_captions()
	_refresh_availability()
	_refresh_skill_slots()
	_apply_ra3_skin()


## RA3 风格皮肤：深色金属面板 + 紧凑按钮（配合右侧指挥侧栏的视觉语言）。
func _apply_ra3_skin():
	var panel = StyleBoxFlat.new()
	panel.bg_color = Color(0.09, 0.10, 0.12, 0.96)
	panel.border_color = Color(0.45, 0.50, 0.55)
	panel.set_border_width_all(1)
	panel.set_corner_radius_all(4)
	add_theme_stylebox_override("panel", panel)
	for button in find_children("", "Button", true, false):
		_style_ra3_button(button)
	_feedback_label.add_theme_font_size_override("font_size", 11)
	_feedback_label.add_theme_color_override("font_color", Color(0.62, 0.53, 0.28))
	_selected_info_label.add_theme_font_size_override("font_size", 12)
	_selected_info_label.add_theme_color_override("font_color", Color(0.95, 0.83, 0.42))


func _style_ra3_button(button: Button):
	var normal = StyleBoxFlat.new()
	normal.bg_color = Color(0.05, 0.06, 0.08)
	normal.border_color = Color(0.30, 0.33, 0.36)
	normal.set_border_width_all(1)
	normal.set_corner_radius_all(3)
	var hover = StyleBoxFlat.new()
	hover.bg_color = Color(0.10, 0.13, 0.17)
	hover.border_color = Color(0.40, 0.62, 0.95)
	hover.set_border_width_all(1)
	hover.set_corner_radius_all(3)
	var pressed = StyleBoxFlat.new()
	pressed.bg_color = Color(0.13, 0.17, 0.22)
	pressed.border_color = Color(0.95, 0.83, 0.42)
	pressed.set_border_width_all(1)
	pressed.set_corner_radius_all(3)
	var disabled = StyleBoxFlat.new()
	disabled.bg_color = Color(0.05, 0.055, 0.065)
	disabled.border_color = Color(0.18, 0.19, 0.21)
	disabled.set_border_width_all(1)
	disabled.set_corner_radius_all(3)
	button.add_theme_stylebox_override("normal", normal)
	button.add_theme_stylebox_override("hover", hover)
	button.add_theme_stylebox_override("pressed", pressed)
	button.add_theme_stylebox_override("disabled", disabled)
	button.add_theme_font_size_override("font_size", 12)


## 官方单位快捷键复用同一套 HUD 命令入口，不另建第二套命令语义。
func _on_input_action_pressed(action_id: String):
	match action_id:
		"unit.attack_move":
			_on_ground_attack_move_pressed()
		"unit.stop":
			_on_stop_pressed()
		"unit.stance_hold_ground":
			_set_engagement_stance("HoldGround")
		"unit.stance_aggressive":
			_set_engagement_stance("Aggressive")
		"unit.stance_guard":
			_set_engagement_stance("Guard")
		"unit.stance_return_to_base":
			_set_engagement_stance("ReturnToBase")
		"unit.toggle_hold_fire":
			_toggle_hold_fire()
		"unit.clear_rally":
			actions_controller.clear_selected_rally_points()
		"unit.force_move":
			_on_force_move_pressed()
		"unit.force_attack":
			_on_force_attack_pressed()
		"unit.tactical_withdraw":
			_on_tactical_withdraw_pressed()
		"global.cancel":
			if _targeting_command != "":
				actions_controller.cancel_command_targeting()


func _on_force_move_pressed():
	if _targeting_command == "ForceMove":
		actions_controller.cancel_command_targeting()
		return
	if actions_controller.get_selected_command_unit_count() == 0:
		_feedback_label.text = "请先选择已支持的单位"
		return
	actions_controller.begin_force_move_targeting()


func _on_force_attack_pressed():
	if _targeting_command == "ForceAttack":
		actions_controller.cancel_command_targeting()
		return
	if actions_controller.get_selected_command_unit_count() == 0:
		_feedback_label.text = "请先选择已支持的单位"
		return
	actions_controller.begin_force_attack_targeting()


func _on_halt_pressed():
	actions_controller.cancel_command_targeting()
	actions_controller.halt_selected_units()


func _on_stop_pressed():
	actions_controller.cancel_command_targeting()
	actions_controller.stop_selected_units()


func _on_tactical_withdraw_pressed():
	if _targeting_command == "TacticalWithdraw":
		actions_controller.cancel_command_targeting()
		return
	if actions_controller.get_selected_command_unit_count() == 0:
		_feedback_label.text = "请先选择已支持的单位"
		return
	actions_controller.begin_tactical_withdraw_targeting()


func _on_ground_attack_move_pressed():
	if _targeting_command == "GroundAttackMove":
		actions_controller.cancel_command_targeting()
		return
	if actions_controller.get_selected_command_unit_count() == 0:
		_feedback_label.text = "请先选择已支持的单位"
		return
	actions_controller.begin_ground_attack_move_targeting()


func _set_engagement_stance(stance: String):
	actions_controller.set_selected_engagement_stance(stance)
	_refresh_policy_buttons()


func _toggle_hold_fire():
	var current_policy: String = actions_controller.get_selected_combat_policy("FirePolicy")
	var next_policy := "FireAtWill" if current_policy == "HoldFire" else "HoldFire"
	actions_controller.set_selected_fire_policy(next_policy)
	_refresh_policy_buttons()


func _hotkey(action_id: String) -> String:
	if _input_runtime == null or not _input_runtime.has_method("GetBinding"):
		return ""
	return str(_input_runtime.GetBinding(action_id)).strip_edges()


func _caption(base_text: String, action_id: String) -> String:
	var key := _hotkey(action_id)
	if key.is_empty():
		return base_text
	return "%s [%s]" % [base_text, key]


func _refresh_command_captions():
	_force_move_button.text = _caption(
		"取消强制移动" if _targeting_command == "ForceMove" else "强制移动",
		"unit.force_move"
	)
	_force_attack_button.text = _caption(
		"取消强制攻击" if _targeting_command == "ForceAttack" else "强制攻击",
		"unit.force_attack"
	)
	_tactical_withdraw_button.text = _caption(
		"取消战术后退" if _targeting_command == "TacticalWithdraw" else "战术后退",
		"unit.tactical_withdraw"
	)
	_ground_attack_move_button.text = _caption(
		"取消移动并攻击" if _targeting_command == "GroundAttackMove" else "移动并攻击",
		"unit.attack_move"
	)
	_halt_button.text = "停止移动"
	_aggressive_button.text = _caption("侵略", "unit.stance_aggressive")
	_guard_button.text = _caption("警戒", "unit.stance_guard")
	_hold_ground_button.text = _caption("固守", "unit.stance_hold_ground")
	_return_to_base_button.text = _caption("撤回基地", "unit.stance_return_to_base")
	_clear_rally_point_button.text = _caption("清除集结", "unit.clear_rally")


func _process(_delta):
	_refresh_skill_slot_captions()


func _on_command_targeting_changed(command_name: String):
	_targeting_command = command_name
	_refresh_command_captions()
	_refresh_hold_fire_caption()
	if command_name == "ForceMove":
		_feedback_label.text = "请右键地面指定强制移动目标"
	elif command_name == "ForceAttack":
		_feedback_label.text = "请右键单位或地面指定强制攻击目标"
	elif command_name == "TacticalWithdraw":
		_feedback_label.text = "请右键地面指定战术后退目的地"
	elif command_name == "GroundAttackMove":
		_feedback_label.text = "请右键地面或敌方单位指定移动并攻击目标"
	elif command_name.begins_with("Skill:"):
		_feedback_label.text = "请右键指定技能目标"


func _on_command_feedback(
	command_name: String, accepted_count: int, rejected_count: int, status: String
):
	var display_names := {
		"Move": "移动",
		"ForceMove": "强制移动",
		"Attack": "攻击",
		"HaltMovement": "停止移动",
		"Stop": "停止",
		"ForceAttack": "强制攻击",
		"ForceAttackGround": "地面强制攻击",
		"TacticalWithdraw": "战术后退",
		"GroundAttackMove": "移动并攻击",
		"EntityAttackMove": "移动并攻击",
		"Aggressive": "侵略姿态",
		"Guard": "警戒姿态",
		"HoldGround": "固守姿态",
		"ReturnToBase": "撤回基地姿态",
		"HoldFire": "停火",
		"FireAtWill": "自由开火",
		"SetRallyPoint": "设置集结点",
		"ClearRallyPoint": "清除集结点",
		"demo_self_heal": "治疗",
		"demo_unit_pulse": "脉冲",
	}
	var display_name: String = display_names.get(command_name, command_name)
	if status == "Unreachable":
		_feedback_label.text = "%s：无法到达目标" % display_name
		_refresh_policy_buttons()
		return
	_feedback_label.text = "%s：接受 %d，拒绝 %d（%s）" % [
		display_name, accepted_count, rejected_count, status
	]
	_refresh_policy_buttons()


func _refresh_availability():
	var has_supported_units: bool = actions_controller.get_selected_command_unit_count() > 0
	var has_policy_units: bool = actions_controller.get_selected_combat_policy_unit_count() > 0
	var has_rally_producers: bool = actions_controller.get_selected_rally_producer_count() > 0
	_force_move_button.disabled = not has_supported_units
	_force_attack_button.disabled = not has_supported_units
	_tactical_withdraw_button.disabled = not has_supported_units
	_ground_attack_move_button.disabled = not has_supported_units
	_halt_button.disabled = not has_supported_units
	_aggressive_button.disabled = not has_policy_units
	_guard_button.disabled = not has_policy_units
	_hold_ground_button.disabled = not has_policy_units
	_return_to_base_button.disabled = not has_policy_units
	_hold_fire_button.disabled = not has_policy_units
	_clear_rally_point_button.disabled = not has_rally_producers
	if not has_supported_units:
		actions_controller.cancel_command_targeting()
		_feedback_label.text = "选择单位或生产建筑后可下达适用的传统 RTS 命令"
	_refresh_policy_buttons()
	_refresh_skill_slots()
	_refresh_selected_info()


## RA3 情境窗口的单位摘要：选中集按类型聚合计数。
func _refresh_selected_info():
	var units = get_tree().get_nodes_in_group("selected_units").filter(
		func(unit):
			return is_instance_valid(unit) and unit.is_in_group("controlled_units")
	)
	if units.is_empty():
		_selected_info_label.text = "未选中单位"
		return
	var count_by_type := {}
	for unit in units:
		var type_key := ""
		var scene_path = unit.get("scene_file_path")
		if scene_path != null and str(scene_path) != "":
			type_key = str(scene_path).get_file().trim_suffix(".tscn")
		else:
			type_key = unit.name
		count_by_type[type_key] = int(count_by_type.get(type_key, 0)) + 1
	var parts := []
	for type_key in count_by_type:
		var display: String = _UNIT_DISPLAY_NAMES.get(type_key, type_key)
		parts.append("%s ×%d" % [display, count_by_type[type_key]])
	_selected_info_label.text = "选中: " + "  ".join(parts)


func _refresh_policy_buttons():
	if actions_controller == null:
		return
	var stance: String = actions_controller.get_selected_combat_policy("EngagementStance")
	var fire_policy: String = actions_controller.get_selected_combat_policy("FirePolicy")
	_aggressive_button.button_pressed = stance == "Aggressive"
	_guard_button.button_pressed = stance == "Guard"
	_hold_ground_button.button_pressed = stance == "HoldGround"
	_return_to_base_button.button_pressed = stance == "ReturnToBase"
	_hold_fire_button.button_pressed = fire_policy == "HoldFire"
	_refresh_hold_fire_caption()


func _refresh_hold_fire_caption():
	if actions_controller == null:
		return
	var fire_policy: String = actions_controller.get_selected_combat_policy("FirePolicy")
	_hold_fire_button.text = _caption(
		"恢复开火" if fire_policy == "HoldFire" else "停火",
		"unit.toggle_hold_fire"
	)


func _refresh_skill_slots():
	if actions_controller == null:
		return
	var slots: Array = actions_controller.get_selected_skill_slots()
	var ids: Array[String] = []
	for slot in slots:
		ids.append(str(slot["skill_id"]))
	if ids != _skill_slot_ids:
		_rebuild_skill_buttons(slots)
		_skill_slot_ids = ids
	_refresh_skill_slot_captions()


func _rebuild_skill_buttons(slots: Array):
	for child in _skill_slots.get_children():
		child.queue_free()
	for slot in slots:
		var skill_id: String = str(slot["skill_id"])
		var target: String = str(slot["target"])
		var button := Button.new()
		button.custom_minimum_size = Vector2(122, 28)
		button.set_meta("skill_id", skill_id)
		button.set_meta("target", target)
		button.pressed.connect(_on_skill_pressed.bind(skill_id, target))
		_style_ra3_button(button)
		_skill_slots.add_child(button)


func _refresh_skill_slot_captions():
	if actions_controller == null:
		return
	var slots: Array = actions_controller.get_selected_skill_slots()
	var by_id := {}
	for slot in slots:
		by_id[str(slot["skill_id"])] = slot
	for child in _skill_slots.get_children():
		if not child is Button:
			continue
		var skill_id: String = str(child.get_meta("skill_id"))
		var caption: String = _SKILL_CAPTIONS.get(skill_id, skill_id)
		if _targeting_command == "Skill:%s" % skill_id:
			caption = "取消" + caption
		if by_id.has(skill_id):
			var remaining: int = int(by_id[skill_id]["remaining_milliseconds"])
			child.disabled = remaining > 0
			if remaining > 0:
				caption = "%s %.1fs" % [caption, remaining / 1000.0]
		child.text = caption


func _on_skill_pressed(skill_id: String, target: String):
	if _targeting_command == "Skill:%s" % skill_id:
		actions_controller.cancel_command_targeting()
		return
	if actions_controller.get_selected_command_unit_count() == 0:
		_feedback_label.text = "请先选择已支持的单位"
		return
	actions_controller.begin_skill_use(skill_id, target)
