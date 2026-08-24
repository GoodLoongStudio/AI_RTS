extends PanelContainer

const Unit = preload("res://source/match/units/Unit.gd")
const Moving = preload("res://source/match/units/actions/Moving.gd")

const GROUND_LEVEL_PLANE = Plane(Vector3.UP, 0)
const MINIMAP_PIXELS_PER_WORLD_METER = 2
const MINIMAP_UI_SIZE = Vector2(176, 176)
const CAMERA_INDICATOR_COLOR = Color(0.35, 0.93, 1.0, 0.95)
const CAMERA_FOOTPRINT_COLOR = Color(0.35, 0.93, 1.0, 0.10)

var _unit_to_corresponding_node_mapping = {}
var _camera_movement_active = false
var _camera_footprint: Polygon2D
var _map_size := Vector2.ZERO

@onready var _match = find_parent("Match")
@onready var _camera_indicator = find_child("CameraIndicator") as Line2D
@onready var _viewport_background = find_child("Background")
@onready var _texture_rect = find_child("MinimapTextureRect")


func _ready():
	if not FeatureFlags.show_minimap:
		queue_free()
		return
	_remove_dummy_nodes()
	_configure_fixed_minimap_layout()
	_configure_camera_indicator()
	await _match.ready  # make sure Match is ready as it may change map on setup
	_map_size = _match.find_child("Map").size
	find_child("MinimapViewport").size = _map_size * MINIMAP_PIXELS_PER_WORLD_METER
	_texture_rect.gui_input.connect(_on_gui_input)
	_update_camera_indicator()


func _configure_fixed_minimap_layout():
	# A ViewportTexture reports its native render size as TextureRect minimum size by default.
	# Large world maps therefore used to expand the HUD minimap itself. Ignore texture size and
	# keep the HUD footprint fixed; STRETCH_KEEP_ASPECT_CENTERED handles visual scaling.
	_texture_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_texture_rect.custom_minimum_size = Vector2.ZERO
	custom_minimum_size = Vector2.ZERO
	clip_contents = true
	var outer_container := get_parent() as Control
	if outer_container != null:
		outer_container.custom_minimum_size = MINIMAP_UI_SIZE
		outer_container.offset_left = 0.0
		outer_container.offset_top = -MINIMAP_UI_SIZE.y
		outer_container.offset_right = MINIMAP_UI_SIZE.x
		outer_container.offset_bottom = 0.0


func _configure_camera_indicator():
	# Standard RTS minimap camera footprint: a translucent polygon plus a bright outline.
	_camera_indicator.default_color = CAMERA_INDICATOR_COLOR
	_camera_indicator.width = 2.0
	_camera_indicator.antialiased = true
	_camera_indicator.z_index = 101

	_camera_footprint = Polygon2D.new()
	_camera_footprint.name = "CameraFootprint"
	_camera_footprint.color = CAMERA_FOOTPRINT_COLOR
	_camera_footprint.z_index = 100
	_camera_indicator.get_parent().add_child(_camera_footprint)


func _process(_delta):
	# Camera movement itself is render-frame smooth, so the minimap footprint should follow it
	# every rendered frame instead of lagging behind on physics ticks.
	_update_camera_indicator()


func _physics_process(_delta):
	_sync_real_units_with_minimap_representations()


func _remove_dummy_nodes():
	for dummy_node in find_children("EditorOnlyDummy*"):
		dummy_node.queue_free()


func _sync_real_units_with_minimap_representations():
	var units_synced = {}
	var units_to_sync = (
		get_tree().get_nodes_in_group("units") + get_tree().get_nodes_in_group("resource_units")
	)
	for unit in units_to_sync:
		if not unit.visible:
			continue
		units_synced[unit] = 1
		if not _unit_is_mapped(unit):
			_map_unit(unit)
		_sync_unit(unit)
	for mapped_unit in _unit_to_corresponding_node_mapping:
		if not mapped_unit in units_synced:
			_cleanup_mapping(mapped_unit)


func _unit_is_mapped(unit):
	return unit in _unit_to_corresponding_node_mapping


func _map_unit(unit):
	var node_representing_unit = ColorRect.new()
	node_representing_unit.size = Vector2(3, 3)
	if not unit is Unit:
		node_representing_unit.rotation_degrees = 45
	_viewport_background.add_sibling(node_representing_unit)
	node_representing_unit.pivot_offset = node_representing_unit.size / 2.0
	_unit_to_corresponding_node_mapping[unit] = node_representing_unit


func _sync_unit(unit):
	var unit_pos_3d = unit.global_transform.origin
	var unit_pos_2d = Vector2(unit_pos_3d.x, unit_pos_3d.z) * MINIMAP_PIXELS_PER_WORLD_METER
	_unit_to_corresponding_node_mapping[unit].position = unit_pos_2d
	var mapped_color := Color.WHITE
	if unit is Unit:
		var owner_player = unit.player
		if owner_player != null and "color" in owner_player:
			mapped_color = owner_player.color
	else:
		mapped_color = unit.color
	_unit_to_corresponding_node_mapping[unit].color = mapped_color


