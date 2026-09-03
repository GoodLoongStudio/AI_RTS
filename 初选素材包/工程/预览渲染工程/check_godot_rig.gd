extends SceneTree

func _init() -> void:
	var ps: PackedScene = load("res://assets/rig_test/Chr_00_rigged.fbx")
	if ps == null:
		print("LOAD FAILED")
		quit()
		return
	var inst: Node = ps.instantiate()
	get_root().add_child(inst)
	var found_skel := false
	var stack: Array = [inst]
	while stack.size() > 0:
		var n: Node = stack.pop_back()
		if n is Skeleton3D:
			var sk := n as Skeleton3D
			found_skel = true
			var names := []
			for i in sk.get_bone_count():
				names.append(sk.get_bone_name(i))
			print("SKELETON bones=", sk.get_bone_count())
			print("BONE_LIST=", ", ".join(names))
			var need := ["Hips", "Spine", "Head", "LeftHand", "RightFoot",
				"LeftUpLeg", "RightUpLeg", "LeftForeArm", "RightForeArm"]
			for req in need:
				var idx := sk.find_bone(req)
				print("  ", req, " -> ", "OK" if idx >= 0 else "MISSING")
		for c in n.get_children():
			stack.append(c)
	print("GODOT_HUMANOID_READY=", found_skel)
	quit()
