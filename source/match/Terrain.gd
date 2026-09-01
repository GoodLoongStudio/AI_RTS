extends StaticBody3D

@onready var _collision_shape = find_child("CollisionShape3D")


func _ready():
	input_event.connect(_on_input_event)


func update_shape(reference_mesh):
	_collision_shape.shape = reference_mesh.create_trimesh_shape()


func _on_input_event(_camera, event, _click_position, _click_normal, _shape_idx):
	if (
		event is InputEventMouseButton
		and event.button_index == MOUSE_BUTTON_RIGHT
		and event.pressed
	):
		var target_point = get_viewport().get_camera_3d().get_ray_intersection(event.position)
		if target_point == null:
			return
		MatchSignals.terrain_targeted.emit(target_point)
		get_viewport().set_input_as_handled()


func _unhandled_input(event: InputEvent):
	# Physics picking can miss the map body while its runtime trimesh is being
	# rebuilt or when the camera is over an uncovered edge. Preserve the RTS
	# right-click contract by falling back to a ray-plane target, but leave unit
	# clicks to their own Targetability handlers.
	if not (
		event is InputEventMouseButton
		and event.button_index == MOUSE_BUTTON_RIGHT
		and event.pressed
	):
		return
	var camera := get_viewport().get_camera_3d()
	if camera == null:
		return
	var ray_from := camera.project_ray_origin(event.position)
	var ray_to := ray_from + camera.project_ray_normal(event.position) * 1000.0
	var query := PhysicsRayQueryParameters3D.create(ray_from, ray_to)
	query.collision_mask = 0xFFFFFFFF
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if not hit.is_empty() and hit.get("collider") != self:
		return
	var target_point = camera.get_ray_intersection(event.position)
	if target_point != null:
		MatchSignals.terrain_targeted.emit(target_point)
