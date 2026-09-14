extends MeshInstance3D
## 生成地图的真实地形网格：读取 G4 height_data.bin（与 Python 校验同源的高度场），
## 运行时构建 ArrayMesh。Match._setup_subsystems_dependent_on_map 随后用本网格
## create_trimesh_shape 建碰撞，导航烘焙自碰撞 —— 视觉/碰撞/导航/高度查询同源。
##
## height_data.bin 格式：int32 w, int32 h, float32[h*w]（行主序，little-endian）。
## 顶点 (i,j) 的局部坐标 = (i*xz_step, h, j*xz_step)，xz_step = SEMANTIC_SPAN/(w-1)；
## 即顶点覆盖语义域 [0,SEMANTIC_SPAN]²，再经 Map 基座 scale=world_scale 换算成
## 世界米（512 语义 -> 2048m）。高度是**语义米**，同样由 Map 的 Y 缩放换算。
##
## 视觉轮（GLM）改动说明（仅材质/贴图部分，网格构建逻辑未动）：
## - 材质改为 cull_disabled 着色器：GL 兼容渲染下开放单面高度场的背面被剔除会
##   黑面不可见（实测 capture_debug.gd），着色器按世界高度+坡度+噪声混合自然色带
##   （河床/岸沙/暖土/台地草/崖岩），锚点取契约高度：水床 -2.4 / 水面 0 / 平地
##   0.6 / 台地顶 3.6。
## - terrain_albedo（visual_api materials 透传）作为全局色调，按亮度归一，
##   profile 仍可整体调暖/调冷。
## - 隐藏 Collision/Walk*/GroundMesh* 可视盒板：盒顶与高度场顶共面，Terrain
##   可见后两者 Z-fight 且坡道处盒顶台阶穿出；仅关 visible，碰撞/导航不动。

@export_file("*.bin") var height_data_path := ""
## G2 语义域跨度（米）。高度场以其为坐标系，顶点间距 = SEMANTIC_SPAN/(w-1)。
const SEMANTIC_SPAN := 512.0
## Map.tscn 基座 Geometry 对本节点的等比缩放（顶点 0-512 -> 世界 0-2048 时为 4）。
## shader 内所有高度锚点（水床/岸线/台地/山体）按未缩放顶点坐标编写，
## vertex 里除回该值，否则缩放把 world_pos.y 抬高 N 倍导致全部着色锚点错位。
@export var world_scale := 1.0
@export var terrain_albedo: Color = Color(0.80, 0.72, 0.60, 1)
@export var terrain_roughness: float = 1.0  # 兼容保留（着色器固定 roughness 1.0）
@export var terrain_shaded: bool = false    # 兼容保留（着色器恒为受光模式）

func _enter_tree() -> void:
	# 必须在 _enter_tree（add_child 同步回调）建网格：Match._ready 会在同一帧
	# 调用 Terrain.update_shape(mesh) 捕提碰撞 trimesh，若等到 _ready 才建网格，
	# 捕到的是基 PlaneMesh（平地），导航/碰撞与真实高程脱节。
	_build()


func _ready() -> void:
	# 材质在 _ready 设置（树就绪后），避免 _enter_tree 过早赋值被覆盖/黑面。
	_apply_material()
	_wire_water_mask()
	_hide_redundant_ground_plates()


func _wire_water_mask() -> void:
	# 水面 shader（showcase_water 的 mask_from_tex 通路）需要同一份 terrain_masks.png
	# 作为岸距来源。tscn 里的 ExtResource(Texture2D) 走的是 .godot/imported 的**导入
	# 缓存**：导出侧重新生成了掩码但缓存没刷新时，shader 会静默拿到旧掩码
	# （水色/岸线位置错，且没有任何报错）。这里直接用 Image.load_from_file 读盘建
	# ImageTexture 覆盖参数，与地形掩码（同样直接读盘）保持同源同版本。
	var geometry := get_parent()
	var map_node: Node = geometry.get_parent() if geometry != null else null
	if map_node == null:
		return
	var water_body: Node = map_node.get_node_or_null("WaterBody")
	if water_body == null:
		return
	var path: String = height_data_path.get_base_dir() + "/terrain_masks.png"
	if height_data_path.is_empty() or not FileAccess.file_exists(path):
		push_error("GeneratedTerrain: 水面掩码缺失（不静默跳过）: " + path)
		return
	var img := Image.load_from_file(path)
	if img == null:
		push_error("GeneratedTerrain: 水面掩码无法读取: " + path)
		return
	var tex := ImageTexture.create_from_image(img)
	var wired := 0
	for child in water_body.get_children():
		var mi := child as MeshInstance3D
		if mi == null:
			continue
		var m := mi.material_override as ShaderMaterial
		if m != null:
			m.set_shader_parameter("mask_tex", tex)
			wired += 1
	if wired == 0:
		push_error("GeneratedTerrain: WaterBody 下没有可用的水面 ShaderMaterial")
	else:
		print("WATER_MASK wired=", wired, " size=", img.get_width(), "x", img.get_height())


