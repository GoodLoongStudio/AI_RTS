extends Node3D

enum BlueprintPositionValidity {
	VALID,
	COLLIDES_WITH_OBJECT,
	NOT_NAVIGABLE,
	NOT_ENOUGH_RESOURCES,
	OUT_OF_MAP,
	NOT_VISIBLE,
}

const ROTATION_BY_KEY_STEP = 45.0
const ROTATION_DEAD_ZONE_DISTANCE = 0.1

const MATERIALS_ROOT = "res://source/match/resources/materials/"
const BLUEPRINT_VALID_PATH = MATERIALS_ROOT + "blueprint_valid.material.tres"
const BLUEPRINT_INVALID_PATH = MATERIALS_ROOT + "blueprint_invalid.material.tres"

var _active_blueprint_node = null
var _pending_structure_prototype = null
var _pending_construction_workers := []
var _blueprint_rotating = false

@onready var _player = get_parent()
@onready var _match = find_parent("Match")
@onready var _feedback_label = find_child("FeedbackLabel3D")
@onready var _placement_runtime = _match.find_child("StructurePlacementRuntime")
@onready var _balance_runtime = _match.find_child("BalanceConfigRuntime")
@onready var _input_runtime = _match.get_node("InputBindingRuntime")


func _ready():
	_feedback_label.hide()
	if not _match.is_node_ready():
		await _match.ready
	if _match.get_local_player() != _player:
		return
	MatchSignals.place_structure.connect(_on_structure_placement_request)
	_input_runtime.connect("ActionPressed", _on_input_action_pressed)


func _unhandled_input(event):
	if not _structure_placement_started():
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		_handle_lmb_down_event(event)
	if (
		event is InputEventMouseButton
		and event.button_index == MOUSE_BUTTON_LEFT
		and not event.pressed
	):
		_handle_lmb_up_event(event)
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT:
		_handle_rmb_event(event)
	if event is InputEventMouseMotion:
		_handle_mouse_motion_event(event)


func _handle_lmb_down_event(_event):
	get_viewport().set_input_as_handled()
	_start_blueprint_rotation()


func _handle_lmb_up_event(_event):
	get_viewport().set_input_as_handled()
	var blueprint_position_validity = _calculate_blueprint_position_validity()
	if blueprint_position_validity == BlueprintPositionValidity.VALID:
		_finish_structure_placement()
	elif blueprint_position_validity == BlueprintPositionValidity.NOT_ENOUGH_RESOURCES:
		MatchSignals.not_enough_resources_for_construction.emit(_player)
	_finish_blueprint_rotation()


func _handle_rmb_event(event):
	get_viewport().set_input_as_handled()
	if event.pressed:
		_finish_blueprint_rotation()
		_cancel_structure_placement()


func _handle_mouse_motion_event(_event):
	get_viewport().set_input_as_handled()
	if _blueprint_rotation_started():
		_rotate_blueprint_towards_mouse_pos()
	else:
		_set_blueprint_position_based_on_mouse_pos()
	var blueprint_position_validity = _calculate_blueprint_position_validity()
	_update_feedback_label(blueprint_position_validity)
	_update_blueprint_color(blueprint_position_validity == BlueprintPositionValidity.VALID)


func _structure_placement_started():
	return _active_blueprint_node != null


func _blueprint_rotation_started():
	return _blueprint_rotating == true


func _calculate_blueprint_position_validity():
	var evaluation = _placement_runtime.Evaluate(
		_player,
		_pending_structure_prototype,
		_active_blueprint_node.global_transform,
		{}  # ECO-007B：Legacy 参数保留兼容，权威成本由 C# Catalog 查询。
	)
	match evaluation["primary_issue"]:
		"":
			return BlueprintPositionValidity.VALID
		"NotVisible":
			return BlueprintPositionValidity.NOT_VISIBLE
		"OutOfBounds":
			return BlueprintPositionValidity.OUT_OF_MAP
		"InsufficientResources":
			return BlueprintPositionValidity.NOT_ENOUGH_RESOURCES
		"Occupied", "FriendlyDisplacementUnavailable":
			return BlueprintPositionValidity.COLLIDES_WITH_OBJECT
		_:
			return BlueprintPositionValidity.NOT_NAVIGABLE


func _update_feedback_label(blueprint_position_validity):
	_feedback_label.visible = (blueprint_position_validity != BlueprintPositionValidity.VALID)
	match blueprint_position_validity:
		BlueprintPositionValidity.COLLIDES_WITH_OBJECT:
			_feedback_label.text = tr("BLUEPRINT_COLLIDES_WITH_OBJECT")
		BlueprintPositionValidity.NOT_NAVIGABLE:
			_feedback_label.text = tr("BLUEPRINT_NOT_NAVIGABLE")
		BlueprintPositionValidity.NOT_ENOUGH_RESOURCES:
			_feedback_label.text = tr("BLUEPRINT_NOT_ENOUGH_RESOURCES")
		BlueprintPositionValidity.OUT_OF_MAP:
			_feedback_label.text = tr("BLUEPRINT_OUT_OF_MAP")
		BlueprintPositionValidity.NOT_VISIBLE:
			_feedback_label.text = tr("BLUEPRINT_NOT_VISIBLE")


