extends SceneTree
## 地图截图：加载生成地图，1920×1920 抓帧。三种机位互斥：
##   默认      正交俯视（PROJECTION_ORTHOGONAL，旋转 -90,0,0）——验收顶视图
##   --iso45   正交 45° 轴测（俯角 45°、方位 45°）——验收立体图，保尺度可量
##   --oblique 透视斜视——仅供观感参考，不作验收
## --flat 时地面白/遮挡红/装饰灰/水面藏（供差分）。
## 用法：Godot_mono.exe --rendering_driver opengl3 --resolution 1920x1920 --path <AI_RTS工程根> \
##        --script ortho_capture.gd -- --map=res://source/match/maps/generated/seed_16.tscn \
##        --out=<abs ortho_raw.png> [--flat] [--size=256] [--iso45] [--oblique]

const WATER_MESH_PREFIX := "WaterMesh"
## 45° 轴测的单位视向（从目标指向相机）：方位 45°、俯角 45°。
const ISO45_DIR := Vector3(0.5, 0.70710678, 0.5)

func _init() -> void:
	_run()


func _run() -> void:
	await process_frame
	var map_path := ""
	var out_path := "ortho_raw.png"
	var flat := false
	var oblique := false
	var iso45 := false
	var size := 256.0
	var center := Vector2(-1, -1)   # 局部检查点中心（世界坐标）；<0 表示全图
	var radius := -1.0              # 局部检查点半径（米）；<0 表示全图
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--map="):
			map_path = a.substr(6)
		elif a.begins_with("--out="):
			out_path = a.substr(6)
		elif a == "--flat":
			flat = true
		elif a == "--oblique":
			oblique = true
		elif a == "--iso45":
			iso45 = true
		elif a.begins_with("--size="):
			size = float(a.substr(7))
		elif a.begins_with("--center="):
			var parts := a.substr(9).split(",")
			if parts.size() == 2:
				center = Vector2(float(parts[0]), float(parts[1]))
		elif a.begins_with("--radius="):
			radius = float(a.substr(9))
	if map_path.is_empty():
		push_error("ortho_capture: missing --map")
		quit(2)
		return
	var map = load(map_path).instantiate()
	root.add_child(map)
	await process_frame
	await process_frame

	# 环境与光照（生成地图场景无 WorldEnvironment）
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.18, 0.18, 0.22)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(1, 1, 1)
	e.ambient_light_energy = 1.0
	env.environment = e
	root.add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-55, 30, 0)
	sun.light_energy = 1.2
	root.add_child(sun)

	if flat:
		_flat_override(map)

	var cam := Camera3D.new()
	var half := size / 2.0
	var look := Vector3(half, 0, half)
	if center.x >= 0 and radius > 0:
		look = Vector3(center.x, 0, center.y)
	if iso45:
		# 45° 正交轴测（验收立体图）：正交投影不产生近大远小，格网与高度可量。
		# 全图按 size 方形取景；局部检查点按直径取景。均留 1.5 倍边距容纳投影宽度。
		var span := (radius * 2.0) if radius > 0 else size
		var dist := span * 2.0
		cam.projection = Camera3D.PROJECTION_ORTHOGONAL
		cam.size = span * 1.5
		cam.look_at_from_position(look + ISO45_DIR * dist, look, Vector3.UP)
		cam.near = 0.05
		cam.far = dist * 2.0 + span * 2.0
	elif oblique:
		# 45° 斜视参考图（仅供观感，不作验收）；支持局部检查点
		cam.projection = Camera3D.PROJECTION_PERSPECTIVE
		cam.fov = 45.0
		var span := radius if radius > 0 else size
		cam.position = Vector3(look.x + span * 0.21, span * 0.27, look.z + span * 0.25)
		cam.look_at(look)
		cam.far = span * 4.0 + 200.0
	else:
		cam.projection = Camera3D.PROJECTION_ORTHOGONAL
		cam.size = (radius * 2.0) if radius > 0 else size
		cam.position = Vector3(look.x, 50, look.z)
		cam.rotation_degrees = Vector3(-90, 0, 0)
		cam.far = 300.0
	root.add_child(cam)
	cam.current = true
	# 强制窗口/视口 1920×1920（命令行 --resolution 可能被系统缩放/驱动改写）
	root.size = Vector2i(1920, 1920)
	root.content_scale_factor = 1.0
	await process_frame
	await process_frame
	await RenderingServer.frame_post_draw
	var img := root.get_viewport().get_texture().get_image()
	img.save_png(out_path)
	print("ortho_capture saved %s (%dx%d) flat=%s size=%f iso45=%s oblique=%s"
		% [out_path, img.get_width(), img.get_height(), flat, size, iso45, oblique])
	quit(0)


func _flat_override(map: Node) -> void:
	# 地面纯白
	var terrain := map.find_child("Terrain", true, false) as MeshInstance3D
	if terrain != null:
		terrain.material_override = _flat_mat(Color(1, 1, 1))
	var bg := map.find_child("BlackBackgroundFixingAntiAliasingBug", true, false) as MeshInstance3D
	if bg != null:
		bg.visible = false
	# 水体：藏蓝色视觉板（碰撞在 Collision 节点统一渲染红）
	var wb := map.find_child("WaterBody", true, false)
	if wb != null:
		for node in wb.find_children("*", "MeshInstance3D", true, false):
			node.visible = false
	# 格网游程碰撞盒（Collision 节点）：全部按遮挡红渲染；岩脊基座网格（SolidMesh*）隐藏
	var col := map.find_child("Collision", true, false)
	if col != null:
		for node in col.find_children("*", "MeshInstance3D", true, false):
			if String(node.name).begins_with("RidgeMesh"):
				node.visible = false
		for node in col.find_children("*", "StaticBody3D", true, false):
			for child in node.get_children():
				if child is CollisionShape3D and child.shape is BoxShape3D:
					var mi := MeshInstance3D.new()
					var bm := BoxMesh.new()
					bm.size = (child.shape as BoxShape3D).size
					mi.mesh = bm
					mi.material_override = _flat_mat(Color(0.85, 0.05, 0.05))
					child.add_child(mi)
	var deco := map.find_child("Decorations", true, false)
	if deco == null:
		return
	for inst in deco.get_children():
		var blocking: bool = inst.get_meta("blocking", false)
		if not blocking:
			_apply(inst, _flat_mat(Color(0.55, 0.55, 0.55)))
		else:
			# 遮挡实例本体：mesh 隐藏（碰撞盒单独渲染）
			_set_visible_meshes(inst, false)


func _set_visible_meshes(node: Node, value: bool) -> void:
	if node is MeshInstance3D:
		(node as MeshInstance3D).visible = value
	for c in node.get_children():
		_set_visible_meshes(c, value)


func _flat_mat(color: Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = color
	return mat


func _apply(node: Node, mat: StandardMaterial3D) -> void:
	if node is MeshInstance3D:
		(node as MeshInstance3D).material_override = mat
	for c in node.get_children():
		_apply(c, mat)
