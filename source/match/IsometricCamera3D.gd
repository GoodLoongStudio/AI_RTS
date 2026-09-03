extends Camera3D

const EXPECTED_X_ROTATION_DEGREES = -30.0
const EXPECTED_PROJECTION = PROJECTION_ORTHOGONAL

@export_group("Size")
@export var size_min = 1
@export var size_max = 20
@export_group("Movement")
@export var edge_scroll_enabled = true
@export var screen_margin_for_movement = 48.0  # px
@export var bottom_screen_margin_for_movement = 72.0  # px; bottom HUD needs a wider reliable edge zone
@export var movement_speed = 1.1
@export var movement_acceleration = 10.0
@export var movement_deceleration = 14.0
@export var bounding_planes: Array[Plane] = []
@export_group("Rotation")
@export var mouse_rotation_speed = 0.005  # [rad/px]
@export var arrowkey_rotation_speed = 2  # [rad/s]
@export var default_y_rotation_degrees = 0.0
@export var reference_plane_for_rotation = Plane(Vector3.UP, 0.0)
@export_group("View")
@export var visible_height_min = -10
@export var visible_height_max = 10
@export var zoom_step = 1.0

var _mouse_pos_when_rotation_started = null
var _camera_global_pos_when_rotation_started = null
var _smoothed_screen_move_vector := Vector2.ZERO
var _follow_target: Node3D = null
var _map_extents := Vector2.ZERO
@onready var _input_runtime = get_parent().get_node("InputBindingRuntime")


func _ready():
	# 无头/专用服上没有玩家输入，_input_runtime 是不带 GetAxis 的裸节点，
	# 相机纯表现层——直接停掉处理，避免对局期每帧刷 SCRIPT ERROR。
	if DisplayServer.get_name() == "headless" or NetSession.is_dedicated_server():
		set_process(false)
		set_process_input(false)
		set_process_unhandled_input(false)
		return
	assert(projection == EXPECTED_PROJECTION, "unexpected projection")
	assert(
		is_equal_approx(rotation_degrees.x, EXPECTED_X_ROTATION_DEGREES), "unexptected X rotation"
	)
	_apply_user_camera_options()
	_align_camera_properties_to_current_size()
	_input_runtime.connect("ActionPressed", _on_input_action_pressed)
	MatchSignals.unit_died.connect(_on_followed_unit_died)
	# 窗口大小变化会改变宽高比，拉远上限与视野夹紧需随之重算。
	get_viewport().size_changed.connect(
		func():
			set_size_safely(size)
			_align_position_to_bounding_planes()
	)


func _on_input_action_pressed(action_id: String):
	if action_id != "camera.focus_latest_event":
		return
	focus_latest_battlefield_event()


## 解除镜头跟随并跳到最近一条玩家可知的重要战场事件。
func focus_latest_battlefield_event() -> bool:
	var event_runtime = get_parent().get_node_or_null("BattlefieldEventRuntime")
	if event_runtime == null:
		return false
	var focus: Dictionary = event_runtime.TryGetLatestImportantFocus()
	if focus.is_empty():
		return false
	clear_follow_target()
	set_position_safely(focus["position"])
	return true


func _apply_user_camera_options():
	# Edge scrolling is on by default; the player can still disable it in camera options.
	# Keyboard camera movement remains available through the same movement path.
	edge_scroll_enabled = (
		FeatureFlags.enable_edge_scroll
		and bool(Globals.get_camera_option("edge_scroll_enabled"))
	)
	movement_speed = float(Globals.get_camera_option("movement_speed"))
	screen_margin_for_movement = float(Globals.get_camera_option("edge_margin"))
	bottom_screen_margin_for_movement = float(Globals.get_camera_option("bottom_edge_margin"))
	var smoothing: float = maxf(float(Globals.get_camera_option("smoothing")), 0.1)
	movement_acceleration = smoothing
	movement_deceleration = smoothing * 1.4
	zoom_step = maxf(float(Globals.get_camera_option("zoom_step")), 0.05)


