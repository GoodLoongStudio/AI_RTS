extends MeshInstance3D

## 建造范围指示（放置蓝图时显示的白色可建区）。
##
## 【2026-10-12 用户报"白色蓝图交叠后太亮，不要叠色"】旧实现给每个圈各生成
## 一套三角形扇塞进同一个 mesh：透明材质下交叠三角形各自混合一次
## （alpha 0.22 → 0.39 → 0.53…），基地圈簇越密越白。
## 现在改为**并集掩码**：所有圈先以"覆写"语义写进同一张掩码纹理
## （fill_rect 天然并集，交叠像素只写一次），再用贴地高度场网格采样它——
## 任意点的亮度恒为 albedo_color，与圈数无关。

const GROUND_OFFSET := 0.06
## 掩码纹理分辨率（像素/米）。上限防大范围（指挥中心级）爆显存。
const TEX_PIXELS_PER_M := 3.0
const MAX_TEXTURE_SIDE := 1024
## 高度场网格密度：≤48×48 顶点，控制 ground_height_at 采样次数。
const MAX_GRID_VERTS_PER_SIDE := 48
const MIN_GRID_CELL_M := 2.0

var _match: Node3D
var _player: Node
var _runtime: Node
var _prototype: PackedScene
var _retry_in := 0.0


func configure(match_node: Node3D, player: Node, runtime: Node, prototype: PackedScene) -> void:
	_match = match_node
	_player = player
	_runtime = runtime
	_prototype = prototype
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.albedo_color = Color(1.0, 1.0, 1.0, 0.22)
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.render_priority = 2
	material_override = material
	_publish_mesh()


func _process(delta: float) -> void:
	if mesh != null or _runtime == null or not is_instance_valid(_player):
		return
	_retry_in -= delta
	if _retry_in <= 0.0:
		_publish_mesh()
		_retry_in = 0.2


func set_blueprint_yaw(_yaw: float) -> void:
	# The range is rotationally invariant. Keep the method so the handler can
	# update the preview through one stable interface while the blueprint turns.
	pass


func _publish_mesh() -> void:
	mesh = null
	var circles = _runtime.BuildAreaCircles(_player, _prototype)
	if circles.is_empty():
		# The command center is the one remote-anchor structure: its candidate
		# area is the complete map rectangle rather than a union of local discs.
		var bounds: Rect2 = _runtime.BuildAreaBounds(_player, _prototype)
		if bounds.has_area():
			_publish_rect_mesh(bounds)
		return
	_publish_union_mesh(circles)


## 指挥中心的整图矩形回退：单一矩形、无交叠，保持旧几何口径即可。
func _publish_rect_mesh(bounds: Rect2) -> void:
	var vertices := PackedVector3Array()
	var a := to_local(_ground_point(bounds.position) + Vector3.UP * GROUND_OFFSET)
	var b := to_local(
		_ground_point(bounds.position + Vector2(bounds.size.x, 0.0)) + Vector3.UP * GROUND_OFFSET
	)
	var c := to_local(
		_ground_point(bounds.position + Vector2(0.0, bounds.size.y)) + Vector3.UP * GROUND_OFFSET
	)
	var d := to_local(_ground_point(bounds.position + bounds.size) + Vector3.UP * GROUND_OFFSET)
	vertices.append_array(PackedVector3Array([a, c, b, b, c, d]))
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	var surface := ArrayMesh.new()
	surface.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh = surface


