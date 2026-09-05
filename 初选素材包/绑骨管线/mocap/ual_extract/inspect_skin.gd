extends SceneTree

## 对照实验: ①去掉 AnimationPlayer 导出 -> skins 是否出现; ②dump 骨架数据为 JSON 备用
func _initialize():
	var scn = load("res://.godot_imported_Mannequin.glb-2d262953d7f016a6e7593ba36bb364f3.scn") as PackedScene

	# 实验 1: 无动画导出
	var inst = scn.instantiate()
	root.add_child(inst)
	var mi := inst.find_child("Mannequin", true, false) as MeshInstance3D
	mi.skeleton = NodePath("../GeneralSkeleton")
	var ap := inst.find_child("AnimationPlayer", true, false)
	var ap_parent := ap.get_parent()
	ap_parent.remove_child(ap)
	var gltf := GLTFDocument.new()
	var state := GLTFState.new()
	var err := gltf.append_from_scene(inst, state)
	print("TEST1 err=", err, " skins=", state.skins.size())
	var bytes := gltf.generate_buffer(state)
	FileAccess.open("res://UAL_noanim.glb", FileAccess.WRITE).store_buffer(bytes)
	inst.queue_free()

	# 实验 2: dump 骨架 rest + UAL 动作轨道到 JSON (供 Python 自建 glTF)
	inst = scn.instantiate()
	root.add_child(inst)
	mi = inst.find_child("Mannequin", true, false) as MeshInstance3D
	mi.skeleton = NodePath("../GeneralSkeleton")
	var skel := inst.find_child("GeneralSkeleton", true, false) as Skeleton3D
	var lib = load("res://.godot_exported_133200997_export-27ecaf409c1935b6c3ae563a89144607-UAL1_Source.res") as AnimationLibrary
	var f := FileAccess.open("res://ual_dump.json", FileAccess.WRITE)
	f.store_string("{\n\"bones\":[\n")
	var names := skel.get_bone_count()
	for i in names:
		var parent: int = skel.get_bone_parent(i)
		var rest := skel.get_bone_rest(i)
		var pos := rest.origin
		var rot := rest.basis.get_rotation_quaternion()
		var scl := rest.basis.get_scale()
		if i > 0:
			f.store_string(",\n")
		f.store_string("{\"name\":\"%s\",\"parent\":%d,\"pos\":[%s],\"rot\":[%s],\"scl\":[%s]}" % [
			skel.get_bone_name(i), parent,
			"%.6f,%.6f,%.6f" % [pos.x, pos.y, pos.z],
			"%.6f,%.6f,%.6f,%.6f" % [rot.x, rot.y, rot.z, rot.w],
			"%.6f,%.6f,%.6f" % [scl.x, scl.y, scl.z]])
	f.store_string("],\n\"anims\":[\n")
	var first := true
	for anim_name in lib.get_animation_list():
		var anim: Animation = lib.get_animation(anim_name)
		if not first:
			f.store_string(",\n")
		first = false
		f.store_string("{\"name\":\"%s\",\"len\":%.4f,\"tracks\":[" % [anim_name, anim.length])
		var tfirst := true
		for ti in anim.get_track_count():
			var path := str(anim.track_get_path(ti))
			var colon := path.rfind(":")
			if colon < 0:
				continue
			var bone := path.substr(colon + 1)
			var tt := anim.track_get_type(ti)
			if tt != Animation.TYPE_ROTATION_3D and tt != Animation.TYPE_POSITION_3D and tt != Animation.TYPE_SCALE_3D:
				continue
			var kind := "rot" if tt == Animation.TYPE_ROTATION_3D else ("pos" if tt == Animation.TYPE_POSITION_3D else "scl")
			if not tfirst:
				f.store_string(",")
			tfirst = false
			f.store_string("{\"bone\":\"%s\",\"kind\":\"%s\",\"keys\":[" % [bone, kind])
			for k in anim.track_get_key_count(ti):
				var t: float = anim.track_get_key_time(ti, k)
				var v = anim.track_get_key_value(ti, k)
				var vs: String
				if kind == "rot":
					vs = "%.6f,%.6f,%.6f,%.6f" % [v.x, v.y, v.z, v.w]
				else:
					vs = "%.6f,%.6f,%.6f" % [v.x, v.y, v.z]
				if k > 0:
					f.store_string(",")
				f.store_string("[%.5f,%s]" % [t, vs])
			f.store_string("]}")
		f.store_string("]}")
	f.store_string("]}\n")
	f.close()
	print("JSON_DUMPED size=", FileAccess.open("res://ual_dump.json", FileAccess.READ).get_length())
	quit(0)