func _process(delta: float):
	# Camera movement is visual feedback and should update on render frames rather than
	# the fixed physics tick. This avoids visible stepping on 90/120/144 Hz displays.
	var realtime_delta = delta
	if not is_zero_approx(Engine.time_scale):
		realtime_delta /= Engine.time_scale

	if is_following_target():
		# Follow mode intentionally suppresses edge/keyboard translation so the tracked hero
		# remains centered. Zoom and rotation stay available because they do not break the lock.
		_smoothed_screen_move_vector = Vector2.ZERO
		set_position_safely(_follow_target.global_position)
		_try_handling_arrowkey_rotation(realtime_delta)
		return

	if _try_handling_movement(realtime_delta):
		return
	_try_handling_arrowkey_rotation(realtime_delta)


func _unhandled_input(event: InputEvent):
	_try_handling_zoom(event)
	_try_handling_mouse_rotation(event)


func set_follow_target(target: Node3D):
	_follow_target = target
	_smoothed_screen_move_vector = Vector2.ZERO
	if is_instance_valid(_follow_target):
		set_position_safely(_follow_target.global_position)


func clear_follow_target():
	_follow_target = null
	_smoothed_screen_move_vector = Vector2.ZERO


func is_following_target() -> bool:
	if _follow_target != null and not is_instance_valid(_follow_target):
		_follow_target = null
	return _follow_target != null


func get_follow_target() -> Node3D:
	return _follow_target if is_following_target() else null


func _on_followed_unit_died(unit):
	if _follow_target == unit:
		clear_follow_target()


func set_size_safely(a_size: float):
	var clamped_size = clampf(a_size, size_min, _effective_size_max())
	if clamped_size == size:
		return
	size = clamped_size
	_align_camera_properties_to_current_size()
	_align_position_to_bounding_planes()
	if is_following_target():
		set_position_safely(_follow_target.global_position)


## 由 Match 按地图尺寸调用；之后拉远上限随地图与窗口宽高比动态收紧。
func set_map_extents(extents: Vector2):
	_map_extents = extents
	set_size_safely(size)


## 拉远上限：正交 size 是垂直视线平面的高度，30° 俯角下地面可见纵深约
## 2×size、宽度约 size×宽高比。除轴对齐约束外，还按当前 Y 轴旋转角计算
## 视野矩形的地面投影 AABB——旋转到对角方向时上限自动收紧，保证任何
## 旋转角度下视野都完整落在地图内，看不到地图外的黑色背景。
func _effective_size_max() -> float:
	var cap := float(size_max)
	if _map_extents != Vector2.ZERO:
		var viewport_size := get_viewport().get_visible_rect().size
		if viewport_size.x > 0.0 and viewport_size.y > 0.0:
			var aspect := viewport_size.x / viewport_size.y
			var vertical_cap := (
				_map_extents.y * sin(deg_to_rad(absf(EXPECTED_X_ROTATION_DEGREES)))
			)
			var horizontal_cap := _map_extents.x / maxf(aspect, 0.01)
			cap = minf(cap, minf(vertical_cap, horizontal_cap) * 0.85)
			# 按当前旋转角的视野投影半尺寸反推上限（half 随 size 线性增长）。
			var half := _view_half_extents_on_ground()
			if half.x > 0.001 and half.y > 0.001 and size > 0.0:
				var yaw_cap_x := (_map_extents.x * 0.5) / (half.x / size)
				var yaw_cap_y := (_map_extents.y * 0.5) / (half.y / size)
				cap = minf(cap, minf(yaw_cap_x, yaw_cap_y))
	return maxf(cap, size_min)


## 视野矩形在地面上投影的半尺寸（考虑 Y 轴旋转；正交投影下严格成立）。
## 水平半宽 = size×宽高比/2（沿相机右方向），半纵深 = size/(2×sin俯角)
## （沿相机前方向，俯角越低纵深越大）。
func _view_half_extents_on_ground() -> Vector2:
	var viewport_size := get_viewport().get_visible_rect().size
	var aspect := viewport_size.x / maxf(viewport_size.y, 1.0)
	var right2 := Vector2(global_transform.basis.x.x, global_transform.basis.x.z)
	var forward2 := Vector2(-global_transform.basis.z.x, -global_transform.basis.z.z)
	if right2.length() < 0.001 or forward2.length() < 0.001:
		return Vector2.ZERO
	var ground_depth_per_size := 0.5 / maxf(
		sin(deg_to_rad(absf(EXPECTED_X_ROTATION_DEGREES))), 0.01
	)
	right2 = right2.normalized() * size * aspect * 0.5
	forward2 = forward2.normalized() * size * ground_depth_per_size
	return Vector2(abs(right2.x) + abs(forward2.x), abs(right2.y) + abs(forward2.y))


