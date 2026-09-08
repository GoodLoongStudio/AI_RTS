extends MeshInstance3D
## 生成地图的真实地形网格：读取 G4 height_data.bin（与 Python 校验同源的高度场），
## 运行时构建 ArrayMesh。Match._setup_subsystems_dependent_on_map 随后用本网格
## create_trimesh_shape 建碰撞，导航烘焙自碰撞 —— 视觉/碰撞/导航/高度查询同源。
##
## height_data.bin 格式：int32 w, int32 h, float32[h*w]（行主序，little-endian）。
## 顶点 (i,j) 位于世界坐标 (x=i, z=j)，覆盖 [0,w-1]×[0,h-1]（256m 图 = 257×257）。
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
@export var terrain_albedo: Color = Color(0.80, 0.72, 0.60, 1)
@export var terrain_roughness: float = 1.0  # 兼容保留（着色器固定 roughness 1.0）
@export var terrain_shaded: bool = false    # 兼容保留（着色器恒为受光模式）

const TERRAIN_SHADER_CODE := "
shader_type spatial;
render_mode cull_disabled;

uniform vec3 base_tint : source_color = vec3(1.0, 1.0, 1.0);
uniform vec3 bed_color : source_color = vec3(0.42, 0.38, 0.30);
uniform vec3 sand_color : source_color = vec3(0.76, 0.68, 0.50);
uniform vec3 soil_color : source_color = vec3(0.63, 0.54, 0.38);
uniform vec3 dry_color : source_color = vec3(0.69, 0.61, 0.45);
uniform vec3 rock_color : source_color = vec3(0.52, 0.47, 0.40);

varying vec3 world_pos;
varying vec3 world_n;

float hash12(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	float a = hash12(i);
	float b = hash12(i + vec2(1.0, 0.0));
	float c = hash12(i + vec2(0.0, 1.0));
	float d = hash12(i + vec2(1.0, 1.0));
	return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

float fbm2(vec2 p) {
	return vnoise(p) * 0.65 + vnoise(p * 2.3 + 17.1) * 0.35;
}

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_n = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

void fragment() {
	// 背面法线翻转：cull_disabled 下背面按原法线着色会全黑（GL 兼容实测），
	// 崖壁/岸线从斜视角度看时必须翻转，否则出现黑色锯齿面。
	if (!FRONT_FACING) {
		NORMAL = -NORMAL;
	}
	// 色带锚点：水床 -2.4 / 水面 0 / 平地 0.6 / 台地 3.6；中频噪声让带边界有机摆动。
	float wob = (vnoise(world_pos.xz * 0.08) - 0.5) * 1.4;
	float h = world_pos.y + wob;
	vec3 col = bed_color;
	col = mix(col, sand_color, smoothstep(-1.8, -0.9, h));
	col = mix(col, soil_color, smoothstep(0.5, 1.5, h));
	// 台地顶沿用主地表土色；高度层级由崖壁、坡面和受光差异表达，
	// 不把台地误标成独立草地生物群系。
	// 宏观色斑：~30m 尺度干草/土壤斑块打破大面积单色（只改颜色不改高程）。
	float patch = fbm2(world_pos.xz * 0.035);
	float on_low = 1.0 - smoothstep(1.6, 2.4, world_pos.y);
	col = mix(col, dry_color, patch * 0.30 * on_low);
	col = mix(col, col * vec3(1.05, 1.01, 0.95), fbm2(world_pos.xz * 0.013 + 41.7) * on_low * 0.3);
	// 陡坡岩化：崖壁法线接近水平 → rock≈1；坡道缓坡（n.y≈0.94）不受影响。
	float rock = 1.0 - smoothstep(0.55, 0.80, world_n.y);
	col = mix(col, rock_color, rock);
	// 细尺度明度噪声，避免大色块平板。
	float n2 = vnoise(world_pos.xz * 0.55) * 0.5 + vnoise(world_pos.xz * 1.9) * 0.3;
	col *= 0.84 + 0.30 * n2;
	ALBEDO = col * base_tint;
	ROUGHNESS = 1.0;
}
"


func _enter_tree() -> void:
	# 必须在 _enter_tree（add_child 同步回调）建网格：Match._ready 会在同一帧
	# 调用 Terrain.update_shape(mesh) 捕提碰撞 trimesh，若等到 _ready 才建网格，
	# 捕到的是基 PlaneMesh（平地），导航/碰撞与真实高程脱节。
	_build()


func _ready() -> void:
	# 材质在 _ready 设置（树就绪后），避免 _enter_tree 过早赋值被覆盖/黑面。
	_apply_material()
	_hide_redundant_ground_plates()


func _apply_material() -> void:
	var sh := Shader.new()
	sh.code = TERRAIN_SHADER_CODE
	var mat := ShaderMaterial.new()
	mat.shader = sh
	# visual_api 的 terrain_albedo 作全局色调：按亮度归一（默认 0.80,0.72,0.60
	# 归一为轻微暖偏；profile 调该值即可整体调暖/调冷）。
	var tint := terrain_albedo
	if tint.a <= 0.0:
		tint = Color(1, 1, 1, 1)
	var lum: float = tint.r * 0.299 + tint.g * 0.587 + tint.b * 0.114
	if lum > 0.001:
		tint = Color(tint.r / lum, tint.g / lum, tint.b / lum, 1.0)
	mat.set_shader_parameter("base_tint", Vector3(tint.r, tint.g, tint.b))
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
	var verts := PackedVector3Array()
	verts.resize(w * h)
	var idx := 0
	for j in range(h):
		for i in range(w):
			verts[idx] = Vector3(float(i), heights[idx], float(j))
			idx += 1
	var normals := _compute_normals(heights, w, h)
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
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_INDEX] = indices
	var am := ArrayMesh.new()
	am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh = am


func _compute_normals(heights: PackedFloat32Array, w: int, h: int) -> PackedVector3Array:
	# 解析法线 n = normalize(-dh/dx, 1, -dh/dz)（中心差分，边界前向/后向）
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
			var dx: float = float(ip - im)
			var dz: float = float(jp - jm)
			var n := Vector3(-dhx / dx, 1.0, -dhz / dz).normalized()
			normals[j * w + i] = n
	return normals
