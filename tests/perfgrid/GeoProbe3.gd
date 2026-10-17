extends Node


func _ready() -> void:
	var geo: Node3D = (load("res://source/match/units/structure-geometries/OreRefinery.tscn") as PackedScene).instantiate()
	add_child(geo)
	geo.scale = Vector3(3, 3, 3)
	await get_tree().process_frame
	for part_name in ["BasePad", "ProcessorPod", "OreCluster", "OreCart"]:
		var part := geo.find_child(part_name, true, false)
		if part == null:
			continue
		var aabb := AABB()
		var first := true
		var stack: Array = [part]
		while not stack.is_empty():
			var node = stack.pop_back()
			for child in node.get_children():
				stack.push_back(child)
			if node is MeshInstance3D and node.mesh != null:
				var wa: AABB = node.global_transform * node.mesh.get_aabb()
				aabb = wa if first else aabb.merge(wa)
				first = false
		print("[GEO3] %-14s world z 半径=%.2f  x 半径=%.2f" % [
			part_name, aabb.size.z / 2.0, aabb.size.x / 2.0])
	get_tree().quit(0)
