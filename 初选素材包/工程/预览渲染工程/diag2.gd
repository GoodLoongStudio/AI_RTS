extends SceneTree

func _init() -> void:
	var f := FileAccess.open("res://mat_texture_overrides.json", FileAccess.READ)
	var ov: Dictionary = JSON.parse_string(f.get_as_text())
	print("mat keys=", ov.get("mat::4017_幻想怪物", {}).keys())
	var res := "res://assets/4017_幻想怪物/PolygonFantasyRivals/Models/Characters.fbx"
	var ps: PackedScene = load(res)
	var inst: Node = ps.instantiate()
	get_root().add_child(inst)
	var stack: Array = [inst]
	while stack.size() > 0:
		var n: Node = stack.pop_back()
		if n is MeshInstance3D:
			var mi := n as MeshInstance3D
			var mats: Array = []
			for i in mi.mesh.get_surface_count():
				var m = mi.get_active_material(i)
				mats.append(m.resource_name if m else "null")
			print(mi.name, " mats=", mats)
		for c in n.get_children():
			stack.append(c)
	quit()