## 圆并集：先栅格化掩码（覆写=并集），再生成贴地高度场网格采样掩码。
func _publish_union_mesh(circles) -> void:
	var min_xy := Vector2(INF, INF)
	var max_xy := Vector2(-INF, -INF)
	for circle in circles:
		var center: Vector2 = circle["center"]
		var radius := maxf(float(circle["radius"]), 0.0)
		if radius <= 0.0:
			continue
		min_xy = min_xy.min(center - Vector2(radius, radius))
		max_xy = max_xy.max(center + Vector2(radius, radius))
	var size := max_xy - min_xy
	if size.x <= 0.0 or size.y <= 0.0:
		return
	var pad := 0.5
	min_xy -= Vector2(pad, pad)
	size += Vector2(pad * 2.0, pad * 2.0)

	var pixels_per_m := clampf(MAX_TEXTURE_SIDE / maxf(maxf(size.x, size.y), 1.0), 0.5, TEX_PIXELS_PER_M)
	var tex_w := maxi(2, int(ceil(size.x * pixels_per_m)))
	var tex_h := maxi(2, int(ceil(size.y * pixels_per_m)))
	var img := Image.create_empty(tex_w, tex_h, false, Image.FORMAT_RGBA8)
	for circle in circles:
		var center: Vector2 = circle["center"]
		var radius := maxf(float(circle["radius"]), 0.0)
		if radius <= 0.0:
			continue
		_span_fill_circle(img, center, radius, min_xy, pixels_per_m, tex_w, tex_h)
	if img.is_invisible():
		return
	var texture := ImageTexture.create_from_image(img)

	var cell := maxf(MIN_GRID_CELL_M, maxf(size.x, size.y) / float(MAX_GRID_VERTS_PER_SIDE))
	var columns := maxi(1, int(ceil(size.x / cell)))
	var rows := maxi(1, int(ceil(size.y / cell)))
	var vertices := PackedVector3Array()
	var uvs := PackedVector2Array()
	vertices.resize((columns + 1) * (rows + 1))
	uvs.resize((columns + 1) * (rows + 1))
	for row in rows + 1:
		var world_y := minf(min_xy.y + float(row) * cell, min_xy.y + size.y)
		for column in columns + 1:
			var world_x := minf(min_xy.x + float(column) * cell, min_xy.x + size.x)
			var index := row * (columns + 1) + column
			vertices[index] = to_local(_ground_point(Vector2(world_x, world_y)) + Vector3.UP * GROUND_OFFSET)
			uvs[index] = Vector2(
				(world_x - min_xy.x) * pixels_per_m / float(tex_w),
				(world_y - min_xy.y) * pixels_per_m / float(tex_h)
			)
	var indices := PackedInt32Array()
	for row in rows:
		for column in columns:
			var p00 := row * (columns + 1) + column
			var p10 := p00 + 1
			var p01 := p00 + (columns + 1)
			var p11 := p01 + 1
			# 与旧矩形回退同绕向（[a, c, b] / [b, c, d]），且 cull 关闭、双面可见。
			indices.append_array(PackedInt32Array([p00, p01, p10, p10, p01, p11]))
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	var surface := ArrayMesh.new()
	surface.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh = surface
	var material := material_override as StandardMaterial3D
	if material != null:
		material.albedo_texture = texture


## 单个圆的掩码写入：逐行算 x 跨度、fill_rect 整行覆写。
## 覆写（而非叠加）保证多圆交叠区 alpha 恒为 1 —— 这是"不叠色"的关键。
func _span_fill_circle(
	img: Image, center: Vector2, radius: float,
	min_xy: Vector2, pixels_per_m: float, tex_w: int, tex_h: int
) -> void:
	var cx := (center.x - min_xy.x) * pixels_per_m
	var cy := (center.y - min_xy.y) * pixels_per_m
	var radius_px := radius * pixels_per_m
	var first_row := clampi(int(floor(cy - radius_px)), 0, tex_h - 1)
	var last_row := clampi(int(ceil(cy + radius_px)), 0, tex_h - 1)
	for row in range(first_row, last_row + 1):
		var dy_m := (float(row) + 0.5 - cy) / pixels_per_m
		var half_span_m := radius * radius - dy_m * dy_m
		if half_span_m <= 0.0:
			continue
		var half_span := sqrt(half_span_m) * pixels_per_m
		var x0 := clampi(int(floor(cx - half_span)), 0, tex_w - 1)
		var x1 := clampi(int(ceil(cx + half_span)), 0, tex_w - 1)
		if x1 < x0:
			continue
		img.fill_rect(Rect2i(x0, row, x1 - x0 + 1, 1), Color(1.0, 1.0, 1.0, 1.0))


func _ground_point(point: Vector2) -> Vector3:
	var world := Vector3(point.x, 0.0, point.y)
	world.y = _match.ground_height_at(world)
	return world
