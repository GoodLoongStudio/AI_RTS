extends Node

func _ready() -> void:
	var geo: Node3D = (load("res://source/match/units/structure-geometries/OreRefinery.tscn") as PackedScene).instantiate()
	add_child(geo)
	geo.scale = Vector3(3, 3, 3)
	await get_tree().process_frame
	var cluster := geo.find_child("OreCluster", true, false)
	var synty := geo.find_child("SyntyParts", true, false)
	for probe in [["OreCluster", cluster], ["SyntyParts", synty]]:
		if probe[1] == null:
			continue
		var aabb := AABB()
		var first := true
		var stack: Array = [probe[1]]
		while not stack.is_empty():
			var node = stack.pop_back()
			for child in node.get_children():
				stack.push_back(child)
			if node is MeshInstance3D and node.mesh != null:
				var wa: AABB = node.global_transform * node.mesh.get_aabb()
				aabb = wa if first else aabb.merge(wa)
				first = false
		print("[GEO2] %s world AABB size=%.2f x %.2f center=(%.1f, %.1f)" % [
			probe[0], aabb.size.x, aabb.size.z, aabb.get_center().x, aabb.get_center().z])
	get_tree().quit(0)