## 视野必须完整落在地图内：屏幕中心点的活动范围 = 地图范围减去视野
## 半尺寸。贴边滚动、小地图跳转、跟随单位时都走这条路径，任何时刻
## 都看不到地图外的黑色背景。
func _clamp_pivot_to_keep_view_inside(pivot: Vector3) -> Vector3:
	if _map_extents == Vector2.ZERO:
		return pivot
	var half := _view_half_extents_on_ground()
	if half.x <= 0.0 or half.y <= 0.0:
		return pivot
	var upper := _map_extents - half
	if upper.x < half.x or upper.y < half.y:
		# 地图比视野还小（理论上 zoom 上限已杜绝），钉在地图中心对称越界。
		return Vector3(_map_extents.x * 0.5, pivot.y, _map_extents.y * 0.5)
	return Vector3(
		clampf(pivot.x, half.x, upper.x), pivot.y, clampf(pivot.z, half.y, upper.y)
	)


## 旋转/缩放后确保视野完整在地图内：必要时按新角度收紧 zoom 并重夹中心。
func _enforce_view_inside_map():
	set_size_safely(size)
	_align_position_to_bounding_planes()


func set_position_safely(target_position: Vector3):
	global_transform.origin = _target_position_to_camera_position(target_position)


func get_ray_intersection(mouse_pos: Vector2) -> Variant:
	return get_ray_intersection_with_plane(mouse_pos, reference_plane_for_rotation)


func get_ray_intersection_with_plane(mouse_pos: Vector2, plane: Plane) -> Variant:
	return plane.intersects_ray(project_ray_origin(mouse_pos), project_ray_normal(mouse_pos))


func _try_handling_movement(delta: float) -> bool:
	if _is_rotating():
		_smoothed_screen_move_vector = Vector2.ZERO
		return false

	var target_screen_move_vector = _calculate_screen_move_vector()
	var response_speed = (
		movement_acceleration
		if not target_screen_move_vector.is_zero_approx()
		else movement_deceleration
	)
	var smoothing_weight = 1.0 - exp(-response_speed * delta)
	_smoothed_screen_move_vector = _smoothed_screen_move_vector.lerp(
		target_screen_move_vector, clamp(smoothing_weight, 0.0, 1.0)
	)

	if (
		target_screen_move_vector.is_zero_approx()
		and _smoothed_screen_move_vector.length_squared() < 0.0001
	):
		_smoothed_screen_move_vector = Vector2.ZERO

	if _smoothed_screen_move_vector.is_zero_approx():
		return false

	var limited_screen_move_vector = _smoothed_screen_move_vector.limit_length(1.0)
	var scaled_screen_move_vector = (
		Vector2(limited_screen_move_vector.x, limited_screen_move_vector.y * 2.0)
		* delta
		* movement_speed
		* size
	)
	var camera_move_vector = (
		Vector3(scaled_screen_move_vector.x, 0, scaled_screen_move_vector.y)
		. rotated(Vector3(0, 1, 0), rotation.y)
	)
	global_translate(camera_move_vector)
	_align_position_to_bounding_planes()
	return true


func _calculate_screen_move_vector() -> Vector2:
	var viewport_size := Vector2(get_viewport().size)
	var mouse_pos := get_viewport().get_mouse_position()
	var keyboard_move_vector := Vector2(
		_input_runtime.GetAxis("camera.move_left", "camera.move_right"),
		_input_runtime.GetAxis("camera.move_up", "camera.move_down")
	).limit_length(1.0)

	# Keyboard movement stays available even when the player disables edge scrolling.
	if not keyboard_move_vector.is_zero_approx():
		return keyboard_move_vector
	if not edge_scroll_enabled:
		return Vector2.ZERO
	if _is_pointer_over_hud():
		return Vector2.ZERO
	return _calculate_edge_scroll_vector(mouse_pos, viewport_size)