func _cleanup_mapping(unit):
	_unit_to_corresponding_node_mapping[unit].queue_free()
	_unit_to_corresponding_node_mapping.erase(unit)


func _update_camera_indicator():
	if _camera_indicator == null or _camera_footprint == null or _map_size == Vector2.ZERO:
		return
	var viewport := get_viewport()
	var camera := viewport.get_camera_3d()
	if camera == null:
		_camera_indicator.hide()
		_camera_footprint.hide()
		return

	var viewport_size := Vector2(viewport.size)
	var camera_corners := [
		Vector2.ZERO,
		Vector2(viewport_size.x, 0.0),
		viewport_size,
		Vector2(0.0, viewport_size.y),
	]
	var minimap_points := PackedVector2Array()
	for screen_corner in camera_corners:
		var intersection = GROUND_LEVEL_PLANE.intersects_ray(
			camera.project_ray_origin(screen_corner),
			camera.project_ray_normal(screen_corner)
		)
		if intersection == null:
			_camera_indicator.hide()
			_camera_footprint.hide()
			return

		# Keep the footprint readable when the camera reaches a map edge. The actual screen corner
		# may project outside the playable world, but the minimap should show the visible in-map part.
		var world_x := clampf(intersection.x, 0.0, _map_size.x)
		var world_z := clampf(intersection.z, 0.0, _map_size.y)
		minimap_points.append(
			Vector2(world_x, world_z) * MINIMAP_PIXELS_PER_WORLD_METER
		)

	_camera_footprint.polygon = minimap_points
	var outline_points := PackedVector2Array(minimap_points)
	outline_points.append(minimap_points[0])
	_camera_indicator.points = outline_points
	_camera_indicator.show()
	_camera_footprint.show()


func _texture_rect_position_to_world_position(position_2d_within_texture_rect):
	assert(
		_texture_rect.stretch_mode == _texture_rect.STRETCH_KEEP_ASPECT_CENTERED,
		"world 3d position retrieval algorithm assumes 'STRETCH_KEEP_ASPECT_CENTERED'"
	)
	var texture_rect_size = _texture_rect.size
	var texture_size = _texture_rect.texture.get_size()
	var proportions = texture_rect_size / texture_size
	var scaling_factor = proportions.x if proportions.x < proportions.y else proportions.y
	var scaled_texture_size = texture_size * scaling_factor
	var scaled_texture_position_within_texture_rect = (
		(texture_rect_size - scaled_texture_size) / 2.0
	)
	var rect_containing_scaled_texture = Rect2(
		scaled_texture_position_within_texture_rect, scaled_texture_size
	)
	if rect_containing_scaled_texture.has_point(position_2d_within_texture_rect):
		var position_2d_within_minimap = (
			(position_2d_within_texture_rect - rect_containing_scaled_texture.position)
			/ scaling_factor
		)
		return position_2d_within_minimap / MINIMAP_PIXELS_PER_WORLD_METER
	return null


func _try_teleporting_camera_based_on_local_texture_rect_position(position_2d_within_texture_rect):
	var world_position_2d = _texture_rect_position_to_world_position(
		position_2d_within_texture_rect
	)
	if world_position_2d == null:
		return
	var world_position_3d = Vector3(world_position_2d.x, 0, world_position_2d.y)
	get_viewport().get_camera_3d().set_position_safely(world_position_3d)


func _issue_movement_action(position_2d_within_texture_rect):
	var world_position_2d = _texture_rect_position_to_world_position(
		position_2d_within_texture_rect
	)
	if world_position_2d == null:
		return
	var abstract_world_position_3d = Vector3(world_position_2d.x, 0, world_position_2d.y)
	var camera = get_viewport().get_camera_3d()
	var target_point_on_colliding_surface = camera.get_ray_intersection(
		camera.unproject_position(abstract_world_position_3d)
	)
	if target_point_on_colliding_surface == null:
		return
	MatchSignals.terrain_targeted.emit(target_point_on_colliding_surface)


func _on_gui_input(event):
	if event is InputEventMouseButton:
		if event.is_pressed() and event.button_index == MOUSE_BUTTON_LEFT:
			_try_teleporting_camera_based_on_local_texture_rect_position(event.position)
			_camera_movement_active = true
		if not event.is_pressed() and event.button_index == MOUSE_BUTTON_LEFT:
			_camera_movement_active = false
		if event.is_pressed() and event.button_index == MOUSE_BUTTON_RIGHT:
			_issue_movement_action(event.position)
	elif event is InputEventMouseMotion and _camera_movement_active:
		_try_teleporting_camera_based_on_local_texture_rect_position(event.position)
