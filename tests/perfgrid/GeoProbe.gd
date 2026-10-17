extends Node

const GEO := "res://source/match/units/structure-geometries/OreRefinery.tscn"
const ROOT_SCALE := 3.0


func _ready() -> void:
	var geo: Node3D = (load(GEO) as PackedScene).instantiate()
	add_child(geo)
	geo.scale = Vector3(ROOT_SCALE, ROOT_SCALE, ROOT_SCALE)
	await get_tree().process_frame
	var aabb := AABB()
	var first := true
	var stack: Array = [geo]
	while not stack.is_empty():
		var node = stack.pop_back()
		for child in node.get_children():
			stack.push_back(child)
		if node is MeshInstance3D and node.mesh != null:
			var wa: AABB = node.global_transform * node.mesh.get_aabb()
			aabb = wa if first else aabb.merge(wa)
			first = false
	print("[GEO] OreRefinery visual AABB size=%.2f x %.2f (y=%.2f) half=(%.2f, %.2f)" % [
		aabb.size.x, aabb.size.z, aabb.size.y, aabb.size.x / 2.0, aabb.size.z / 2.0])
	var space := geo.get_world_3d().direct_space_state
	for axis in ["x", "z"]:
		var offset := Vector3(15, 0.3, 0) if axis == "x" else Vector3(0, 0.3, 15)
		var q := PhysicsRayQueryParameters3D.create(
			geo.global_position + offset, geo.global_position)
		q.collision_mask = 2
		q.collide_with_areas = true
		var hit := space.intersect_ray(q)
		if hit.is_empty():
			print("[GEO] collider %s-axis: no hit" % axis)
		else:
			var p: Vector3 = hit["position"]
			var d: float = absf((p - geo.global_position).dot(
				Vector3(1, 0, 0) if axis == "x" else Vector3(0, 0, 1)))
			print("[GEO] collider %s-axis radius = %.2f" % [axis, d])
	get_tree().quit(0)
