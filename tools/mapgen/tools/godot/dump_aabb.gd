extends SceneTree
## 导出 4006 科幻世界包所有非碰撞 FBX 的合并 AABB（只读素材工程，不修改 assets/）。
## 用法：
##   Godot_mono_console.exe --headless --path <预览渲染工程> --script dump_aabb.gd -- --out=<绝对路径.json>

func _init() -> void:
	var out_path := "aabb_raw.json"
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			out_path = a.substr(6)
	var result := {}
	var n_err := 0
	_scan("res://assets", result, n_err)
	var f := FileAccess.open(out_path, FileAccess.WRITE)
	f.store_string(JSON.stringify(result, "  "))
	f.close()
	print("dump_aabb: %d models -> %s" % [result.size(), out_path])
	quit()


func _list_dir(path: String) -> PackedStringArray:
	var d := DirAccess.open(path)
	if d == null:
		print("open failed: ", path, " err=", DirAccess.get_open_error())
		return PackedStringArray()
	var names := d.get_files()
	var sub := d.get_directories()
	print("dir ", path, " files=", names.size(), " dirs=", sub.size(), " first=", (names[0] if names.size() > 0 else "<none>"))
	return names + sub


func _scan(path: String, out: Dictionary, n_err: int) -> void:
	var d := DirAccess.open(path)
	if d == null:
		return
	d.list_dir_begin()
	var name := d.get_next()
	while name != "":
		var full := path + "/" + name
		if d.current_is_dir():
			_scan(full, out, n_err)
		elif name.ends_with(".fbx") and not name.contains("_Collision"):
			var ab := _load_aabb(full)
			if ab != AABB():
				out[full] = {
					"size": [ab.size.x, ab.size.y, ab.size.z],
					"min_y": ab.position.y,
				}
			else:
				n_err += 1
		name = d.get_next()
	d.list_dir_end()


func _load_aabb(path: String) -> AABB:
	var ps = load(path)
	if ps == null:
		return AABB()
	var inst = ps.instantiate()
	if inst == null:
		return AABB()
	var acc := _merge(inst, Transform3D.IDENTITY, AABB())
	inst.free()
	return acc


func _merge(node: Node, xf: Transform3D, acc: AABB) -> AABB:
	var cur := xf
	if node is Node3D:
		cur = xf * (node as Node3D).transform
	if node is MeshInstance3D:
		var mi := node as MeshInstance3D
		if mi.mesh != null:
			var ab: AABB = cur * mi.mesh.get_aabb()
			if acc.size == Vector3.ZERO and acc.position == Vector3.ZERO:
				acc = ab
			else:
				acc = acc.merge(ab)
	for c in node.get_children():
		acc = _merge(c, cur, acc)
	return acc