func _start_structure_placement(structure_prototype):
	if _structure_placement_started():
		return
	_pending_structure_prototype = structure_prototype
	_pending_construction_workers = get_tree().get_nodes_in_group("selected_units").filter(
		func(unit):
			return (
				unit.is_in_group("controlled_units")
				and unit.has_method("request_legacy_construct")
			)
	)
	var blueprint_path = _balance_runtime.GetBlueprintScenePath(structure_prototype)
	assert(not blueprint_path.is_empty(), "structure is missing blueprint asset mapping")
	_active_blueprint_node = load(blueprint_path).instantiate()
	var blueprint_origin = Vector3(-999, 0, -999)
	var camera_direction_yless = (
		(get_viewport().get_camera_3d().project_ray_normal(Vector2(0, 0)) * Vector3(1, 0, 1))
		. normalized()
	)
	var rotate_towards = blueprint_origin + camera_direction_yless.rotated(Vector3.UP, PI * 0.75)
	_active_blueprint_node.global_transform = Transform3D(Basis(), blueprint_origin).looking_at(
		rotate_towards, Vector3.UP
	)
	add_child(_active_blueprint_node)
	_input_runtime.SetContextActive("BuildPlacement", true)


func _set_blueprint_position_based_on_mouse_pos():
	var mouse_pos_2d = get_viewport().get_mouse_position()
	var mouse_pos_3d = get_viewport().get_camera_3d().get_ray_intersection(mouse_pos_2d)
	if mouse_pos_3d == null:
		return
	_active_blueprint_node.global_transform.origin = mouse_pos_3d
	_feedback_label.global_transform.origin = mouse_pos_3d


func _update_blueprint_color(blueprint_position_is_valid):
	var material_to_set = (
		preload(BLUEPRINT_VALID_PATH)
		if blueprint_position_is_valid
		else preload(BLUEPRINT_INVALID_PATH)
	)
	for child in _active_blueprint_node.find_children("*"):
		if "material_override" in child:
			child.material_override = material_to_set


func _cancel_structure_placement():
	if _structure_placement_started():
		_feedback_label.hide()
		_active_blueprint_node.queue_free()
		_active_blueprint_node = null
	_pending_construction_workers = []
	_input_runtime.SetContextActive("BuildPlacement", false)


func _finish_structure_placement():
	if NetSession.should_forward_commands():
		# 联机傀儡端：放置必须转发到权威服务器（此前只在本地产出建筑, 服务器毫不知情）。
		var match_node := find_parent("Match")
		var sync := match_node.get_node_or_null("NetSync") if match_node != null else null
		if sync != null:
			var transform: Transform3D = _active_blueprint_node.global_transform
			sync.forward_command(
				"place_structure",
				_pending_construction_workers,
				transform.origin,
				null,
				_player,
				_pending_structure_prototype.resource_path
				+ "|"
				+ str(transform.basis.get_euler().y)
			)
			_pending_construction_workers = []
			_input_runtime.SetContextActive("BuildPlacement", false)
			_active_blueprint_node.queue_free()
			_active_blueprint_node = null
			return
	var result = _placement_runtime.Place(
		_player,
		_pending_structure_prototype,
		_active_blueprint_node.global_transform,
		{}  # ECO-007B：Legacy 参数保留兼容，权威成本由 C# Catalog 查询。
	)
	if result["accepted"]:
		_placement_runtime.AssignBuilders(
			_pending_construction_workers,
			result["structure"],
			_player,
			result["displaced_unit_ids"]
		)
		_cancel_structure_placement()
	elif result["primary_issue"] == "InsufficientResources":
		MatchSignals.not_enough_resources_for_construction.emit(_player)


func _start_blueprint_rotation():
	_blueprint_rotating = true


func _try_rotating_blueprint_by(degrees):
	if not _structure_placement_started():
		return
	_active_blueprint_node.global_transform.basis = (
		_active_blueprint_node.global_transform.basis.rotated(Vector3.UP, deg_to_rad(degrees))
	)


func _rotate_blueprint_towards_mouse_pos():
	var mouse_pos_2d = get_viewport().get_mouse_position()
	var mouse_pos_3d = get_viewport().get_camera_3d().get_ray_intersection(mouse_pos_2d)
	if mouse_pos_3d == null:
		return
	var mouse_pos_yless = mouse_pos_3d * Vector3(1, 0, 1)
	var blueprint_pos_3d = _active_blueprint_node.global_transform.origin
	var blueprint_pos_yless = blueprint_pos_3d * Vector3(-999, 0, -999)
	if mouse_pos_yless.distance_to(blueprint_pos_yless) < ROTATION_DEAD_ZONE_DISTANCE:
		return
	var rotation_target = Vector3(mouse_pos_yless.x, blueprint_pos_3d.y, mouse_pos_yless.z)
	if rotation_target.is_equal_approx(_active_blueprint_node.global_transform.origin):
		return
	_active_blueprint_node.global_transform = _active_blueprint_node.global_transform.looking_at(
		rotation_target, Vector3.UP
	)


func _finish_blueprint_rotation():
	_blueprint_rotating = false


func _on_structure_placement_request(structure_prototype):
	_start_structure_placement(structure_prototype)


func _on_input_action_pressed(action_id: String):
	if action_id == "build.rotate":
		_try_rotating_blueprint_by(ROTATION_BY_KEY_STEP)
		return
	if action_id == "global.cancel" and _structure_placement_started():
		_finish_blueprint_rotation()
		_cancel_structure_placement()
