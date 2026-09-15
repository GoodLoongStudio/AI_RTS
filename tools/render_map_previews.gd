extends Node

## 离线生成「地图卡预览图」（菜单里那张真图，替代原先按路径 hash 派生的假格子）。
##
## 为什么离线生成而不是运行时渲染：生成地图是 2048m/1025² 网格，菜单里每次切图都实例化一遍
## 会明显卡顿；离线出一张 512² PNG 后菜单只需 load()，代价可忽略。
##
## 用法（**必须带窗口**：headless 下 `viewport.get_texture()` 为 null，什么都存不出来）：
##   godot --path . --resolution 1280x720 --position -4000,-4000 res://tools/render_map_previews.tscn
## 产物：assets/map_previews/<地图文件基名>.png
## 生成后需 `--headless --import` 一次（否则菜单里 load() 拿不到）。
##
## 取景方式：**从实例化后的真实几何算 AABB**（不读地图元数据），
## 所以手搓图（PlaneMesh）与生成地图（高度场 ArrayMesh）走同一条路径，地图改版后重跑即可。

const MatchSetupShared = preload("res://source/main-menu/MatchSetupShared.gd")

const OUT_DIR := "res://assets/map_previews"
const VIEW_SIZE := Vector2i(512, 512)
## 正交相机留白系数：1.0 = 刚好贴边，留 4% 免边缘被裁。
const FRAME_MARGIN := 1.04

## 水面高度（语义米）：与地形管线权威值 `Y_WATER = -2.4` 一致，低于它按水色画。
const PREVIEW_WATER_Y := -2.4

## 预览专用地形材质（按局部高度分层着色，仍然受光，所以坡面有明暗 = 能看出地形起伏）。
## 为什么需要它：生成地图的地形/水面是**自定义 shader**，参数（`mask_world_size=2048`、
## `showcase_world_scale`、水面掩码）都是按"游戏内 2048m 的 Match 上下文"标定的，
## 离线单独实例化时渲染结果几乎全黑（2026-09-15 实测）。预览图不需要复刻游戏内配色，
## 需要的是"一眼看出地形结构"，所以这里只替换 **ShaderMaterial** 的地形/水面，
## 手搓地图的原生材质（本来就能正常渲染）保持原样。
const PREVIEW_TERRAIN_SHADER := """
shader_type spatial;
varying float v_height;
uniform float water_y = -2.4;
uniform float band_span = 26.0;
uniform vec3 water_color = vec3(0.15, 0.31, 0.45);

void vertex() {
	v_height = VERTEX.y;
}

void fragment() {
	float t = clamp((v_height - water_y) / band_span, 0.0, 1.0);
	// 【2026-09-15 用户反馈：预览图与实际地图配色不符（实际是废土沙色，预览是灰绿）】
	// 换成游戏内 showcase_land 的沙地/棕土色系（sand_uniform_diff / brown_mud_02 / moon_dusted）。
	vec3 low = vec3(0.55, 0.38, 0.24);
	vec3 mid = vec3(0.78, 0.58, 0.36);
	vec3 high = vec3(0.86, 0.78, 0.64);
	vec3 land = mix(mix(low, mid, smoothstep(0.0, 0.55, t)), high, smoothstep(0.55, 1.0, t));
	// 水线必须用**权威水高**判定，不能用"取景包围盒最低点"：
	// 平地地图整体在 y=0，用包围盒最低点会把整张图误判成水面（2026-09-15 实测）。
	ALBEDO = mix(water_color, land, step(water_y + 0.02, v_height));
	ROUGHNESS = 0.92;
}
"""


func _ready() -> void:
	var dir_abs := ProjectSettings.globalize_path(OUT_DIR)
	DirAccess.make_dir_recursive_absolute(dir_abs)
	for entry in MatchSetupShared.map_entries():
		var map_path := str(entry[0])
		await _render_one(map_path, MatchSetupShared.map_label(map_path))
	print("[PREVIEW] 全部完成，输出目录：", OUT_DIR)
	get_tree().quit(0)


