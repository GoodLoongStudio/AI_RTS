extends SceneTree

func _init() -> void:
	var targets = [
		"res://assets/4006_科幻世界/PolygonSciFiWorlds/Models/Characters.fbx",
	]
	for path in targets:
		var ps: PackedScene = load(path)
		if ps == null:
			print("LOAD FAILED ", path)
			continue
		var inst: Node = ps.instantiate()
		_walk(inst, path)
	quit()

func _walk(n: Node, fbx: String) -> void:
	if n is MeshInstance3D:
		var mi := n as MeshInstance3D
		var mats: Array = []
		for i in mi.mesh.get_surface_count():
			var m = mi.get_active_material(i)
			if m is BaseMaterial3D:
				var bm := m as BaseMaterial3D
				mats.append(str(bm.resource_name, "|tex=", bm.albedo_texture != null))
			else:
				mats.append("null")
		print(fbx.get_file(), "  ", mi.name, "  mats=", mats)
	for c in n.get_children():
		_walk(c, fbx)
