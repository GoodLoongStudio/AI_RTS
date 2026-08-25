extends PanelContainer

var actions_controller: Node = null
var _targeting_command := ""
var _input_runtime = null

@onready var _force_move_button: Button = %ForceMoveButton
@onready var _halt_button: Button = %HaltButton
@onready var _force_attack_button: Button = %ForceAttackButton
@onready var _tactical_withdraw_button: Button = %TacticalWithdrawButton
@onready var _ground_attack_move_button: Button = %GroundAttackMoveButton
@onready var _aggressive_button: Button = %AggressiveButton
@onready var _guard_button: Button = %GuardButton
@onready var _hold_ground_button: Button = %HoldGroundButton
@onready var _hold_fire_button: Button = %HoldFireButton
@onready var _clear_rally_point_button: Button = %ClearRallyPointButton
@onready var _feedback_label: Label = %FeedbackLabel


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
		"取消撤退" if _targeting_command == "TacticalWithdraw" else "撤退",
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
	_clear_rally_point_button.text = _caption("清除集结", "unit.clear_rally")


func _on_command_targeting_changed(command_name: String):
	_targeting_command = command_name
	_refresh_command_captions()
	_refresh_hold_fire_caption()
	if command_name == "ForceMove":
		_feedback_label.text = "请右键地面指定强制移动目标"
	elif command_name == "ForceAttack":
		_feedback_label.text = "请右键单位或地面指定强制攻击目标"
	elif command_name == "TacticalWithdraw":
		_feedback_label.text = "请右键地面指定撤退目的地"
	elif command_name == "GroundAttackMove":
		_feedback_label.text = "请右键地面或敌方单位指定移动并攻击目标"


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
		"TacticalWithdraw": "撤退",
		"GroundAttackMove": "移动并攻击",
		"EntityAttackMove": "移动并攻击",
		"Aggressive": "侵略姿态",
		"Guard": "警戒姿态",
		"HoldGround": "固守姿态",
		"HoldFire": "停火",
		"FireAtWill": "自由开火",
		"SetRallyPoint": "设置集结点",
		"ClearRallyPoint": "清除集结点",
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
	_hold_fire_button.disabled = not has_policy_units
	_clear_rally_point_button.disabled = not has_rally_producers
	if not has_supported_units:
		actions_controller.cancel_command_targeting()
		_feedback_label.text = "选择单位或生产建筑后可下达适用的传统 RTS 命令"
	_refresh_policy_buttons()


func _refresh_policy_buttons():
	if actions_controller == null:
		return
	var stance: String = actions_controller.get_selected_combat_policy("EngagementStance")
	var fire_policy: String = actions_controller.get_selected_combat_policy("FirePolicy")
	_aggressive_button.button_pressed = stance == "Aggressive"
	_guard_button.button_pressed = stance == "Guard"
	_hold_ground_button.button_pressed = stance == "HoldGround"
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