## 鼠标停在建造栏、命令栏等会吃点击的 HUD 上时，不贴边移镜头。
func _is_pointer_over_hud() -> bool:
	var hovered := get_viewport().gui_get_hovered_control()
	if hovered == null or not hovered.is_visible_in_tree():
		return false
	return hovered.mouse_filter != Control.MOUSE_FILTER_IGNORE


func _calculate_edge_scroll_vector(mouse_pos: Vector2, viewport_size: Vector2) -> Vector2:
	if viewport_size.x <= 0.0 or viewport_size.y <= 0.0:
		return Vector2.ZERO
	if not Rect2(Vector2.ZERO, viewport_size).has_point(mouse_pos):
		return Vector2.ZERO

	var horizontal_margin = max(screen_margin_for_movement, 1.0)
	var top_margin = horizontal_margin
	var bottom_margin = max(bottom_screen_margin_for_movement, horizontal_margin)

	var left_strength = _edge_strength(mouse_pos.x, horizontal_margin)
	var right_strength = _edge_strength(viewport_size.x - mouse_pos.x, horizontal_margin)
	var top_strength = _edge_strength(mouse_pos.y, top_margin)
	var bottom_strength = _edge_strength(viewport_size.y - mouse_pos.y, bottom_margin)

	return Vector2(
		right_strength - left_strength,
		bottom_strength - top_strength
	).limit_length(1.0)


func _edge_strength(distance_to_edge: float, margin: float) -> float:
	if distance_to_edge >= margin:
		return 0.0
	var edge_depth = 1.0 - clamp(distance_to_edge / margin, 0.0, 1.0)
	return smoothstep(0.0, 1.0, edge_depth)


func _try_handling_zoom(event: InputEvent):
	if not event is InputEventMouseButton or not event.is_pressed():
		return
	if event.button_index == MOUSE_BUTTON_WHEEL_UP:
		_zoom_in()
	elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
		_zoom_out()


func _zoom_in():
	set_size_safely(size - zoom_step)


func _zoom_out():
	set_size_safely(size + zoom_step)


func _try_handling_arrowkey_rotation(delta: float):
	if _is_rotating():
		return
	var angle_radians = (
		delta
		* _input_runtime.GetAxis("camera.rotate_counterclockwise", "camera.rotate_clockwise")
		* arrowkey_rotation_speed
	)
	if not is_zero_approx(angle_radians):
		_rotate_from_reference_position_by(global_position, angle_radians)
		_enforce_view_inside_map()
		if is_following_target():
			set_position_safely(_follow_target.global_position)


func _try_handling_mouse_rotation(event: InputEvent):
	if event is InputEventMouseButton:
		if event.is_pressed() and event.button_index == MOUSE_BUTTON_MIDDLE and event.double_click:
			_reset_rotation()
		elif event.is_pressed() and event.button_index == MOUSE_BUTTON_MIDDLE:
			_start_rotation(event)
		elif not event.is_pressed() and event.button_index == MOUSE_BUTTON_MIDDLE:
			_stop_rotation()
	elif event is InputEventMouseMotion and _is_rotating():
		var mouse_pos = event.position
		var angle_radians = (
			(mouse_pos.x - _mouse_pos_when_rotation_started.x) * mouse_rotation_speed
		)
		_rotate_from_reference_position_by(_camera_global_pos_when_rotation_started, angle_radians)
		_enforce_view_inside_map()
		if is_following_target():
			set_position_safely(_follow_target.global_position)


func _reset_rotation():
	var pivot_point = _calculate_pivot_point()
	if pivot_point == null:
		return
	var camera_position = global_position
	var camera_position_yless = camera_position * Vector3(1, 0, 1)
	var pivot_point_yless = pivot_point * Vector3(1, 0, 1)
	var pivot_to_camera_distance_yless = camera_position_yless.distance_to(pivot_point_yless)
	var new_camera_position_yless = (
		pivot_point_yless
		- (
			Vector3(0, 0, -1).normalized().rotated(
				-Vector3.UP, deg_to_rad(-default_y_rotation_degrees)
			)
			* pivot_to_camera_distance_yless
			)
	)
	global_position = Vector3(
		new_camera_position_yless.x, camera_position.y, new_camera_position_yless.z
	)
	global_transform = global_transform.looking_at(pivot_point, Vector3(0, 1, 0))
	if is_following_target():
		set_position_safely(_follow_target.global_position)