func _render_one(map_path: String, label: String) -> void:
	var packed := load(map_path) as PackedScene
	if packed == null:
		print("[PREVIEW] 跳过（加载失败）：", map_path)
		return
	var out_path := "%s/%s.png" % [OUT_DIR, MatchSetupShared.preview_slug(map_path)]

	# 生成地图优先走"高度场直接合成"：那份地图的可视地表是自定义 shader 驱动的，
	# 参数按游戏内 Match 上下文标定，离线实例化渲染结果不可靠（2026-09-15 实测全黑）；
	# 而 height_data.bin 是权威数据，直接晕渲出来的预览既稳、又更能看出地形结构。
	if _synth_from_heightfield(map_path, out_path, label):
		return

	var viewport := SubViewport.new()
	viewport.size = VIEW_SIZE
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(viewport)

	var holder := Node3D.new()
	viewport.add_child(holder)
	var map_node := packed.instantiate()
	holder.add_child(map_node)

	# 环境与光照：生成地图的地形是自定义 shader（自发光性质），手搓图走 StandardMaterial，
	# 两者都要能看清，所以给一块中性背景 + 环境光 + 一盏斜俯平行光。
	var world_env := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.05, 0.06, 0.08)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.78, 0.78, 0.8)
	env.ambient_light_energy = 1.0
	world_env.environment = env
	viewport.add_child(world_env)
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-55.0, -35.0, 0.0)
	light.light_energy = 1.15
	viewport.add_child(light)

	# 网格构建/材质绑定发生在 enter_tree~ready 之间，多等两帧再取 AABB 与出图。
	await get_tree().process_frame
	await get_tree().process_frame

	var bounds := _terrain_bounds(map_node)
	if bounds.size.x <= 0.0 and bounds.size.z <= 0.0:
		print("[PREVIEW] 跳过（量不到几何）：", map_path)
		viewport.queue_free()
		return

	var center := bounds.get_center()
	var span := maxf(maxf(bounds.size.x, bounds.size.z), 1.0)
	_apply_preview_materials(map_node, bounds)
	var camera := Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = span * FRAME_MARGIN
	camera.near = 0.05
	camera.far = span * 8.0 + 2000.0
	camera.position = Vector3(center.x, bounds.position.y + span * 2.0, center.z)
	camera.rotation_degrees = Vector3(-90.0, 0.0, 0.0)
	viewport.add_child(camera)
	camera.current = true

	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var image := viewport.get_texture().get_image()
	var err := image.save_png(ProjectSettings.globalize_path(out_path))
	print("[PREVIEW] %s → %s  尺寸=%s  AABB=%.1f×%.1f  err=%s"
		% [label, out_path, str(image.get_size()), bounds.size.x, bounds.size.z, str(err)])
	viewport.queue_free()
	await get_tree().process_frame


## 由 `height_data.bin`（1025² float32，语义米）直接合成一张晕渲预览图。
## 只在同目录存在 `map_index.json` + `height_data`（= 生成地图）时生效，返回是否已出图。
## 颜色约定：水面取水深以下（权威值 `Y_WATER = -2.4`），陆地按高度分带，再叠一层坡面明暗。
func _synth_from_heightfield(map_path: String, out_path: String, label: String) -> bool:
	var dir := map_path.get_base_dir()
	var index_path := dir.path_join("map_index.json")
	if not FileAccess.file_exists(index_path):
		return false
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(index_path))
	if not (parsed is Dictionary):
		return false
	var data_res := str((parsed as Dictionary).get("height_data", ""))
	if data_res.is_empty() or not FileAccess.file_exists(data_res):
		return false
	var floats := FileAccess.get_file_as_bytes(data_res).to_float32_array()
	var side := int(round(sqrt(float(floats.size()))))
	if side < 4 or side * side > floats.size():
		return false

	var size := VIEW_SIZE.x
	var image := Image.create(size, size, false, Image.FORMAT_RGB8)
	var step := float(side) / float(size)
	var light := Vector3(-0.55, 0.72, -0.42).normalized()
	# 【2026-09-15 用户反馈】与上方 shader 同口径：改成游戏内废土沙色系，
	# 不再用"灰绿→土黄→灰白"（那是离线预览临时配色，和实际地图对不上）。
	var low_c := Color(0.55, 0.38, 0.24)
	var mid_c := Color(0.78, 0.58, 0.36)
	var high_c := Color(0.86, 0.78, 0.64)
	var water_c := Color(0.15, 0.31, 0.45)
	for py in range(size):
		for px in range(size):
			var sx := mini(int(px * step), side - 1)
			var sy := mini(int(py * step), side - 1)
			var height := floats[sy * side + sx]
			if height <= PREVIEW_WATER_Y:
				image.set_pixel(px, py, water_c)
				continue
			var neighbor_step := maxi(int(step), 1)
			var hx := floats[sy * side + mini(sx + neighbor_step, side - 1)] - height
			var hz := floats[mini(sy + neighbor_step, side - 1) * side + sx] - height
			var normal := Vector3(-hx, float(neighbor_step), -hz).normalized()
			var shade := clampf(normal.dot(light), 0.0, 1.0) * 0.9 + 0.35
			var t := clampf((height - PREVIEW_WATER_Y) / 26.0, 0.0, 1.0)
			var land := low_c.lerp(mid_c, smoothstep(0.0, 0.55, t)).lerp(
				high_c, smoothstep(0.55, 1.0, t)
			)
			image.set_pixel(px, py, Color(
				clampf(land.r * shade, 0.0, 1.0),
				clampf(land.g * shade, 0.0, 1.0),
				clampf(land.b * shade, 0.0, 1.0)
			))
	var err := image.save_png(ProjectSettings.globalize_path(out_path))
	print("[PREVIEW] %s ← height_data.bin 合成（%d²，%s）err=%s" % [label, side, out_path, str(err)])
	return err == OK


