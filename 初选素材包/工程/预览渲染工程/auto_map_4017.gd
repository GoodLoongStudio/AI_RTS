extends SceneTree

# 对 4017 两个角色合集的每个 mesh，自动尝试 4 张 A 图集，
# 检测非黑剪影的那张，输出 mesh 级映射。

const TEX_DIR := "res://assets/4017_幻想怪物/PolygonFantasyRivals/Textures/"
const ATLAS := ["FantasyRivals_Texture_01_A.png", "FantasyRivals_Texture_02_A.png",
	"FantasyRivals_Texture_03_A.png", "FantasyRivals_Texture_04_A.png"]


func _init() -> void:
	_run()


func _run() -> void:
	get_root().size = Vector2i(200, 200)
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
	sun.light_energy = 1.3
	get_root().add_child(sun)

	var result := {}
	for fbx_name in ["Characters.fbx", "Characters_BR.fbx"]:
		var res: String = "res://assets/4017_幻想怪物/PolygonFantasyRivals/Models/" + fbx_name
		var ps: PackedScene = load(res)
		if ps == null:
			print("LOAD FAILED ", fbx_name)
			continue
		var inst: Node = ps.instantiate()
		get_root().add_child(inst)
		var meshes: Array = []
		_collect(inst, meshes)
		print(fbx_name, " mesh 数: ", meshes.size())
		for mi in meshes:
			var hit: String = await _auto_pick(mi, meshes)
			if hit != "":
				result[str(mi.name)] = TEX_DIR + hit
				print("  MATCH ", mi.name, " -> ", hit)
			else:
				print("  NONE ", mi.name)
		inst.queue_free()
	var f := FileAccess.open("res://auto_map_4017.json", FileAccess.WRITE)
	f.store_string(JSON.stringify({"mesh::4017_幻想怪物": result}, "  "))
	f.close()
	print("AUTO_MAP_DONE ", result.size())
	quit()


func _collect(n: Node, out: Array) -> void:
	if n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
		out.append(n as MeshInstance3D)
	for c in n.get_children():
		_collect(c, out)


func _auto_pick(target: MeshInstance3D, siblings: Array) -> String:
	var aabb: AABB = target.get_global_transform() * target.get_aabb()
	if aabb.size.length() < 0.001:
		return ""
	for atlas in ATLAS:
		for other in siblings:
			other.visible = other == target
		var bm := StandardMaterial3D.new()
		bm.albedo_texture = load(TEX_DIR + atlas)
		bm.roughness = 0.9
		for i in target.mesh.get_surface_count():
			target.set_surface_override_material(i, bm)
		var cam := Camera3D.new()
		cam.fov = 50.0
		var radius := aabb.size.length() * 0.5
		get_root().add_child(cam)
		cam.position = aabb.get_center() + Vector3(0.62, 0.5, 0.85).normalized() * (radius * 2.0 + 0.8)
		cam.current = true
		await process_frame
		cam.look_at(aabb.get_center())
		await process_frame
		RenderingServer.force_draw(true)
		var img := get_root().get_texture().get_image()
		cam.queue_free()
		if _is_colored(img):
			for other2 in siblings:
				other2.visible = true
			return atlas
		for other3 in siblings:
			other3.visible = true
	return ""


func _is_colored(img: Image) -> bool:
	var w := img.get_width()
	var h := img.get_height()
	var model_px := 0
	var dark_px := 0
	for y in range(0, h, 2):
		for x in range(0, w, 2):
			var c := img.get_pixel(x, y)
			var lum := c.get_luminance()
			var is_bg: bool = absf(lum - 0.75) < 0.06 and absf(c.r - c.g) < 0.02 and absf(c.g - c.b) < 0.02
			if not is_bg:
				model_px += 1
				if lum < 0.08:
					dark_px += 1
	if model_px < 20:
		return false
	return float(dark_px) / float(model_px) < 0.5
