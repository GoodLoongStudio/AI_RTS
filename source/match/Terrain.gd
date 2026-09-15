extends StaticBody3D

@onready var _collision_shape = find_child("CollisionShape3D")


func _ready():
	input_event.connect(_on_input_event)


func update_shape(reference_mesh):
	# Generated G4 terrain keeps a dense 1025x1025 visual grid (~2M triangles).
	# Feeding that mesh directly to ConcavePolygonShape3D makes the physics server
	# spend tens of milliseconds per frame even though large G4 maps skip nav bake.
	# Use a decimated heightfield collision for large generated maps; the visual
	# MeshInstance3D remains full resolution and blockers/bridges keep their own
	# authoritative collision shapes.
	if reference_mesh is ArrayMesh and reference_mesh.get_surface_count() > 0:
		# ⚠️ 必须显式注解：`surface_get_arrays()` 的返回值在 API 里无类型，
		# 用 `:=` 会触发 "Cannot infer the type of arrays" ⇒ 项目把该告警当错误
		# ⇒ 整个 Terrain.gd 不加载 ⇒ `Match._setup_subsystems_dependent_on_map()` 在
		# `_terrain.update_shape()` 处中断（报 Nonexistent function in base 'StaticBody3D'）
		# ⇒ 依赖该子系统的一批用例全红或挂死。
		var arrays: Array = reference_mesh.surface_get_arrays(0)
		var src: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var count := src.size()
		var side := int(round(sqrt(float(count))))
		if side > 256 and side * side == count:
			var stride := 16
			var xs: Array[int] = []
			var zs: Array[int] = []
			for i in range(0, side, stride):
				xs.append(i)
				zs.append(i)
			if xs.back() != side - 1:
				xs.append(side - 1)
			if zs.back() != side - 1:
				zs.append(side - 1)
			var verts := PackedVector3Array()
			verts.resize(xs.size() * zs.size())
			for zj in range(zs.size()):
				for xi in range(xs.size()):
					verts[zj * xs.size() + xi] = src[zs[zj] * side + xs[xi]]
			var indices := PackedInt32Array()
			indices.resize((xs.size() - 1) * (zs.size() - 1) * 6)
			var k := 0
			for zj in range(zs.size() - 1):
				for xi in range(xs.size() - 1):
					var a := zj * xs.size() + xi
					var b := a + xs.size()
					indices[k] = a
					indices[k + 1] = b
					indices[k + 2] = a + 1
					indices[k + 3] = a + 1
					indices[k + 4] = b
					indices[k + 5] = b + 1
					k += 6
			var reduced := ArrayMesh.new()
			var reduced_arrays := []
			reduced_arrays.resize(Mesh.ARRAY_MAX)
			reduced_arrays[Mesh.ARRAY_VERTEX] = verts
			reduced_arrays[Mesh.ARRAY_INDEX] = indices
			reduced.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, reduced_arrays)
			_collision_shape.shape = reduced.create_trimesh_shape()
			print("TERRAIN_COLLISION decimated ", count, " verts -> ", verts.size(), " verts")
			return
	_collision_shape.shape = reference_mesh.create_trimesh_shape()


func disable_runtime_collision() -> void:
	"""Disable the terrain trimesh for large generated maps.

	Generated G4 maps use a 1025x1025 render grid. Converting that mesh to a
	trimesh creates over a million physics vertices and dominates the physics
	step even though terrain units do not collide with this body and large-map
	navigation baking is intentionally skipped. Mouse targeting already has a
	plane fallback in _unhandled_input, so no gameplay contract is lost.
	"""
	if _collision_shape != null:
		_collision_shape.shape = null
	collision_layer = 0
	collision_mask = 0
	remove_from_group("terrain_navigation_input")


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