## 只替换**取景用的那个 Terrain 网格**的材质（+ 名字含 water 的水面网格）。
## 刻意不做"全场景扫 ShaderMaterial"：手搓图里那些 ShaderMaterial 网格实测都在画面外
## （换了材质图也不变），乱扫只会带来无谓的耦合；而 Terrain 一律换成预览材质，
## 是为了让三张预览图共用同一套配色语言（否则手搓图是一块原始 albedo 的纯色，观感突兀）。
func _apply_preview_materials(root: Node, bounds: AABB) -> void:
	var shader := Shader.new()
	shader.code = PREVIEW_TERRAIN_SHADER
	var terrain_mat := ShaderMaterial.new()
	terrain_mat.shader = shader
	terrain_mat.set_shader_parameter("water_y", PREVIEW_WATER_Y)
	terrain_mat.set_shader_parameter("band_span", 26.0)
	var water_mat := StandardMaterial3D.new()
	water_mat.albedo_color = Color(0.16, 0.32, 0.46, 0.9)
	water_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	var replaced := 0
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		for child in node.get_children():
			stack.append(child)
		var mesh_instance := node as MeshInstance3D
		if mesh_instance == null or mesh_instance.mesh == null:
			continue
		var lower := node.name.to_lower()
		if lower == "terrain":
			mesh_instance.material_override = terrain_mat
			replaced += 1
		elif lower.contains("water"):
			mesh_instance.material_override = water_mat
			replaced += 1
	print("[PREVIEW] 预览材质替换 %d 个" % replaced)


## 取景必须只看**可玩地形**：只认名为 `Terrain` 的那个网格。
## 不能对整个场景做 AABB 并集 —— 手搓地图里带一个 1000 单位的天空/背景网格，
## 并集会把它算进来，相机被推到 1000 米外，地形在 512² 图上缩成中心一个小方块
## （2026-09-15 实测：PlainAndSimple 的并集是 1000×1000，而真实地形只有 ~216 米）。
func _terrain_bounds(root: Node) -> AABB:
	var terrain := root.find_child("Terrain", true, false) as MeshInstance3D
	if terrain != null and terrain.mesh != null:
		return terrain.global_transform * terrain.mesh.get_aabb()
	# 没有 Terrain 节点时退回并集（至少不会取不到景）。
	return _visual_bounds(root)


## 合并场景内所有 MeshInstance3D 的世界 AABB（含缩放），仅作为 Terrain 缺失时的兜底。
## 用 `mesh.get_aabb()` 而不是遍历顶点：生成地图是 1025²，逐点遍历会白等几十秒。
func _visual_bounds(root: Node) -> AABB:
	var result := AABB()
	var found := false
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		for child in node.get_children():
			stack.append(child)
		var mesh_instance := node as MeshInstance3D
		if mesh_instance == null or mesh_instance.mesh == null:
			continue
		var box: AABB = mesh_instance.global_transform * mesh_instance.mesh.get_aabb()
		if not found:
			result = box
			found = true
		else:
			result = result.merge(box)
	return result
