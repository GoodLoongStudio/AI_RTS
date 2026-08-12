extends PanelContainer

var actions_controller: Node = null
var _targeting_command := ""

@onready var _force_move_button: Button = %ForceMoveButton
@onready var _halt_button: Button = %HaltButton
@onready var _force_attack_button: Button = %ForceAttackButton
@onready var _tactical_withdraw_button: Button = %TacticalWithdrawButton
@onready var _ground_attack_move_button: Button = %GroundAttackMoveButton
@onready var _aggressive_button: Button = %AggressiveButton
@onready var _guard_button: Button = %GuardButton
@onready var _hold_ground_button: Button = %HoldGroundButton
@onready var _hold_fire_button: Button = %HoldFireButton
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
	actions_controller.command_targeting_changed.connect(_on_command_targeting_changed)
	actions_controller.command_feedback.connect(_on_command_feedback)
	MatchSignals.unit_selected.connect(func(_unit): _refresh_availability())
	MatchSignals.unit_deselected.connect(func(_unit): _refresh_availability())
	MatchSignals.unit_died.connect(func(_unit): _refresh_availability.call_deferred())
	_refresh_availability()


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


func _on_command_targeting_changed(command_name: String):
	_targeting_command = command_name
	_force_move_button.text = "取消强制移动" if command_name == "ForceMove" else "强制移动"
	_force_attack_button.text = "取消强制攻击" if command_name == "ForceAttack" else "强制攻击"
	_tactical_withdraw_button.text = (
		"取消撤退" if command_name == "TacticalWithdraw" else "撤退"
	)
	_ground_attack_move_button.text = (
		"取消移动并攻击" if command_name == "GroundAttackMove" else "移动并攻击"
	)
	if command_name == "ForceMove":
		_feedback_label.text = "请右键地面指定强制移动目标"
	elif command_name == "ForceAttack":
		_feedback_label.text = "请右键单位或地面指定强制攻击目标"
	elif command_name == "TacticalWithdraw":
		_feedback_label.text = "请右键地面指定撤退目的地"
	elif command_name == "GroundAttackMove":
		_feedback_label.text = "请右键地面指定移动并攻击目的地"


func _on_command_feedback(
	command_name: String, accepted_count: int, rejected_count: int, status: String
):
	var display_names := {
		"ForceMove": "强制移动",
		"Attack": "攻击",
		"Stop": "停止",
		"ForceAttack": "强制攻击",
		"ForceAttackGround": "地面强制攻击（当前武器不支持）",
		"TacticalWithdraw": "撤退",
		"GroundAttackMove": "移动并攻击",
		"Aggressive": "侵略姿态",
		"Guard": "警戒姿态",
		"HoldGround": "固守姿态",
		"HoldFire": "停火",
		"FireAtWill": "自由开火",
	}
	var display_name: String = display_names.get(command_name, command_name)
	_feedback_label.text = "%s：接受 %d，拒绝 %d（%s）" % [
		display_name, accepted_count, rejected_count, status
	]
	_refresh_policy_buttons()


func _refresh_availability():
	var has_supported_units: bool = actions_controller.get_selected_command_unit_count() > 0
	_force_move_button.disabled = not has_supported_units
	_force_attack_button.disabled = not has_supported_units
	_tactical_withdraw_button.disabled = not has_supported_units
	_ground_attack_move_button.disabled = not has_supported_units
	_halt_button.disabled = not has_supported_units
	_aggressive_button.disabled = not has_supported_units
	_guard_button.disabled = not has_supported_units
	_hold_ground_button.disabled = not has_supported_units
	_hold_fire_button.disabled = not has_supported_units
	if not has_supported_units:
		actions_controller.cancel_command_targeting()
		_feedback_label.text = "选择 Tank 后可下达传统 RTS 命令"
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
	_hold_fire_button.text = "恢复开火" if fire_policy == "HoldFire" else "停火"
