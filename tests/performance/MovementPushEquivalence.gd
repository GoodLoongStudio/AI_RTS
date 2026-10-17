extends Node

const Reference = preload("res://tests/performance/MovementPushReference.gd")
var _checks := 0
var _failures := 0


func _ready() -> void:
	var unit := Node3D.new()
	add_child(unit)
	var mover = Reference.new()
	mover.radius = 0.5
	unit.add_child(mover)
	var mesh := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(2, 0.4, 5)
	mesh.mesh = box
	mesh.position = Vector3(0.2, 0.2, -0.4)
	unit.add_child(mesh)
	var collision := CollisionShape3D.new()
	var own_box := BoxShape3D.new()
	own_box.size = Vector3(2, 1, 4)
	collision.shape = own_box
	unit.add_child(collision)
	var first := _obstacle(Vector3(10, 0, 10))
	var second := _obstacle(Vector3(12, 0, 10))
	# Exercise direction-dependent asymmetric hull, zero-hull fallback, and
	# narrow-pass collider support without changing the production parameters.
	for mode in range(3):
		mesh.position.y = 5.0 if mode == 1 else 0.2
		mover._narrow_pass_saved_radius = 0.5 if mode == 2 else -1.0
		for yaw in [0.0, 45.0, 90.0, 135.0]:
			first.rotation.y = deg_to_rad(yaw)
			unit.rotation.y = deg_to_rad(135.0 - yaw)
			for x in [-20.0, -4.0, -2.01, -1.99, 0.0, 1.99, 2.01, 4.0, 20.0]:
				for z in [-5.0, -0.01, 0.0, 0.01, 5.0]:
					unit.global_position = Vector3(10 + x, 0, 10 + z)
					for delta in [Vector3.ZERO, Vector3(0.5, 0, -0.5), Vector3(-0.5, 0, 0.5)]:
						for escape in [false, true]:
							var point: Vector3 = unit.global_position + delta
							var expected: Vector3 = mover.reference_push(point, escape)
							var actual: Vector3 = mover._push_out_of_static_obstacles(point, escape)
							_check(actual.distance_to(expected) < 0.00001,
								"mode=%s yaw=%s point=%s escape=%s expected=%s actual=%s" %
								[mode, yaw, point, escape, expected, actual])
					for direction in [Vector2.RIGHT, Vector2.LEFT, Vector2.UP, Vector2.DOWN, Vector2(1, 1).normalized()]:
						_check(is_equal_approx(mover.reference_ground_hull(unit, direction),
							mover._ground_hull_half_xz(unit, direction)), "directional hull")
	# Sampling must not survive a pose/node/transform change between calls.
	first.position.x = 60
	second.position.x = 70
	mover._narrow_pass_saved_radius = -1.0
	mesh.position.y = 0.2
	var old_half: float = mover._ground_hull_half_xz(unit, Vector2.RIGHT)
	mesh.scale = Vector3(2, 1, 0.5)
	unit.rotation.y = 0.3
	var new_half: float = mover._ground_hull_half_xz(unit, Vector2.RIGHT)
	_check(not is_equal_approx(old_half, new_half), "mutation changes hull")
	_check(is_equal_approx(mover.reference_ground_hull(unit, Vector2.RIGHT), new_half), "mutated hull")
	unit.position = Vector3(56, 0, 10)
	_check(mover.reference_push(Vector3(57, 0, 10)).is_equal_approx(
		mover._push_out_of_static_obstacles(Vector3(57, 0, 10))), "mutated near push")
	var skeleton := Skeleton3D.new()
	skeleton.name = "Pose"
	unit.add_child(skeleton)
	skeleton.add_bone("ground")
	skeleton.add_bone("high")
	skeleton.set_bone_pose_position(0, Vector3(3, 0.1, -1))
	skeleton.set_bone_pose_position(1, Vector3(100, 5, 100))
	var skinned := MeshInstance3D.new()
	skinned.mesh = box
	skinned.skeleton = NodePath("../Pose")
	unit.add_child(skinned)
	var excluded := MeshInstance3D.new()
	excluded.name = "SelectionExcluded"
	var huge := BoxMesh.new()
	huge.size = Vector3(100, 0.2, 100)
	excluded.mesh = huge
	unit.add_child(excluded)
	for pose_x in [3.0, 6.0]:
		skeleton.set_bone_pose_position(0, Vector3(pose_x, 0.1, -1))
		for direction in [Vector2.RIGHT, Vector2.LEFT, Vector2.UP, Vector2.DOWN]:
			var support: float = mover._ground_hull_half_xz(unit, direction)
			_check(is_equal_approx(mover.reference_ground_hull(unit, direction), support), "bone pose hull")
			_check(support < 10.0, "high bone and Selection excluded")
	first.queue_free()
	second.queue_free()
	unit.queue_free()
	await get_tree().process_frame
	print("Movement push equivalence: %s checks, %s failure(s)" % [_checks, _failures])
	print("Movement push equivalence completed: %s failure(s)" % _failures)
	get_tree().quit(0 if _failures == 0 else 1)


func _obstacle(at: Vector3) -> Node3D:
	var root := Node3D.new()
	root.position = at
	add_child(root)
	var obstacle := NavigationObstacle3D.new()
	obstacle.radius = 8
	root.add_child(obstacle)
	obstacle.add_to_group(Constants.Match.Navigation.DOMAIN_TO_OBSTACLE_GROUP_MAPPING[
		Constants.Match.Navigation.Domain.TERRAIN])
	var nested := Node3D.new()
	nested.position = Vector3(0.7, 0, -0.3)
	nested.scale = Vector3(1.2, 1, 0.8)
	root.add_child(nested)
	var collision := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(4, 3, 7)
	collision.shape = shape
	nested.add_child(collision)
	return root


func _check(passed: bool, detail: String) -> void:
	_checks += 1
	if not passed:
		_failures += 1
		push_error("Movement push mismatch: " + detail)
