extends SceneTree
## 一次性探针：检查 Decorations 实例的 tint 元数据与材质（用后即删）。

func _init() -> void:
	_run()


func _run() -> void:
	await process_frame
	var map = load("res://source/match/maps/generated/seed_16.tscn").instantiate()
	root.add_child(map)
	for _i in range(6):
		await process_frame
	var deco: Node = map.find_child("Decorations", true, false)
	print("deco found: ", deco != null, " children: ", deco.get_child_count() if deco else -1)
	var n := 0
	var with_tint := 0
	var with_mat := 0
	for inst in deco.get_children():
		var tint_s: String = inst.get_meta("tint", "")
		if not tint_s.is_empty():
			with_tint += 1
		if n < 3:
			var mi_list: Array = inst.find_children("*", "MeshInstance3D", true, false)
			var mo = null
			if mi_list.size() > 0:
				mo = (mi_list[0] as MeshInstance3D).material_override
			print("  ", inst.name, " tint=", tint_s, " meshes=", mi_list.size(),
				  " override0=", mo != null,
				  " color=", (mo as StandardMaterial3D).albedo_color if mo is StandardMaterial3D else "-")
		if not tint_s.is_empty():
			with_mat += 1
		n += 1
	print("total=", n, " with_tint=", with_tint)
	quit(0)
