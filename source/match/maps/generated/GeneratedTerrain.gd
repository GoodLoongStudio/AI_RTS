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
## Map.tscn 基座 Geometry 对本节点的等比缩放（顶点 0-512 -> 世界 0-2048 时为 4）。
## shader 内所有高度锚点（水床/岸线/台地/山体）按未缩放顶点坐标编写，
## vertex 里除回该值，否则缩放把 world_pos.y 抬高 N 倍导致全部着色锚点错位。
@export var world_scale := 1.0
@export var terrain_albedo: Color = Color(0.80, 0.72, 0.60, 1)
@export var terrain_roughness: float = 1.0  # 兼容保留（着色器固定 roughness 1.0）
@export var terrain_shaded: bool = false    # 兼容保留（着色器恒为受光模式）

const TERRAIN_SHADER_CODE := "
shader_type spatial;
render_mode cull_disabled;

uniform vec3 base_tint : source_color = vec3(1.0, 1.0, 1.0);
uniform float world_scale = 1.0;
uniform vec3 bed_color : source_color = vec3(0.30, 0.34, 0.36);
uniform vec3 shore_color : source_color = vec3(0.72, 0.62, 0.44);
uniform vec3 sand_color : source_color = vec3(0.80, 0.62, 0.38);
uniform vec3 soil_color : source_color = vec3(0.63, 0.54, 0.38);
uniform vec3 plateau_color : source_color = vec3(0.93, 0.90, 0.78);
uniform sampler2D sand_tex : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D detail_tex : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D top_tex : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D rock_tex : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D detail2_tex : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D sand_nrm : filter_linear_mipmap, repeat_enable;
uniform sampler2D rock_nrm : filter_linear_mipmap, repeat_enable;
uniform sampler2D macro_sand : source_color, filter_linear_mipmap, repeat_enable;

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

vec3 triplanar(sampler2D t, vec3 pos, vec3 n, float s) {
	vec3 w = pow(abs(n), vec3(6.0));
	w /= max(dot(w, vec3(1.0)), 1e-4);
	return texture(t, pos.zy * s).rgb * w.x + texture(t, pos.xz * s).rgb * w.y
	     + texture(t, pos.xy * s).rgb * w.z;
}

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz / max(world_scale, 0.001);
	world_n = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