func _apply_material() -> void:
	# ---- 共享 shader：与 review 渲染器同一份 showcase_land.gdshader ----
	# mask_from_tex=1 模式下，着色掩码（台地/岸/湖/岩区距离场）从 terrain_masks.png
	# 顶点采样（G4 导出，与 review 的 UV/UV2 同口径）—— 游戏内与 review 逐像素同源。
	var shared := load("res://source/match/maps/generated/showcase_land.gdshader")
	assert(shared != null, "shared terrain shader (showcase_land.gdshader) missing")
	var mat := ShaderMaterial.new()
	mat.shader = shared
	var pbr := "res://assets/terrain_pbr/"
	for pair in [
		["sand_tex", "sand_uniform_diff.jpg"], ["sand_normal", "dense_sand_normal.jpg"],
		["detail_tex", "sand_01_diff.jpg"], ["top_tex", "moon_dusted_03_diff.jpg"],
		["cliff_tex", "cliff_side_diff.jpg"], ["cliff_normal", "cliff_side_normal.jpg"],
		["rock_tex", "dark_rock_02_diff.jpg"], ["rock_normal", "dark_rock_02_normal.jpg"],
		["detail2_tex", "gray_rocks_diff.jpg"], ["bank_tex", "brown_mud_02_diff.jpg"],
		["shore_tex", "damp_beach_sand_02_diff.jpg"], ["ramp_tex", "dirt_aerial_02_diff.jpg"],
		["macro_sand_tex", "image25_macro_sand.png"], ["macro_gravel_tex", "image25_macro_gravel.png"],
		["macro_rock_tex", "image25_macro_rock.png"], ["macro_wet_shore_tex", "image25_macro_wet_shore.png"],
		["macro_albedo", "image25_macro_sand.png"],
	]:
		var tex := load(pbr + pair[1])
		if tex != null:
			mat.set_shader_parameter(pair[0], tex)
	# 掩码走 UV/UV2 顶点属性（_build 已写入）—— 与 review 渲染器同机制，
	# 不使用 mask_from_tex 分支（保持 mask_from_tex=0 默认）。
	# 与 review 渲染器逐参数一致（p 归一化到 2000m 语义域；世界 2048 -> 1.024）
	var sem_scale := world_scale / 3.90625
	mat.set_shader_parameter("showcase_world_scale", sem_scale)
	mat.set_shader_parameter("use_masks", 1.0)
	mat.set_shader_parameter("use_macro_albedo", true)
	mat.set_shader_parameter("macro_strength", 0.72)
	mat.set_shader_parameter("ground_height", 2.34)
	mat.set_shader_parameter("top_height", 14.35)
	mat.set_shader_parameter("normal_strength", 0.022)
	mat.set_shader_parameter("cut_water", false)
	mat.set_shader_parameter("debug_masks", 0.0)
	mat.set_shader_parameter("main_run", 0.0)
	mat.set_shader_parameter("main_width", 0.0)
	material_override = mat


func _hide_redundant_ground_plates() -> void:
	# Collision/Walk*/GroundMesh* 是与碰撞同尺寸的可视盒板；Terrain ArrayMesh
	# 可见后两者共面 Z-fight、坡道处盒顶台阶穿出。仅隐藏 MeshInstance3D 的
	# GroundMesh*（Walk*/Solid* 的碰撞体、桥面/水面不动）。
	# BlackBackgroundFixingAntiAliasingBug（Map.tscn 自带 Y=-0.1 黑垫板）：
	# GL 兼容渲染下水缘陡壁格子掠射角不被光栅化，垂直俯视透出该黑垫板，
	# 形成贴水一圈 ~1.3m 纯黑锯齿边（47-0 像素取证 + A/B 实验证实；
	# 隐藏后水蓝直接衔接沙色，无残留）。隐藏代价是地图边界外露环境背景，
	# 属可接受观感；若 Forward+ 下确认需要该垫板做 AA，请改按渲染后端门控。
	var geometry := get_parent()
	if geometry == null:
		return
	var blackbg: Node = geometry.get_node_or_null("BlackBackgroundFixingAntiAliasingBug")
	if blackbg != null:
		blackbg.visible = false
	var map := geometry.get_parent()
	if map == null:
		return
	var collision: Node = map.get_node_or_null("Collision")
	if collision == null:
		return
	for walk in collision.get_children():
		for child in walk.get_children():
			if child is MeshInstance3D and String(child.name).begins_with("GroundMesh"):
				child.visible = false


