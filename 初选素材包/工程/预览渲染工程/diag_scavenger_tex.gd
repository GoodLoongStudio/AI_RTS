extends SceneTree

var tex_map: Dictionary = {}

func _init() -> void:
	var f := FileAccess.open("res://texture_map.json", FileAccess.READ)
	tex_map = JSON.parse_string(f.get_as_text())
	var res := "res://assets/4006_科幻世界/PolygonSciFiWorlds/Models/Characters.fbx"
	var ps: PackedScene = load(res)
	var inst: Node = ps.instantiate()
	get_root().add_child(inst)

	# 环境
	var we := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.75, 0.75, 0.78)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(1, 1, 1)
	env.ambient_light_energy = 1.0
	get_root().add_child(we)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, -30, 0)
	sun.light_energy = 1.2
	get_root().add_child(sun)

	# 找 Scavenger_02
	var target: MeshInstance3D = null
	var stack: Array = [inst]
	while stack.size() > 0:
		var n: Node = stack.pop_back()
		if n is MeshInstance3D and str(n.name).contains("Scavenger_02"):
			target = n as MeshInstance3D
		for c in n.get_children():
			stack.append(c)
	if target == null:
		print("NO TARGET")
		quit()
		return

	# AABB
	var aabb: AABB = target.get_aabb()
	var xf := target.get_global_transform()
	var gab: AABB = xf * aabb

	var candidates: Array = tex_map.get(res, [])
	print("candidates=", candidates)
	var combos := [
		["tex_01A", candidates[0]],
		["tex_03C", candidates[1]],
		["tex_02C", candidates[2]],
	]
	for combo: Array in combos:
		var tag := str(combo[0])
		var tex_path := str(combo[1])
		var dup: MeshInstance3D = target.duplicate() as MeshInstance3D
		# 隔离：从原父级摘出来直接挂 root
		get_root().add_child(dup)
		for i in dup.mesh.get_surface_count():
			var bm := StandardMaterial3D.new()
			bm.albedo_texture = load(tex_path)
			bm.roughness = 0.9
			dup.set_surface_override_material(i, bm)
		var cam := Camera3D.new()
		cam.fov = 50.0
		var radius := gab.size.length() * 0.5
		get_root().add_child(cam)
		cam.position = gab.get_center() + Vector3(0.62, 0.5, 0.85).normalized() * (radius * 2.0 + 0.8)
		cam.current = true
		await process_frame
		cam.look_at(gab.get_center())
		await process_frame
		RenderingServer.force_draw(true)
		var img := get_root().get_texture().get_image()
		var out := "res://../../预览图/diag_Scavenger02_%s.png" % tag
		img.save_png(ProjectSettings.globalize_path(out))
		print("SAVED ", out)
		dup.queue_free()
		cam.queue_free()
	quit()