void fragment() {
	if (!FRONT_FACING) {
		NORMAL = -NORMAL;
	}
	vec3 wp = world_pos;
	vec3 wn = normalize(world_n);
	// hv = 顶点高度域的权威值（平地 0.6 / 台地 3.6 / 山峰 ~23），
	// 对任意基座缩放通用；xz 保持世界坐标（噪声密度随地图尺寸自然变化）。
	float hs = max(world_scale, 0.001);
	float hv = wp.y / hs;
	float h = hv;
	float flatness = clamp(wn.y, 0.0, 1.0);

	float facet = vnoise(wp.xz * 0.025);
	float litho = vnoise(wp.xz * 0.011 + vec2(3.0, 33.0));
	float mid40 = vnoise(wp.xz * 0.028 + vec2(57.0, 91.0));
	float macro1 = vnoise(wp.xz * 0.0020);
	float macro3 = vnoise(wp.xz * 0.035 - vec2(5.0, 9.0));
	float belt250 = vnoise(wp.xz * 0.004 + vec2(23.0, 87.0));
	float dune45 = vnoise(wp.xz * 0.022 + vec2(5.0, 71.0));
	float rock_band = vnoise(wp.xz * 0.011 + vec2(11.0, 29.0));
	float cloud = vnoise(wp.xz * 0.0011 + vec2(77.0, 31.0)) * 0.65
	            + vnoise(wp.xz * 0.0032 + vec2(9.0, 51.0)) * 0.35;

	// ---- 1. 沙地：真实贴图 + 程序化色带/云影 ----
	vec3 ground = texture(sand_tex, wp.xz * 0.05).rgb;
	ground = mix(ground, texture(detail_tex, wp.xz * 0.026).rgb,
	             smoothstep(0.35, 0.80, macro3) * 0.4);
	ground = mix(ground, ground * vec3(1.07, 1.00, 0.89), smoothstep(0.42, 0.72, belt250) * 0.34);
	ground *= 0.955 + dune45 * 0.11;
	ground *= 0.92 + macro3 * 0.16;
	ground = mix(ground, texture(macro_sand, wp.xz * 0.0011).rgb, 0.30);
	ground *= 1.0 - smoothstep(0.48, 0.86, cloud) * 0.16;

	// ---- 2. 水床与岸线 ----
	float bed_m = 1.0 - smoothstep(-1.6, -0.2, hv);
	vec3 bed = mix(bed_color, vec3(0.55, 0.50, 0.38), smoothstep(-2.2, -0.4, hv));
	float shore_band = 1.0 - smoothstep(0.0, 2.2, abs(hv - 0.55));

	// ---- 3. 台地顶 ----
	float on_top = smoothstep(3.2, 3.55, hv) * (1.0 - smoothstep(3.65, 4.4, hv));
	vec3 top_col = texture(top_tex, wp.xz * 0.012).rgb * (0.92 + macro3 * 0.14);

	// ---- 4. 山体四色区（真实岩石贴图 + 沉积岩条带）----
	float mountain_in = smoothstep(9.0, 22.0, hv);
	float steepness = 1.0 - smoothstep(0.50, 0.86, flatness);
	float altitude = smoothstep(12.0, 55.0, hv);
	vec3 wall_dark = vec3(0.30, 0.235, 0.175);
	vec3 ridge_red = vec3(0.60, 0.375, 0.215);
	vec3 weathered = vec3(0.50, 0.435, 0.35);
	vec3 rock_zone = mix(weathered, wall_dark, steepness * 0.90);
	rock_zone = mix(rock_zone, ridge_red, altitude * (1.0 - steepness * 0.45) * 0.85);
	float strata_band = sin(hv * 0.42 + rock_band * 7.0 + facet * 2.4 + macro3 * 1.6) * 0.5 + 0.5;
	vec3 bed_a = vec3(0.24, 0.165, 0.115);
	vec3 bed_b = vec3(0.52, 0.385, 0.27);
	rock_zone = mix(rock_zone, mix(bed_a, bed_b, strata_band),
	    mountain_in * 0.82 * (0.45 + 0.55 * (0.5 + 0.5 * rock_band)));
	rock_zone *= 0.68 + facet * 0.30 + litho * 0.16 + mid40 * 0.12;

	// ---- 合成 ----
	vec3 col = ground;
	col = mix(col, bed, bed_m);
	col = mix(col, shore_color, shore_band * (1.0 - bed_m) * 0.6);
	float rock_m = clamp(mountain_in * (0.55 + 0.45 * smoothstep(0.30, 0.65, flatness))
	    + steepness * mountain_in * 0.5, 0.0, 1.0);
	col = mix(col, rock_zone, rock_m);
	col = mix(col, top_col, on_top * (1.0 - mountain_in) * 0.85);

	float n2 = vnoise(wp.xz * 0.55) * 0.5 + vnoise(wp.xz * 1.9) * 0.3;
	col *= 0.88 + 0.24 * n2;
	col *= vec3(1.05, 0.99, 0.90);
	col = mix(col, col * col * 1.35, 0.20);

	ALBEDO = col * base_tint;
	ROUGHNESS = mix(0.9, 0.80, mountain_in);

	// ---- 微凹凸：贴图法线（岩面 triplanar + 沙地平面）+ 程序化梯度 ----
	vec3 n_sand = texture(sand_nrm, wp.xz * 0.05).xyz * 2.0 - 1.0;
	vec3 n_rock = triplanar(rock_nrm, wp, wn, 0.062) * 2.0 - 1.0;
	vec2 gq = wp.xz * 0.24;
	float gn0 = vnoise(gq);
	vec2 bump_g = vec2(vnoise(gq + vec2(0.85, 0.0)) - gn0,
	                   vnoise(gq + vec2(0.0, 0.85)) - gn0);
	vec3 nrm = mix(n_sand, n_rock, mountain_in);
	nrm.x += bump_g.x * 1.2 * mountain_in;
	nrm.y += bump_g.y * 1.2 * mountain_in;
	vec3 bump_world = vec3(nrm.x, 0.0, nrm.y) * (0.10 + 0.40 * mountain_in);
	vec3 bump_view = (VIEW_MATRIX * vec4(bump_world, 0.0)).xyz;
	NORMAL = normalize(normalize(NORMAL) + bump_view);
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
	mat.set_shader_parameter("world_scale", world_scale)
	var pbr := "res://assets/terrain_pbr/"
	for pair in [
		["sand_tex", "dense_sand_diff.jpg"], ["sand_nrm", "dense_sand_normal.jpg"],
		["detail_tex", "sand_01_diff.jpg"], ["top_tex", "moon_dusted_03_diff.jpg"],
		["rock_tex", "dark_rock_02_diff.jpg"], ["rock_nrm", "dark_rock_02_normal.jpg"],
		["detail2_tex", "gray_rocks_diff.jpg"], ["macro_sand", "image25_macro_sand.png"],
	]:
		var tex := load(pbr + pair[1])
		if tex != null:
			mat.set_shader_parameter(pair[0], tex)
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