func _start_rotation(event: InputEvent):
	_mouse_pos_when_rotation_started = event.position
	_camera_global_pos_when_rotation_started = global_transform.origin


func _stop_rotation():
	_mouse_pos_when_rotation_started = null


func _rotate_from_reference_position_by(reference_position: Vector3, angle_radians: float):
	var pivot_point = _calculate_pivot_point()
	if pivot_point == null:
		return
	var diff_vec = reference_position - pivot_point
	var rotated_diff_vec = diff_vec.rotated(-Vector3.UP, angle_radians)
	var rotated_reference_position = pivot_point + rotated_diff_vec
	global_position = rotated_reference_position
	global_transform = global_transform.looking_at(pivot_point, Vector3.UP)


func _is_rotating() -> bool:
	return _mouse_pos_when_rotation_started != null


func _calculate_pivot_point() -> Vector3:
	var screen_center_pos_2d = get_viewport().size / 2.0
	return get_ray_intersection_with_plane(screen_center_pos_2d, reference_plane_for_rotation)


func _align_camera_properties_to_current_size():
	_align_camera_properties_to_size(size)


func _align_camera_properties_to_size(a_size: float):
	_align_camera_position_to_size(a_size)
	_align_camera_far_to_size(a_size)


func _align_camera_position_to_size(a_size: float):
	var alpha_degrees = 60
	var beta_degrees = 90 - alpha_degrees
	var target_height = (
		a_size * sin(deg_to_rad(alpha_degrees)) / 2.0
		+ sin(deg_to_rad(beta_degrees))
		+ visible_height_max
	)
	var target_camera_plane = Plane(Vector3.UP, target_height)
	var camera_ray_normal = project_ray_normal(Vector2(0, 0))
	var target_camera_pos = target_camera_plane.intersects_ray(
		global_transform.origin, camera_ray_normal
	)
	if target_camera_pos == null:
		target_camera_pos = target_camera_plane.intersects_ray(
			global_transform.origin, -camera_ray_normal
		)
	global_transform.origin = target_camera_pos


func _align_camera_far_to_size(a_size: float):
	var up = (project_position(Vector2(0, 0), 0) - project_position(Vector2(0, 1), 0)).normalized()
	var camera_ray_begin = project_position(Vector2(0, 0), 0) + up * (a_size - size) / 2.0
	var camera_ray_normal = project_ray_normal(Vector2(0, 0))
	var min_visible_plane = Plane(Vector3.UP, visible_height_min)
	var ray_intersection = min_visible_plane.intersects_ray(camera_ray_begin, camera_ray_normal)
	far = ceil(ray_intersection.distance_to(camera_ray_begin))


func _align_position_to_bounding_planes():
	var pivot_point = _calculate_pivot_point()
	var aligned_pivot_point = _clamp_position_to_bounding_planes(pivot_point)
	var diff = aligned_pivot_point - pivot_point
	global_transform.origin += diff


func _clamp_position_to_bounding_planes(a_position: Vector3) -> Vector3:
	for bounding_plane in bounding_planes:
		if not bounding_plane.is_point_over(a_position):
			a_position = a_position - bounding_plane.normal * bounding_plane.distance_to(a_position)
	return _clamp_pivot_to_keep_view_inside(a_position)


func _target_position_to_camera_position(target_position: Vector3) -> Vector3:
	target_position = _clamp_position_to_bounding_planes(target_position)
	var screen_center_pos_2d = get_viewport().size / 2.0
	var camera_ray = project_ray_normal(screen_center_pos_2d)
	var target_plane = Plane(Vector3.UP, target_position.y)
	var intersection = target_plane.intersects_ray(global_transform.origin, camera_ray)
	var offset_yless = (target_position - intersection) * Vector3(1, 0, 1)
	return global_transform.origin + offset_yless