func _load_mask_uvs(w: int, h: int) -> Array:
	var uvs := PackedVector2Array()
	var uv2s := PackedVector2Array()
	uvs.resize(w * h)
	uv2s.resize(w * h)
	if height_data_path.is_empty():
		return [uvs, uv2s]
	var path: String = height_data_path.get_base_dir() + "/terrain_masks.png"
	if not FileAccess.file_exists(path):
		return [uvs, uv2s]
	var img := Image.load_from_file(path)
	if img == null:
		return [uvs, uv2s]
	img.convert(Image.FORMAT_RGBA8)
	var mw := img.get_width()
	var mh := img.get_height()
	var bytes := img.get_data()
	var sx := float(mw - 1) / float(maxi(w - 1, 1))
	var sy := float(mh - 1) / float(maxi(h - 1, 1))
	for j in range(h):
		for i in range(w):
			var mi := int(round(float(i) * sx))
			var mj := int(round(float(j) * sy))
			var o := (mj * mw + mi) * 4
			var idx := j * w + i
			uvs[idx] = Vector2((bytes[o] / 255.0 - 0.5) * 600.0, (bytes[o + 1] / 255.0 - 0.5) * 600.0)
			uv2s[idx] = Vector2((bytes[o + 2] / 255.0 - 0.5) * 600.0, bytes[o + 3] / 255.0 * 2.0 - 1.0)
	return [uvs, uv2s]


func _build() -> void:
	if height_data_path.is_empty():
		push_error("GeneratedTerrain: height_data_path 未设置")
		return
	if mesh is ArrayMesh:
		return
	var f := FileAccess.open(height_data_path, FileAccess.READ)
	if f == null:
		push_error("GeneratedTerrain: 无法读取高度数据 %s" % height_data_path)
		return
	var w := f.get_32()
	var h := f.get_32()
	if w < 2 or h < 2 or w > 4097 or h > 4097:
		push_error("GeneratedTerrain: 高度数据尺寸非法 %dx%d" % [w, h])
		return
	var data := f.get_buffer((w * h) * 4)
	f.close()
	var heights := data.to_float32_array()
	# 顶点局部间距：height_data 是语义域的上采样（1025 = 512 格 ×2 + 1），顶点
	# 序号**不等于**语义坐标。此前直接按序号当局部坐标（0..1024），使得地形在
	# 世界里的跨度是 1024×world_scale=4096m，而出生点/水面/装饰/碰撞板都在
	# 2048m 内 —— 地形比其余几何大 2 倍，着色特征（河道/台地/崖壁）全部落在
	# 实际几何的 2 倍坐标处（2026-09-14 探针实测 4096m vs 2048m，游戏内与 review
	# 观感不一致的根因）。
	var xz_step := SEMANTIC_SPAN / float(maxi(w - 1, 1))
	var verts := PackedVector3Array()
	verts.resize(w * h)
	var idx := 0
	for j in range(h):
		for i in range(w):
			verts[idx] = Vector3(float(i) * xz_step, heights[idx], float(j) * xz_step)
			idx += 1
	var normals := _compute_normals(heights, w, h, xz_step)
	var indices := PackedInt32Array()
	indices.resize((w - 1) * (h - 1) * 6)
	var k := 0
	for j in range(h - 1):
		for i in range(w - 1):
			var v00 := j * w + i
			indices[k] = v00
			indices[k + 1] = v00 + w
			indices[k + 2] = v00 + 1
			indices[k + 3] = v00 + 1
			indices[k + 4] = v00 + w
			indices[k + 5] = v00 + w + 1
			k += 6
	# 共享 shader 的着色掩码：从 terrain_masks.png 采样写入 UV/UV2
	# （与 review 渲染器同机制：UV=(plateau_d, shore_d) 米，UV2=(lake_d, cls)）
	var masks := _load_mask_uvs(w, h)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = masks[0]
	arrays[Mesh.ARRAY_TEX_UV2] = masks[1]
	arrays[Mesh.ARRAY_INDEX] = indices
	var am := ArrayMesh.new()
	am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh = am


func _compute_normals(heights: PackedFloat32Array, w: int, h: int, xz_step: float) -> PackedVector3Array:
	# 解析法线 n = normalize(-dh/dx, 1, -dh/dz)（中心差分，边界前向/后向）。
	# dh 是语义米，dx/dz 必须换算成同一局部单位的间距（序号差 × xz_step），
	# 否则顶点 XZ 一旦重标定，法线坡度就会整体偏掉 xz_step 倍。
	var normals := PackedVector3Array()
	normals.resize(w * h)
	for j in range(h):
		var jm: int = maxi(j - 1, 0)
		var jp: int = mini(j + 1, h - 1)
		for i in range(w):
			var im: int = maxi(i - 1, 0)
			var ip: int = mini(i + 1, w - 1)
			var dhx: float = heights[j * w + ip] - heights[j * w + im]
			var dhz: float = heights[jp * w + i] - heights[jm * w + i]
			var dx: float = float(ip - im) * xz_step
			var dz: float = float(jp - jm) * xz_step
			var n := Vector3(-dhx / dx, 1.0, -dhz / dz).normalized()
			normals[j * w + i] = n
	return normals
