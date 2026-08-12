extends PanelContainer

var actions_controller: Node = null
var _is_force_move_targeting := false

@onready var _force_move_button: Button = %ForceMoveButton
@onready var _halt_button: Button = %HaltButton
@onready var _feedback_label: Label = %FeedbackLabel


func _ready():
	assert(actions_controller != null, "TraditionalUnitCommandHUD requires UnitActionsController")
	_force_move_button.pressed.connect(_on_force_move_pressed)
	_halt_button.pressed.connect(_on_halt_pressed)
	actions_controller.command_targeting_changed.connect(_on_command_targeting_changed)
	actions_controller.command_feedback.connect(_on_command_feedback)
	MatchSignals.unit_selected.connect(func(_unit): _refresh_availability())
	MatchSignals.unit_deselected.connect(func(_unit): _refresh_availability())
	MatchSignals.unit_died.connect(func(_unit): _refresh_availability.call_deferred())
	_refresh_availability()


func _on_force_move_pressed():
	if _is_force_move_targeting:
		actions_controller.cancel_command_targeting()
		return
	if actions_controller.get_selected_command_unit_count() == 0:
		_feedback_label.text = "请先选择已支持的单位"
		return
	actions_controller.begin_force_move_targeting()


func _on_halt_pressed():
	actions_controller.cancel_command_targeting()
	actions_controller.halt_selected_units()


func _on_command_targeting_changed(is_targeting: bool):
	_is_force_move_targeting = is_targeting
	_force_move_button.text = "取消强制移动" if is_targeting else "强制移动"
	if is_targeting:
		_feedback_label.text = "请右键地面指定强制移动目标"


func _on_command_feedback(
	command_name: String, accepted_count: int, rejected_count: int, status: String
):
	var display_name := "强制移动" if command_name == "ForceMove" else "停止移动"
	_feedback_label.text = "%s：接受 %d，拒绝 %d（%s）" % [
		display_name, accepted_count, rejected_count, status
	]


func _refresh_availability():
	var has_supported_units: bool = actions_controller.get_selected_command_unit_count() > 0
	_force_move_button.disabled = not has_supported_units
	_halt_button.disabled = not has_supported_units
	if not has_supported_units:
		actions_controller.cancel_command_targeting()
		_feedback_label.text = "选择 Tank 后可下达传统 RTS 命令"
