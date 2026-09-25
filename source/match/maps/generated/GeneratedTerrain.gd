extends MeshInstance3D
## 生成地图的真实地形网格：读取 G4 height_data.bin（与 Python 校验同源的高度场），
## 运行时构建 ArrayMesh。生成图的碰撞不走 trimesh：禁行格 + 高度采样。
##
## height_data.bin 格式：int32 w, int32 h, float32[h*w]（行主序，little-endian）。
## 顶点 (i,j) 的局部坐标 = (i*xz_step, h, j*xz_step)，xz_step = SEMANTIC_SPAN/(w-1)；
## 即顶点覆盖语义域 [0,SEMANTIC_SPAN]²，再经 Map 基座 scale=world_scale 换算成
## 世界米（256 语义默认 1:1）。高度是**语义米**，同样由 Map 的 Y 缩放换算。
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
## G2 语义域跨度（米）。高度场以其为坐标系，顶点间距 = span/(w-1)。
## G4 四人图默认 256。个别旧导出可改 semantic_span。
const SEMANTIC_SPAN := 256.0
@export var semantic_span := 256.0
## Map.tscn 基座 Geometry 对本节点的等比缩放（256 图通常为 1）。
## shader 内所有高度锚点（水床/岸线/台地/山体）按未缩放顶点坐标编写，
## vertex 里除回该值，否则缩放把 world_pos.y 抬高 N 倍导致全部着色锚点错位。
@export var world_scale := 1.0
@export var terrain_albedo: Color = Color(0.80, 0.72, 0.60, 1)
@export var terrain_roughness: float = 1.0  # 兼容保留（着色器固定 roughness 1.0）
@export var terrain_shaded: bool = false    # 兼容保留（着色器恒为受光模式）


func _terrain_span() -> float:
	return semantic_span if semantic_span > 1.0 else SEMANTIC_SPAN


func _enter_tree() -> void:
	# 必须在 _enter_tree 建网格：同帧就要换轻量材质并删作者碰撞/水面。
	_build()
	# 第一帧就要换着色器、藏 200+ 半透明水面片。放到 _ready 时玩家已经看见
	# 肉色雾/沙色盒，并且 Compatibility 透明排序已经把帧率打穿。
	_apply_material()
	_hide_redundant_ground_plates()


func _ready() -> void:
	# 桥面必须在这里收集：`_enter_tree` 时 Collision 兄弟子树还没进树，
	# `CollisionShape3D.global_transform` 还是单位阵（实测三座桥的矩形全落原点）；
	# 而 `_apply_g4_runtime_budget` / `Match._setup_subsystems_dependent_on_map` 的
	# 清理又会 free 掉 `Collision/*`。`_ready` 自底向上触发，是唯一两者都满足的时机。
	_collect_bridge_rects()
	# 作者碰撞/水面的清理从 `_enter_tree` 挪到这里：必须晚于桥面收集
	# （清理会 free 掉 `Collision/*`，而 `_enter_tree` 时桥节点还没进树、
	# global_transform 还是单位阵）。仍在同一帧， perf 语义不变。
	_purge_large_map_authoring_nodes()
	_apply_material()
	_wire_water_mask()
	_hide_redundant_ground_plates()
	# 必须在 Match._ready 的导航烘焙之前执行（本节点 _ready 早于父节点）。
	_strip_legacy_ground_plates()
	_apply_g4_runtime_budget()
	_build_water_occupancy()
	_ground_resource_nodes()
	_print_g4_runtime_diagnostics()


## 资源点贴地（2026-09-15 用户报"大湖地图的矿显示有问题"）。
##
## 生成器写资源点用的 y 比**真实地面**低 0.45m（实测该图 16/16 个矿的
## `y - sample_height(x,z)` 恒为 -0.45），而 `rock_crystalsLargeA` 模型本体只有
## 0.54m 高 ⇒ 只露出约 0.1m，视觉上就是"埋进地里的一小片碎片"
## （同模型在 PlainAndSimple 手做图上 y 与地面差 ≈ 0，完全露出，故仅生成图有此现象）。
## 这里按高度场把 Resources 子树里的每个资源点抬到地面：只改**根节点 y**，
## 不动模型/材质/子节点偏移；抬完与手做图口径一致。
func _ground_resource_nodes() -> void:
	var geometry := get_parent()
	var map_node: Node = geometry.get_parent() if geometry != null else null
	if map_node == null:
		return
	var resources: Node = map_node.get_node_or_null("Resources")
	if resources == null:
		return
	var fixed := 0
	for ore in resources.get_children():
		if not (ore is Node3D):
			continue
		var node := ore as Node3D
		var ground := sample_height(node.position.x, node.position.z)
		if absf(node.position.y - ground) > 0.01:
			node.position.y = ground
			fixed += 1
	print("G4PERF resources_grounded=", fixed)


## 地形不进物理世界：一张禁行格 + 高度采样。水/岩禁行，桥面走廊除外。
var _water_bits := PackedByteArray()
var _water_w := 0
var _water_h := 0
var _water_span := SEMANTIC_SPAN
var _bridge_rects: Array[Rect2] = []
## 桥面可走板：未大外扩的 XZ + 板顶高度。过桥站立用这个，不用河床。
var _bridge_slabs: Array[Dictionary] = []
var _water_ready := false
var _height_samples := PackedFloat32Array()
var _height_w := 0
var _height_h := 0
## 粗网格高层寻路（约 2m/格）。大图不烘 Recast，地面单位走这张图绕水/崖。
var _path_grid: AStarGrid2D
var _path_w := 0
var _path_h := 0
var _path_cell := 2.0
var _path_scale := 4
var _path_cache: Dictionary = {}
## 建筑足迹：id → 覆盖的粗网格格。矿点不进这里，避免工人采不到。
var _structure_blockers: Dictionary = {}
var _structure_cell_ref: Dictionary = {}
const MAX_GROUND_STEP_M := 2.4
const PATH_CACHE_MAX := 192
const PATH_COARSE_MIN_WALKABLE := 2
## 建筑足迹略小于避让半径，外圈留给工人贴边施工/回城。
const STRUCTURE_STAMP_RADIUS_SCALE := 0.85
const STRUCTURE_STAMP_RADIUS_MIN := 1.15


func _absolute_data_path(res_path: String) -> String:
	if res_path.is_empty():
		return ""
	if FileAccess.file_exists(res_path):
		var as_os := ProjectSettings.globalize_path(res_path)
		if FileAccess.file_exists(as_os):
			return as_os
		return res_path
	var abs_path := ProjectSettings.globalize_path(res_path)
	if FileAccess.file_exists(abs_path):
		return abs_path
	return res_path


func _load_image_from_res(res_path: String) -> Image:
	var abs_path := _absolute_data_path(res_path)
	if abs_path.is_empty():
		return null
	var img := Image.load_from_file(abs_path)
	if img != null and not img.is_empty():
		return img
	if ResourceLoader.exists(res_path):
		var tex = load(res_path)
		if tex is Texture2D:
			return (tex as Texture2D).get_image()
	return null


func _collapse_expensive_water() -> void:
	_purge_large_map_authoring_nodes()


func _purge_large_map_authoring_nodes() -> void:
	var geometry := get_parent()
	var map_node: Node = geometry.get_parent() if geometry != null else null
	if map_node == null or not _is_g4_runtime_map(map_node):
		return
	var water_removed := _free_all_children(map_node.get_node_or_null("WaterBody"))
	var collision_removed := _free_all_children(map_node.get_node_or_null("Collision"))
	if water_removed > 0 or collision_removed > 0:
		print(
			"G4PERF authoring_removed water=",
			water_removed,
			" collision=",
			collision_removed
		)


func _free_all_children(parent: Node) -> int:
	if parent == null:
		return 0
	var removed := parent.get_child_count()
	while parent.get_child_count() > 0:
		var child: Node = parent.get_child(parent.get_child_count() - 1)
		parent.remove_child(child)
		child.free()
	return removed


func _apply_g4_runtime_budget() -> void:
	var map_node := get_parent().get_parent() if get_parent() != null else null
	if map_node == null or not _is_g4_runtime_map(map_node):
		return
	# 桥面必须在清理**之前**收集：`_purge_large_map_authoring_nodes` 会 free 掉
	# `Collision/*`（含 `Bridge*/DeckBody`），之后再收集就一座都不剩
	# （2026-09-21 用户报"过桥寻路很严重"：桥面数据恒空 → 水面格禁行 → 桥不能过）。
	_collect_bridge_rects()
	_purge_large_map_authoring_nodes()
	var lights := 0
	for node in map_node.find_children("*", "Light3D", true, false):
		var light := node as Light3D
		if light != null and light.shadow_enabled:
			light.shadow_enabled = false
			lights += 1
	var decor_stats := _apply_g4_decoration_budget(map_node)
	var stripped := _strip_leftover_map_physics(map_node)
	print("G4PERF budget water_removed=purged",
		" shadows_disabled=", lights,
		" decor_culled=", decor_stats.get("culled", 0),
		" decor_shadow_off=", decor_stats.get("shadow_off", 0),
		" collision_left=", decor_stats.get("collision_disabled", 0),
		" physics_stripped=", stripped)


func _build_water_occupancy() -> void:
	var geometry := get_parent()
	var map_node: Node = geometry.get_parent() if geometry != null else null
	if map_node == null or not _is_g4_runtime_map(map_node):
		return
	var map_size: Variant = map_node.get("size")
	if map_size is Vector2 and map_size.x > 1.0:
		_water_span = maxf(map_size.x, map_size.y)
	# 桥面收集**不依赖掩码**：先收，掩码缺失的回退路径也要能标"桥上可走"。
	if _bridge_rects.is_empty():
		_collect_bridge_rects()
	var path: String = height_data_path.get_base_dir() + "/terrain_masks.png"
	var img := _load_image_from_res(path)
	var blocked := 0
	if img != null and not img.is_empty():
		img.convert(Image.FORMAT_RGBA8)
		_water_w = img.get_width()
		_water_h = img.get_height()
		var bytes := img.get_data()
		_water_bits.resize(_water_w * _water_h)
		var i := 0
		while i < _water_w * _water_h:
			# G = shore_d，内部为负（河+湖）。A = cls，正=岩/山，负=坡道。
			var shore_d := (float(bytes[i * 4 + 1]) / 255.0 - 0.5) * 600.0
			var cls := float(bytes[i * 4 + 3]) / 255.0 * 2.0 - 1.0
			var blocked_cell := 1 if (shore_d < -0.4 or cls > 0.35) else 0
			_water_bits[i] = blocked_cell
			blocked += blocked_cell
			i += 1
	else:
		# 2026-09-21 用户报"生成图上工人采矿/过桥寻路全废"的根因：已安装的生成图
		# （47-0/16-0/49-*/35-0…）**没有 terrain_masks.png**（旧版安装器不拷它）。
		# 旧实在这里直接 return → 占用格从不建立 → `_request_logic_path` 找不到
		# occupancy 就退化为"直线走目标"（水/崖一律撞上去），`_on_bridge` 恒 false、
		# 过桥永不吸附，`is_ground_blocked` 对水/岩全不判 → 整张图的逻辑寻路瘫痪。
		# 这里改为按**高度场**推导禁行格（水/低地 + 陡坡），让任何生成图都有寻路可用。
		push_warning("GeneratedTerrain: 水域禁行掩码读失败 %s；按高度场推导禁行格（水/陡崖）" % path)
		blocked = _build_blocked_from_heightfield()
	var cliffs := _stamp_steep_cliffs()
	var submerged := _stamp_submerged_cells()
	_stamp_bridges_walkable()
	_water_ready = true
	map_node.set_meta("water_occupancy", self)
	_build_path_grid()
	print(
		"G4PERF terrain_block cells=",
		blocked,
		"/",
		_water_w * _water_h,
		" cliffs=",
		cliffs,
		" submerged=",
		submerged,
		" span=",
		_water_span,
		" bridges=",
		_bridge_rects.size()
	)


## 按高度场推导禁行格（terrain_masks.png 缺失时的兜底，2026-09-21）。
## 判据与 `_stamp_submerged_cells` / `_stamp_steep_cliffs` 完全同源：
##   ① 高度 < 0.15m → 水/低地禁行（与 `is_ground_blocked` 的地表门槛一致）；
##   ② 四邻高差 > `MAX_GROUND_STEP_M`(2.4m) → 陡崖禁行（爬不上去）。
## 分辨率直接用高度场网格，世界映射仍走 `_water_span`（span/(w-1) = 格距）。
func _build_blocked_from_heightfield() -> int:
	if _height_w < 2 or _height_h < 2 or _height_samples.is_empty():
		push_warning("GeneratedTerrain: 高度场不可用，禁行格回退也失败（寻路将退化）")
		return 0
	_water_w = _height_w
	_water_h = _height_h
	_water_bits.resize(_water_w * _water_h)
	var blocked := 0
	var iz := 0
	while iz < _water_h:
		var ix := 0
		while ix < _water_w:
			var h := _height_samples[iz * _water_w + ix]
			var is_blocked := h < 0.15
			if not is_blocked:
				if ix > 0 and absf(_height_samples[iz * _water_w + ix - 1] - h) > MAX_GROUND_STEP_M:
					is_blocked = true
				elif ix + 1 < _water_w and absf(_height_samples[iz * _water_w + ix + 1] - h) > MAX_GROUND_STEP_M:
					is_blocked = true
				elif iz > 0 and absf(_height_samples[(iz - 1) * _water_w + ix] - h) > MAX_GROUND_STEP_M:
					is_blocked = true
				elif iz + 1 < _water_h and absf(_height_samples[(iz + 1) * _water_w + ix] - h) > MAX_GROUND_STEP_M:
					is_blocked = true
			if is_blocked:
				blocked += 1
			_water_bits[iz * _water_w + ix] = 1 if is_blocked else 0
			ix += 1
		iz += 1
	return blocked


func _collect_bridge_rects() -> void:
	var geometry := get_parent()
	var map_node: Node = geometry.get_parent() if geometry != null else null
	if map_node == null:
		return
	# 幂等：已经收集过就绝不重收。桥面碰撞体在 `_purge_large_map_authoring_nodes`
	# 之后就被 free 了，重复收集只会把已有数据清成空（2026-09-21 实测 bridges 3→0）。
	if not _bridge_rects.is_empty():
		return
	_bridge_rects.clear()
	_bridge_slabs.clear()
	# 桥面碰撞体有两种历史命名，都要认：
	#   ① `WalkB*`（旧生成器直挂在 Collision 下的可行走板）；
	#   ② `Bridge*/DeckBody`（现行导出：Bridge0..N 容器 + DeckBody 甲板）。
	# 只认 ① 时，现行图一座桥都收不到 → `_sample_bridge_deck` 恒 -inf、`_on_bridge`
	# 恒 false、水面格永远禁行 ⇒ **桥完全不能过**（2026-09-21 用户报"过桥寻路很严重"）。
	#
	# 【2026-09-24 修"桥上卡单位非常严重"】RailC*（护栏物理碰撞）**绝不能**进这个
	# 集合：护栏碰撞体被 `_stamp_bridges_walkable` 一起盖成"可走"——寻路网格觉得
	# 干净能过，物理层却是实心墙（layer 1）。于是单位照着网格往护栏上走、被墙挡住，
	# 脱困候选又都在禁入面外，反复几轮后路径查不到起点格 ⇒ 单位在桥头永久冻结
	# （实测：3 单位过桥，t=5s 走上桥 y=1.30，t=10s 被拖回岸 y=0.60，此后 30s 不动）。
	# 护栏只保留"挡住单位不掉下去"的物理职责，不参与高度采样/可走盖章。
	var bodies: Array[Node] = []
	bodies.append_array(map_node.find_children("WalkB*", "StaticBody3D", true, false))
	for container in map_node.find_children("Bridge*", "Node3D", true, false):
		for child in container.find_children("*", "StaticBody3D", true, false):
			var child_name := String(child.name)
			if child_name.begins_with("RailC"):
				continue
			bodies.append(child)
	for node in bodies:
		var body := node as StaticBody3D
		if body == null:
			continue
		for child in body.get_children():
			var cs := child as CollisionShape3D
			if cs == null or cs.shape == null:
				continue
			var slab := _bridge_slab_from_shape(cs)
			if slab.is_empty():
				continue
			_bridge_slabs.append(slab)
			_bridge_rects.append((slab["rect"] as Rect2).grow(0.25))
		# 过桥站立靠板顶采样；物理盒留给点选/护栏挡路，不能拆。
		body.collision_layer = 2
		body.collision_mask = 0
		if body.is_in_group("terrain_navigation_input"):
			body.remove_from_group("terrain_navigation_input")
		for child in body.get_children():
			var shape := child as CollisionShape3D
			if shape != null:
				shape.disabled = false
	_restore_bridge_rail_collision(map_node)
	print(
		"G4PERF terrain_block bridges=",
		_bridge_rects.size(),
		" slabs=",
		_bridge_slabs.size(),
		" walk_physics=on"
	)


func _restore_bridge_rail_collision(map_node: Node) -> void:
	for node in map_node.find_children("RailC*", "StaticBody3D", true, false):
		var body := node as StaticBody3D
		if body == null:
			continue
		body.collision_layer = 1
		body.collision_mask = 0
		for child in body.get_children():
			var shape := child as CollisionShape3D
			if shape != null:
				shape.disabled = false


func _bridge_slab_from_shape(cs: CollisionShape3D) -> Dictionary:
	var box := cs.shape as BoxShape3D
	if box == null:
		return {}
	var xf := cs.global_transform
	var hx := box.size.x * 0.5
	var hy := box.size.y * 0.5
	var hz := box.size.z * 0.5
	var min_x := 1.0e9
	var max_x := -1.0e9
	var min_z := 1.0e9
	var max_z := -1.0e9
	var deck_y := -1.0e9
	for sx in [-1.0, 1.0]:
		for sy in [-1.0, 1.0]:
			for sz in [-1.0, 1.0]:
				var world: Vector3 = xf * Vector3(sx * hx, sy * hy, sz * hz)
				min_x = minf(min_x, world.x)
				max_x = maxf(max_x, world.x)
				min_z = minf(min_z, world.z)
				max_z = maxf(max_z, world.z)
				deck_y = maxf(deck_y, world.y)
	if max_x <= min_x or max_z <= min_z:
		return {}
	return {
		"rect": Rect2(min_x, min_z, max_x - min_x, max_z - min_z),
		"deck_y": deck_y,
	}


func _sample_bridge_deck(x: float, z: float) -> float:
	var point := Vector2(x, z)
	var best := -1.0e9
	for slab in _bridge_slabs:
		var rect: Rect2 = slab["rect"]
		if rect.grow(0.15).has_point(point):
			best = maxf(best, float(slab["deck_y"]))
	return best


func snap_to_bridge_if_near(point: Vector3, max_dist: float = 7.0) -> Vector3:
	var pulled := _pull_onto_nearby_slab(point, max_dist)
	if _sample_bridge_deck(pulled.x, pulled.z) > -1.0e8:
		return pulled
	return point


func _pull_onto_nearby_slab(point: Vector3, max_dist: float) -> Vector3:
	var best_d := max_dist
	var best := Vector3.INF
	for slab in _bridge_slabs:
		var rect: Rect2 = slab["rect"]
		var clamped := Vector2(
			clampf(point.x, rect.position.x, rect.end.x),
			clampf(point.z, rect.position.y, rect.end.y)
		)
		var d := Vector2(point.x, point.z).distance_to(clamped)
		if d < best_d:
			best_d = d
			best = Vector3(clamped.x, float(slab["deck_y"]), clamped.y)
	if best.x < 1.0e8:
		return best
	return point


func _collision_xz_rect(cs: CollisionShape3D) -> Rect2:
	var slab := _bridge_slab_from_shape(cs)
	if slab.is_empty():
		return Rect2()
	return (slab["rect"] as Rect2).grow(0.25)


func is_water_blocked(world: Vector3) -> bool:
	return is_ground_blocked(world)


## 大图没有 navmesh：台地顶/平地可造，水面和陡崖不可造。
func is_surface_buildable(world: Vector3) -> bool:
	if _on_bridge(world.x, world.z):
		return true
	var height := sample_height(world.x, world.z)
	if height < 0.2:
		return false
	var hx := sample_height(world.x + 2.0, world.z)
	var hz := sample_height(world.x, world.z + 2.0)
	# 2m 内高差 0.8m ≈ 22°，挡掉 12m/8m 坡道，留下台地顶和平地。
	return maxf(absf(hx - height), absf(hz - height)) <= 0.8


func is_ground_blocked(world: Vector3) -> bool:
	if _structure_blocks_world(world):
		return true
	if not _water_ready:
		return false
	if _on_bridge(world.x, world.z):
		return false
	if _sample_water(world.x, world.z):
		return true
	# 掩码判可走即可走，**不再用地表高度二次否决**。高度判据在建掩码时就已并入
	# （文件掩码自带岸距/岩类；高度场回退自带 `<0.15` 与陡坡；`_stamp_steep_cliffs` /
	# `_stamp_submerged_cells` 还会补盖）。而桥面 stamped 区下方就是河床，高度场必然
	# < 0.15 —— 旧实现在这里把已 stamped 可走的桥面格重新判禁行，单位能走上桥却卡在
	# 桥缘几厘米处，整局过不去（2026-09-21 过桥实测根因）。
	return false


## 是否落在「已 stamped 为可走」的桥面矩形内（与 `_stamp_bridges_walkable` 同一份数据）。
func _within_stamped_bridge(x: float, z: float) -> bool:
	if _bridge_rects.is_empty():
		return false
	var point := Vector2(x, z)
	for rect in _bridge_rects:
		if (rect as Rect2).has_point(point):
			return true
	return false


func set_structure_blocker(blocker_id: int, world: Vector3, radius: float) -> void:
	_structure_blockers[int(blocker_id)] = {"pos": world, "radius": radius}
	_rebuild_structure_solids()


func clear_structure_blocker(blocker_id: int) -> void:
	if not _structure_blockers.erase(int(blocker_id)):
		return
	_rebuild_structure_solids()


func _structure_stamp_radius(radius: float) -> float:
	return maxf(radius * STRUCTURE_STAMP_RADIUS_SCALE, STRUCTURE_STAMP_RADIUS_MIN)


func _structure_blocks_world(world: Vector3) -> bool:
	# 迈步/脱位必须用圆形足迹。粗格只给 A*：2m 格会把禁行区伸出到楼外，
	# 回城/出兵落点正好踩在格边上，走入→瞬移→再走入。
	for data in _structure_blockers.values():
		var pos: Vector3 = data["pos"]
		var r := _structure_stamp_radius(float(data["radius"]))
		var dx := world.x - pos.x
		var dz := world.z - pos.z
		if dx * dx + dz * dz <= r * r:
			return true
	return false


func _rebuild_structure_solids() -> void:
	var previous: Array = _structure_cell_ref.keys()
	_structure_cell_ref.clear()
	if _path_grid != null:
		for cell in previous:
			var c: Vector2i = cell
			if _path_grid.is_in_boundsv(c):
				_path_grid.set_point_solid(c, _coarse_blocked(c.x, c.y))
		for blocker_id in _structure_blockers:
			var data: Dictionary = _structure_blockers[blocker_id]
			_stamp_one_structure(data["pos"], float(data["radius"]))
	_path_cache.clear()


func _stamp_one_structure(world: Vector3, radius: float) -> void:
	if _path_grid == null or _path_w < 1:
		return
	var stamp_r := _structure_stamp_radius(radius)
	var r2 := stamp_r * stamp_r
	var min_c := _world_to_path_cell(world.x - stamp_r, world.z - stamp_r)
	var max_c := _world_to_path_cell(world.x + stamp_r, world.z + stamp_r)
	var cz := min_c.y
	while cz <= max_c.y:
		var cx := min_c.x
		while cx <= max_c.x:
			var cell := Vector2i(cx, cz)
			var px := (float(cx) + 0.5) * _path_cell
			var pz := (float(cz) + 0.5) * _path_cell
			var dx := px - world.x
			var dz := pz - world.z
			if dx * dx + dz * dz <= r2:
				_structure_cell_ref[cell] = int(_structure_cell_ref.get(cell, 0)) + 1
				if _path_grid.is_in_boundsv(cell):
					_path_grid.set_point_solid(cell, true)
			cx += 1
		cz += 1


func _stamp_bridges_walkable() -> void:
	if _bridge_rects.is_empty() or _water_w < 2 or _water_h < 2:
		return
	var span := maxf(_water_span, 1.0)
	for rect in _bridge_rects:
		var x0 := clampi(int(floor(rect.position.x / span * float(_water_w - 1))), 0, _water_w - 1)
		var z0 := clampi(int(floor(rect.position.y / span * float(_water_h - 1))), 0, _water_h - 1)
		var x1 := clampi(int(ceil(rect.end.x / span * float(_water_w - 1))), 0, _water_w - 1)
		var z1 := clampi(int(ceil(rect.end.y / span * float(_water_h - 1))), 0, _water_h - 1)
		var z := z0
		while z <= z1:
			var x := x0
			var row := z * _water_w
			while x <= x1:
				_water_bits[row + x] = 0
				x += 1
			z += 1


## 世界坐标处的地表高度（把 Map/Terrain 缩放与位移算进去）。
## `sample_height` 吃的是本节点局部 XZ；出生点/单位给的是 global_position，
## 直接拿去采样会在 scale≠1 时把单位放到错误高度（悬空或埋地）。
func sample_world_height(world: Vector3) -> float:
	var local := to_local(world)
	var h := sample_height(local.x, local.z)
	return to_global(Vector3(local.x, h, local.z)).y


func sample_height(x: float, z: float) -> float:
	if _height_w < 2 or _height_h < 2 or _height_samples.is_empty():
		return 0.0
	var u := clampf(x / _water_span, 0.0, 1.0) * float(_height_w - 1)
	var v := clampf(z / _water_span, 0.0, 1.0) * float(_height_h - 1)
	var x0 := clampi(int(floor(u)), 0, _height_w - 1)
	var z0 := clampi(int(floor(v)), 0, _height_h - 1)
	var x1 := mini(x0 + 1, _height_w - 1)
	var z1 := mini(z0 + 1, _height_h - 1)
	var tx := u - float(x0)
	var tz := v - float(z0)
	var h00 := _height_samples[z0 * _height_w + x0]
	var h10 := _height_samples[z0 * _height_w + x1]
	var h01 := _height_samples[z1 * _height_w + x0]
	var h11 := _height_samples[z1 * _height_w + x1]
	return lerpf(lerpf(h00, h10, tx), lerpf(h01, h11, tx), tz)


func project_ground(point: Vector3) -> Vector3:
	var deck := _sample_bridge_deck(point.x, point.z)
	if deck > -1.0e8:
		point.y = deck
		return point
	point.y = sample_world_height(point)
	return point


## 沿视线求与高度场的交点。先打 Y=0 再抬高度会在 45° 镜头下偏出整座台地的水平距离。
func intersect_ground_ray(origin: Vector3, dir: Vector3) -> Vector3:
	if dir.length_squared() < 0.000001:
		return project_ground(origin)
	dir = dir.normalized()
	var t_lo := 0.0
	var t_hi := 240.0
	if absf(dir.y) > 0.0001:
		var t_low_y := (60.0 - origin.y) / dir.y
		var t_high_y := (-4.0 - origin.y) / dir.y
		t_lo = maxf(0.0, minf(t_low_y, t_high_y))
		t_hi = maxf(t_lo + 1.0, maxf(t_low_y, t_high_y))
	for _i in 20:
		var t := (t_lo + t_hi) * 0.5
		var probe := origin + dir * t
		var surface_h := sample_height(probe.x, probe.z)
		var deck := _sample_bridge_deck(probe.x, probe.z)
		if deck > surface_h:
			surface_h = deck
		if probe.y > surface_h:
			t_lo = t
		else:
			t_hi = t
	return project_ground(origin + dir * ((t_lo + t_hi) * 0.5))


func clamp_ground_move(from: Vector3, to: Vector3) -> Vector3:
	if not _water_ready:
		return to
	if not is_ground_blocked(to) and not _segment_hits_blocked(from, to):
		return to
	return _last_land_along(from, to)


func clamp_ground_step(from: Vector3, to: Vector3) -> Vector3:
	if not _water_ready:
		return to
	if is_ground_blocked(to):
		return from
	if _on_bridge(to.x, to.z) or _on_bridge(from.x, from.z):
		return to
	var from_h := sample_height(from.x, from.z)
	var to_h := sample_height(to.x, to.z)
	if absf(to_h - from_h) > MAX_GROUND_STEP_M:
		return from
	return to


func _on_bridge(x: float, z: float) -> bool:
	return _sample_bridge_deck(x, z) > -1.0e8


func _sample_water(x: float, z: float) -> bool:
	if _water_w < 2 or _water_h < 2:
		return false
	var u := clampf(x / _water_span, 0.0, 1.0)
	var v := clampf(z / _water_span, 0.0, 1.0)
	var ix := clampi(int(round(u * float(_water_w - 1))), 0, _water_w - 1)
	var iz := clampi(int(round(v * float(_water_h - 1))), 0, _water_h - 1)
	return _water_bits[iz * _water_w + ix] != 0


func _segment_hits_water(from: Vector3, to: Vector3) -> bool:
	var dx := to.x - from.x
	var dz := to.z - from.z
	var length := sqrt(dx * dx + dz * dz)
	if length < 0.25:
		return is_water_blocked(to)
	var steps := maxi(1, int(ceil(length)))
	for s in range(1, steps + 1):
		var t := float(s) / float(steps)
		if is_water_blocked(from.lerp(to, t)):
			return true
	return false


func _segment_hits_blocked(from: Vector3, to: Vector3) -> bool:
	var dx := to.x - from.x
	var dz := to.z - from.z
	var length := sqrt(dx * dx + dz * dz)
	if length < 0.25:
		return is_ground_blocked(to)
	var steps := maxi(1, int(ceil(length)))
	for s in range(1, steps + 1):
		var t := float(s) / float(steps)
		if is_ground_blocked(from.lerp(to, t)):
			return true
	return false


func _last_land_along(from: Vector3, to: Vector3) -> Vector3:
	if is_ground_blocked(from):
		return _nearest_land(from)
	var dx := to.x - from.x
	var dz := to.z - from.z
	var length := sqrt(dx * dx + dz * dz)
	if length < 0.25:
		return from
	var steps := maxi(1, int(ceil(length * 2.0)))
	var last := from
	for s in range(1, steps + 1):
		var t := float(s) / float(steps)
		var sample: Vector3 = from.lerp(to, t)
		if is_ground_blocked(sample):
			return last
		last = sample
	return last


func clamp_ground_destination(to: Vector3) -> Vector3:
	if not _water_ready:
		return to
	if not is_ground_blocked(to):
		return project_ground(to)
	return unstick_ground(to, 0)


func unstick_ground(origin: Vector3, salt: int = 0) -> Vector3:
	var land := _nearest_land(origin)
	if salt == 0:
		return land
	var ang := float(salt % 8) * TAU / 8.0
	var probe := land + Vector3(cos(ang), 0.0, sin(ang)) * 0.85
	if not is_ground_blocked(probe):
		return project_ground(probe)
	return land


func find_ground_path(from: Vector3, to: Vector3) -> PackedVector3Array:
	var empty := PackedVector3Array()
	if not _water_ready or _path_grid == null:
		return empty
	var start_pos := unstick_ground(from, 0)
	var end_pos := clamp_ground_destination(to)
	var start_cell := _nearest_open_path_cell(_world_to_path_cell(start_pos.x, start_pos.z))
	var end_cell := _nearest_open_path_cell(_world_to_path_cell(end_pos.x, end_pos.z))
	if start_cell.x < 0 or end_cell.x < 0:
		return empty
	if start_cell == end_cell:
		var direct := PackedVector3Array()
		direct.append(end_pos)
		return direct
	var cache_key := _path_cache_key(start_cell, end_cell)
	if _path_cache.has(cache_key):
		return _with_final_destination(_path_cache[cache_key], end_pos)
	var ids: Array = _path_grid.get_id_path(start_cell, end_cell, true)
	if ids.is_empty():
		return empty
	var points := PackedVector3Array()
	for id in ids:
		points.append(_snap_path_point(_path_cell_to_world(id)))
	# A* 含起点格。第一航点若是格心，单位会先折回去再出发。
	if points.size() > 1:
		points.remove_at(0)
	points = _simplify_ground_path(points)
	points = _with_final_destination(points, end_pos)
	if _path_cache.size() >= PATH_CACHE_MAX:
		_path_cache.clear()
	_path_cache[cache_key] = points
	return points


func ground_path_cell_meters() -> float:
	return _path_cell


func _nearest_land(origin: Vector3) -> Vector3:
	if not _water_ready:
		return origin
	if not is_ground_blocked(origin):
		return project_ground(origin)
	var start := _world_to_fine(origin.x, origin.z)
	var visited := PackedByteArray()
	visited.resize(_water_w * _water_h)
	var q := PackedInt32Array()
	q.append(start.x)
	q.append(start.y)
	visited[start.y * _water_w + start.x] = 1
	var head := 0
	var dirs: Array[int] = [1, 0, -1, 0, 0, 1, 0, -1, 1, 1, 1, -1, -1, 1, -1, -1]
	while head + 1 < q.size():
		var cx := q[head]
		var cz := q[head + 1]
		head += 2
		if _water_bits[cz * _water_w + cx] == 0:
			var candidate := _fine_to_world(cx, cz)
			if not _structure_blocks_world(candidate):
				return candidate
		var d := 0
		while d < dirs.size():
			var nx := cx + dirs[d]
			var nz := cz + dirs[d + 1]
			d += 2
			if nx < 0 or nz < 0 or nx >= _water_w or nz >= _water_h:
				continue
			if absi(nx - start.x) + absi(nz - start.y) > 80:
				continue
			var idx := nz * _water_w + nx
			if visited[idx] != 0:
				continue
			visited[idx] = 1
			q.append(nx)
			q.append(nz)
	return origin


func _stamp_submerged_cells() -> int:
	if _water_w < 2 or _water_h < 2:
		return 0
	var added := 0
	var iz := 0
	while iz < _water_h:
		var ix := 0
		while ix < _water_w:
			var idx := iz * _water_w + ix
			if _water_bits[idx] == 0:
				var world := _fine_to_world(ix, iz)
				if not _on_bridge(world.x, world.z) and world.y < 0.15:
					_water_bits[idx] = 1
					added += 1
			ix += 1
		iz += 1
	return added


func _snap_path_point(point: Vector3) -> Vector3:
	var pulled := _pull_onto_nearby_slab(point, 8.0)
	if _sample_bridge_deck(pulled.x, pulled.z) > -1.0e8:
		return pulled
	if not is_ground_blocked(point):
		return project_ground(point)
	return _nearest_land(point)


func _stamp_steep_cliffs() -> int:
	if _water_w < 2 or _water_h < 2 or _height_samples.is_empty():
		return 0
	var added := 0
	var iz := 0
	while iz < _water_h:
		var ix := 0
		while ix < _water_w:
			var idx := iz * _water_w + ix
			if _water_bits[idx] == 0:
				var h := _sample_height_cell(ix, iz)
				if (
					(ix > 0 and absf(_sample_height_cell(ix - 1, iz) - h) > MAX_GROUND_STEP_M)
					or (ix + 1 < _water_w and absf(_sample_height_cell(ix + 1, iz) - h) > MAX_GROUND_STEP_M)
					or (iz > 0 and absf(_sample_height_cell(ix, iz - 1) - h) > MAX_GROUND_STEP_M)
					or (iz + 1 < _water_h and absf(_sample_height_cell(ix, iz + 1) - h) > MAX_GROUND_STEP_M)
				):
					_water_bits[idx] = 1
					added += 1
			ix += 1
		iz += 1
	return added


func _sample_height_cell(ix: int, iz: int) -> float:
	var world := _fine_to_world(ix, iz)
	return sample_height(world.x, world.z)


func _world_to_fine(x: float, z: float) -> Vector2i:
	var u := clampf(x / maxf(_water_span, 1.0), 0.0, 1.0)
	var v := clampf(z / maxf(_water_span, 1.0), 0.0, 1.0)
	return Vector2i(
		clampi(int(round(u * float(maxi(_water_w - 1, 1)))), 0, maxi(_water_w - 1, 0)),
		clampi(int(round(v * float(maxi(_water_h - 1, 1)))), 0, maxi(_water_h - 1, 0))
	)


func _fine_to_world(ix: int, iz: int) -> Vector3:
	var x := float(ix) / float(maxi(_water_w - 1, 1)) * _water_span
	var z := float(iz) / float(maxi(_water_h - 1, 1)) * _water_span
	return project_ground(Vector3(x, 0.0, z))


func _build_path_grid() -> void:
	_path_cache.clear()
	if not _water_ready or _water_w < 2 or _water_h < 2:
		_path_grid = null
		return
	_path_scale = 4 if maxi(_water_w, _water_h) >= 400 else 2
	_path_w = int(ceil(float(_water_w) / float(_path_scale)))
	_path_h = int(ceil(float(_water_h) / float(_path_scale)))
	_path_cell = _water_span / float(maxi(_path_w, 1))
	_path_grid = AStarGrid2D.new()
	_path_grid.region = Rect2i(0, 0, _path_w, _path_h)
	_path_grid.cell_size = Vector2(_path_cell, _path_cell)
	_path_grid.offset = Vector2.ZERO
	_path_grid.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES
	_path_grid.default_compute_heuristic = AStarGrid2D.HEURISTIC_EUCLIDEAN
	_path_grid.default_estimate_heuristic = AStarGrid2D.HEURISTIC_EUCLIDEAN
	_path_grid.update()
	var solid := 0
	var cz := 0
	while cz < _path_h:
		var cx := 0
		while cx < _path_w:
			var blocked := _coarse_blocked(cx, cz)
			_path_grid.set_point_solid(Vector2i(cx, cz), blocked)
			if blocked:
				solid += 1
			cx += 1
		cz += 1
	print(
		"G4PERF ground_path grid=",
		_path_w,
		"x",
		_path_h,
		" cell=",
		snappedf(_path_cell, 0.01),
		" solid=",
		solid
	)
	_rebuild_structure_solids()


func _coarse_blocked(cx: int, cz: int) -> bool:
	var walkable := 0
	var total := 0
	var hmin := 1.0e9
	var hmax := -1.0e9
	var z0 := cz * _path_scale
	var x0 := cx * _path_scale
	var dz := 0
	while dz < _path_scale:
		var dx := 0
		while dx < _path_scale:
			var fx := mini(x0 + dx, _water_w - 1)
			var fz := mini(z0 + dz, _water_h - 1)
			total += 1
			if _water_bits[fz * _water_w + fx] == 0:
				walkable += 1
				var h := _sample_height_cell(fx, fz)
				hmin = minf(hmin, h)
				hmax = maxf(hmax, h)
			dx += 1
		dz += 1
	if _coarse_overlaps_bridge(cx, cz):
		return walkable < 1
	if walkable < PATH_COARSE_MIN_WALKABLE or walkable * 4 < total * 3:
		return true
	return hmax - hmin > MAX_GROUND_STEP_M


func _coarse_overlaps_bridge(cx: int, cz: int) -> bool:
	var cell := Rect2(
		float(cx) * _path_cell,
		float(cz) * _path_cell,
		_path_cell,
		_path_cell
	)
	for rect in _bridge_rects:
		if rect.intersects(cell):
			return true
	return false


func _world_to_path_cell(x: float, z: float) -> Vector2i:
	return Vector2i(
		clampi(int(floor(x / maxf(_path_cell, 0.01))), 0, maxi(_path_w - 1, 0)),
		clampi(int(floor(z / maxf(_path_cell, 0.01))), 0, maxi(_path_h - 1, 0))
	)


func _path_cell_to_world(cell: Vector2i) -> Vector3:
	var x0 := cell.x * _path_scale
	var z0 := cell.y * _path_scale
	var mid_x := x0 + _path_scale / 2
	var mid_z := z0 + _path_scale / 2
	var best_fx := -1
	var best_fz := -1
	var best_d := 1.0e9
	var dz := 0
	while dz < _path_scale:
		var dx := 0
		while dx < _path_scale:
			var fx := mini(x0 + dx, _water_w - 1)
			var fz := mini(z0 + dz, _water_h - 1)
			if _water_bits[fz * _water_w + fx] == 0:
				var d := float(absi(fx - mid_x) + absi(fz - mid_z))
				if d < best_d:
					best_d = d
					best_fx = fx
					best_fz = fz
			dx += 1
		dz += 1
	if best_fx >= 0:
		return _fine_to_world(best_fx, best_fz)
	var x := (float(cell.x) + 0.5) * _path_cell
	var z := (float(cell.y) + 0.5) * _path_cell
	return project_ground(Vector3(x, 0.0, z))


func _nearest_open_path_cell(cell: Vector2i) -> Vector2i:
	if _path_grid == null:
		return Vector2i(-1, -1)
	var start := Vector2i(
		clampi(cell.x, 0, maxi(_path_w - 1, 0)),
		clampi(cell.y, 0, maxi(_path_h - 1, 0))
	)
	if _path_grid.is_in_boundsv(start) and not _path_grid.is_point_solid(start):
		return start
	var q: Array[Vector2i] = [start]
	var seen := {start: true}
	var head := 0
	var dirs: Array[Vector2i] = [
		Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1),
		Vector2i(1, 1), Vector2i(1, -1), Vector2i(-1, 1), Vector2i(-1, -1)
	]
	while head < q.size() and head < 256:
		var cur: Vector2i = q[head]
		head += 1
		for d in dirs:
			var nxt: Vector2i = cur + d
			if seen.has(nxt) or not _path_grid.is_in_boundsv(nxt):
				continue
			seen[nxt] = true
			if not _path_grid.is_point_solid(nxt):
				return nxt
			q.append(nxt)
	return Vector2i(-1, -1)


func _path_cache_key(a: Vector2i, b: Vector2i) -> int:
	return a.x | (a.y << 8) | (b.x << 16) | (b.y << 24)


func _with_final_destination(points: PackedVector3Array, dest: Vector3) -> PackedVector3Array:
	var out := PackedVector3Array()
	for point in points:
		if out.is_empty() or _planar_len(out[out.size() - 1], point) > 0.35:
			out.append(point)
	if out.is_empty() or _planar_len(out[out.size() - 1], dest) > 0.35:
		out.append(dest)
	return out


func _simplify_ground_path(points: PackedVector3Array) -> PackedVector3Array:
	if points.size() <= 2:
		return points
	var out := PackedVector3Array()
	var i := 0
	out.append(points[0])
	while i < points.size() - 1:
		var j := points.size() - 1
		while j > i + 1 and _segment_hits_blocked(points[i], points[j]):
			j -= 1
		out.append(points[j])
		i = j
	return out


func _planar_len(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x, a.z).distance_to(Vector2(b.x, b.z))


func _is_g4_runtime_map(map_node: Node) -> bool:
	# 有高度场的生成图一律走格子禁行，不再建 3D 地形碰撞。
	if not height_data_path.is_empty():
		return true
	var map_size: Variant = map_node.get("size")
	if map_size is Vector2 and (map_size.x >= 256.0 or map_size.y >= 256.0):
		return true
	var scene_path := String(map_node.scene_file_path)
	return scene_path.contains("/generated/")


func _apply_g4_decoration_budget(map_node: Node) -> Dictionary:
	# Meshes in generated G4 maps are authored as many small FBX instances.
	# Keep strategic landmarks visible, but let the renderer cull distant
	# scenery and disable per-mesh shadows. Visibility ranges are world-space,
	# so this remains effective even when the map root is scaled.
	const DECOR_END := 280.0
	const DECOR_MARGIN := 40.0
	var culled := 0
	var shadow_off := 0
	var strategic_meshes := 0
	for node in map_node.find_children("*", "GeometryInstance3D", true, false):
		var geo := node as GeometryInstance3D
		if geo == null:
			continue
		var path := String(geo.get_path())
		var strategic := _is_strategic_visual_path(path)
		if strategic:
			strategic_meshes += 1
			continue
		# Do not touch the generated terrain surface itself.
		if geo == self or path.contains("/Geometry/Terrain"):
			continue
		geo.visibility_range_end = DECOR_END
		geo.visibility_range_end_margin = DECOR_MARGIN
		geo.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_DISABLED
		culled += 1
	# 作者碰撞已在 _purge_large_map_authoring_nodes 里 free，这里只报剩余数量。
	var collision := map_node.get_node_or_null("Collision")
	var collision_left := collision.get_child_count() if collision != null else 0
	return {"culled": culled, "shadow_off": shadow_off, "collision_disabled": collision_left,
		"strategic": strategic_meshes}


func _strip_leftover_map_physics(map_node: Node) -> int:
	var stripped := 0
	for node in map_node.find_children("*", "StaticBody3D", true, false):
		var body := node as StaticBody3D
		if body == null:
			continue
		var path := String(body.get_path())
		if path.contains("/Resources/") or body.is_in_group("resource_units") or body.is_in_group("units"):
			continue
		if _is_bridge_physics_body(body):
			continue
		body.collision_layer = 0
		body.collision_mask = 0
		if body.is_in_group("terrain_navigation_input"):
			body.remove_from_group("terrain_navigation_input")
		for child in body.get_children():
			var shape := child as CollisionShape3D
			if shape != null and shape.shape != null:
				shape.disabled = true
				shape.shape = null
				stripped += 1
	for node in map_node.find_children("*", "NavigationObstacle3D", true, false):
		var obstacle := node as NavigationObstacle3D
		if obstacle == null:
			continue
		obstacle.avoidance_enabled = false
		obstacle.affect_navigation_mesh = false
		obstacle.set_physics_process(false)
		obstacle.set_physics_process_internal(false)
		obstacle.set_navigation_map(RID())
		stripped += 1
	return stripped


func _is_bridge_physics_body(body: Node) -> bool:
	var node_name := String(body.name)
	if node_name.begins_with("WalkB") or node_name.begins_with("RailC"):
		return true
	return String(body.get_path()).contains("/Bridge")


func _is_strategic_visual_path(path: String) -> bool:
	# Preserve gameplay landmarks and readable navigation cues. Resource and
	# spawn visuals are intentionally exempt from distance culling.
	for token in ["/Resources/", "/SpawnPoints/", "/Bridge", "/Base", "/Objective", "/Road", "/WaterBody/"]:
		if path.contains(token):
			return true
	return false


func _is_legacy_ground_body(node_name: String) -> bool:
	var suffix := ""
	if node_name.begins_with("Solid"):
		suffix = node_name.trim_prefix("Solid")
	elif node_name.begins_with("Walk"):
		suffix = node_name.trim_prefix("Walk")
	return not suffix.is_empty() and suffix.is_valid_int()


## One-shot diagnostics for generated (G4) maps.  This intentionally runs after
## all map setup changes so the numbers describe the *actual* runtime tree.  It
## is cheap (one recursive walk) and never runs every frame.
func _print_g4_runtime_diagnostics() -> void:
	var map_node := get_parent().get_parent() if get_parent() != null else null
	if map_node == null or not _is_g4_runtime_map(map_node):
		return
	var counts := _collect_g4_runtime_counts(map_node)
	var nav_regions := map_node.find_children("*", "NavigationRegion3D", true, false).size()
	# Runtime terrain collider is a sibling on Match, not the visual Map/Terrain.
	var match_root: Node = map_node.get_parent()
	var terrain_body: Node = match_root.get_node_or_null("Terrain") if match_root != null else null
	var terrain_shape: CollisionShape3D = null
	if terrain_body != null:
		terrain_shape = terrain_body.find_child("CollisionShape3D", true, false) as CollisionShape3D
	var terrain_collision_enabled := terrain_shape != null and terrain_shape.shape != null
	var terrain_vertices := 0
	var terrain_triangles := 0
	if mesh is ArrayMesh and mesh.get_surface_count() > 0:
		var arrays: Array = mesh.surface_get_arrays(0)
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		terrain_vertices = vertices.size()
		terrain_triangles = int(indices.size() / 3) if not indices.is_empty() else 0
	print(
		"G4PERF diag map=", map_node.name,
		" backend=", RenderingServer.get_video_adapter_name(),
		" world_scale=", world_scale,
		" terrain_vertices=", terrain_vertices,
		" terrain_triangles=", terrain_triangles,
		" nodes=", counts["nodes"],
		" meshes=", counts["meshes"],
		" lights=", counts["lights"],
		" static_bodies=", counts["static_bodies"],
		" collision_shapes=", counts["collision_shapes"],
		" nav_regions=", nav_regions,
		" terrain_collision=", terrain_collision_enabled,
		" nav_bake_expected=false"
	)
	if nav_regions > 2:
		push_warning("G4PERF: generated map has more than the expected Air/Terrain navigation regions")
	if terrain_collision_enabled:
		push_warning("G4PERF: runtime terrain collision is still enabled on a large generated map")


func _collect_g4_runtime_counts(root: Node) -> Dictionary:
	var counts := {
		"nodes": 0,
		"meshes": 0,
		"lights": 0,
		"static_bodies": 0,
		"collision_shapes": 0,
	}
	var todo: Array[Node] = [root]
	while not todo.is_empty():
		var node: Node = todo.pop_back()
		counts["nodes"] = int(counts["nodes"]) + 1
		if node is MeshInstance3D:
			counts["meshes"] = int(counts["meshes"]) + 1
		if node is Light3D:
			counts["lights"] = int(counts["lights"]) + 1
		if node is StaticBody3D:
			counts["static_bodies"] = int(counts["static_bodies"]) + 1
		if node is CollisionShape3D:
			counts["collision_shapes"] = int(counts["collision_shapes"]) + 1
		for child in node.get_children():
			todo.append(child)
	return counts


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
	# 大地图水面片已经全部隐藏，不必再给 200+ 个材质各绑一张掩码。
	if _is_g4_runtime_map(map_node):
		return
	var path: String = height_data_path.get_base_dir() + "/terrain_masks.png"
	var img := _load_image_from_res(path)
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
	# 对局与 review 共用 showcase_land。卡的是碰撞/导航/雾视口，不是这套材质。
	var shared: Shader = load("res://source/match/maps/generated/showcase_land.gdshader") as Shader
	assert(shared != null, "shared terrain shader (showcase_land.gdshader) missing")
	var mat := ShaderMaterial.new()
	mat.shader = shared
	var pbr := "res://assets/terrain_pbr/"
	for pair in [
		["sand_tex", "dense_sand_diff.jpg"], ["sand_normal", "dense_sand_normal.jpg"],
		["detail_tex", "sand_01_diff.jpg"], ["top_tex", "moon_dusted_03_diff.jpg"],
		["cliff_tex", "cliff_side_diff.jpg"], ["cliff_normal", "cliff_side_normal.jpg"],
		["rock_tex", "dark_rock_02_diff.jpg"], ["rock_normal", "dark_rock_02_normal.jpg"],
		["detail2_tex", "gray_rocks_diff.jpg"], ["bank_tex", "brown_mud_02_diff.jpg"],
		["shore_tex", "damp_beach_sand_02_diff.jpg"], ["ramp_tex", "dirt_aerial_02_diff.jpg"],
		["macro_sand_tex", "image25_macro_sand.png"], ["macro_gravel_tex", "image25_macro_gravel.png"],
		["macro_rock_tex", "image25_macro_rock.png"], ["macro_wet_shore_tex", "image25_macro_wet_shore.png"],
		["macro_albedo", "image25_macro_sand.png"],
	]:
		var tex: Texture2D = load(pbr + pair[1]) as Texture2D
		if tex != null:
			mat.set_shader_parameter(pair[0], tex)
	var mask_res := height_data_path.get_base_dir() + "/terrain_masks.png"
	var mask_img := _load_image_from_res(mask_res)
	if mask_img != null:
		mat.set_shader_parameter("mask_tex", ImageTexture.create_from_image(mask_img))
		mat.set_shader_parameter("mask_from_tex", 1.0)
		mat.set_shader_parameter("mask_world_size", _terrain_span() * world_scale)
	# 256 图 world_scale=1：着色器里的 p 必须是世界米。以前除以 3.90625
	# 会把 8m 高地当成 31m 台顶，镜头距离也被放大，近景直接走远景宏贴图。
	mat.set_shader_parameter("showcase_world_scale", world_scale)
	mat.set_shader_parameter("use_masks", 1.0)
	mat.set_shader_parameter("performance_mode", false)
	# 大湖对局：16m 太碎、200m 太糊，折中 64 世界米一张。
	mat.set_shader_parameter("ground_tile_meters", 64.0)
	# 对局不要把 1800m 卫星宏图盖到山体上。沙/岩走 PBR 平铺。
	mat.set_shader_parameter("use_macro_albedo", false)
	mat.set_shader_parameter("macro_strength", 0.0)
	mat.set_shader_parameter("ground_height", 0.6)
	mat.set_shader_parameter("top_height", 8.1)
	mat.set_shader_parameter("normal_strength", 0.22)
	mat.set_shader_parameter("cut_water", false)
	mat.set_shader_parameter("debug_masks", 0.0)
	mat.set_shader_parameter("main_run", 0.0)
	mat.set_shader_parameter("main_width", 0.0)
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	extra_cull_margin = 0.0
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


## 摘掉旧版"台阶盒板"对导航/物理的参与（2026-09-14 用户截图"单位浮空"的根因修复）。
##
## 本节点的高度场网格已是本图**唯一**地面（`Match._setup_subsystems_dependent_on_map` 用它的
## trimesh 建碰撞、挂 `terrain_navigation_input`），但地图文件里仍留着旧版生成器输出的
## `Collision/Solid*/Walk*` 台阶盒板（4×4m 方盒、高 1m），它们**同样**带该组 → 导航烘焙按组收集时
## 两套面一起进、取较高面：单位站在盒板平顶上、玩家看到的是盒板下方的真地形 → 洼地/坡下悬空
##（实测：盒顶比块内地形最低点高 p50 +0.62m / p90 +2.46m / max +11.79m）。旧地图（seed_*.tscn）
## 地面**就是**这些盒板，所以从无此现象。单位 `collision_mask = 0`，物理不依赖盒板，故摘组+清层安全。
func _strip_legacy_ground_plates() -> void:
	var geometry := get_parent()
	var map_node: Node = geometry.get_parent() if geometry != null else null
	if map_node == null:
		return
	var collision: Node = map_node.get_node_or_null("Collision")
	if collision == null:
		return
	var stripped := strip_legacy_ground_collision(collision)
	if stripped > 0:
		print("TERRAIN: stripped legacy ground plates=", stripped)


## 把遗留台阶盒板从导航输入里摘掉并清空碰撞层，返回处理数量。
## 独立成静态函数：守门测试（tests/automated/TerrainGroundCollisionSmokeTest.gd）用最小节点树
## 验证"只摘 Solid*/Walk*、桥/水面等其它静态碰撞不动"，无需加载整张地图。
static func strip_legacy_ground_collision(collision: Node) -> int:
	#: 与 Constants.Match.Navigation.DOMAIN_TO_GROUP_MAPPING[Domain.TERRAIN] 同值；
	#: static 函数访问不到 autoload，故用字面量并在此注明来源。
	const NAV_GROUP := "terrain_navigation_input"
	var stripped := 0
	for child in collision.get_children():
		var body := child as StaticBody3D
		if body == null:
			continue
		var node_name := String(body.name)
		var suffix := ""
		if node_name.begins_with("Solid"):
			suffix = node_name.trim_prefix("Solid")
		elif node_name.begins_with("Walk"):
			suffix = node_name.trim_prefix("Walk")
		else:
			continue
		# 只认"纯数字后缀"（Solid12 / Walk3）：避免误伤将来可能出现的同类命名。
		if not suffix.is_valid_int():
			continue
		if body.is_in_group(NAV_GROUP):
			body.remove_from_group(NAV_GROUP)
		body.collision_layer = 0
		stripped += 1
	return stripped


func _load_mask_uvs(w: int, h: int) -> Array:
	var uvs := PackedVector2Array()
	var uv2s := PackedVector2Array()
	uvs.resize(w * h)
	uv2s.resize(w * h)
	if height_data_path.is_empty():
		return [uvs, uv2s]
	var path: String = height_data_path.get_base_dir() + "/terrain_masks.png"
	var img := _load_image_from_res(path)
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
	var data_path := _absolute_data_path(height_data_path)
	var f := FileAccess.open(data_path, FileAccess.READ)
	if f == null:
		push_error("GeneratedTerrain: 无法读取高度数据 %s（resolved=%s）" % [height_data_path, data_path])
		return
	var w := f.get_32()
	var h := f.get_32()
	if w < 2 or h < 2 or w > 4097 or h > 4097:
		push_error("GeneratedTerrain: 高度数据尺寸非法 %dx%d" % [w, h])
		return
	var data := f.get_buffer((w * h) * 4)
	f.close()
	var source_heights := data.to_float32_array()
	# 顶点局部间距：height_data 是语义域的上采样（1025 = 512 格 ×2 + 1），顶点
	# 序号**不等于**语义坐标。此前直接按序号当局部坐标（0..1024），使得地形在
	# 世界里的跨度是 1024×world_scale=4096m，而出生点/水面/装饰/碰撞板都在
	# 2048m 内 —— 地形比其余几何大 2 倍，着色特征（河道/台地/崖壁）全部落在
	# 实际几何的 2 倍坐标处（2026-09-14 探针实测 4096m vs 2048m，游戏内与 review
	# 观感不一致的根因）。
	# 源场 1025² 才抽到 513²。256 图已经是 513²（约 0.5m 一格）；
	# 再用 >=513 的 stride=2 会变成 257²，坡面 1m 三角面在近景读成折纸。
	# 格子禁行不走这张网格，加顶点不进物理。
	var stride := 2 if maxi(w, h) >= 1025 else 1
	var rw := int(ceil(float(w - 1) / float(stride))) + 1
	var rh := int(ceil(float(h - 1) / float(stride))) + 1
	var heights := PackedFloat32Array()
	heights.resize(rw * rh)
	for j in range(rh):
		var sj := mini(j * stride, h - 1)
		for i in range(rw):
			var si := mini(i * stride, w - 1)
			heights[j * rw + i] = source_heights[sj * w + si]
	_water_span = _terrain_span()
	var xz_step := _water_span / float(maxi(rw - 1, 1))
	var verts := PackedVector3Array()
	verts.resize(rw * rh)
	var idx := 0
	for j in range(rh):
		for i in range(rw):
			verts[idx] = Vector3(float(i) * xz_step, heights[idx], float(j) * xz_step)
			idx += 1
	var normals := _compute_normals(heights, rw, rh, xz_step)
	var indices := PackedInt32Array()
	indices.resize((rw - 1) * (rh - 1) * 6)
	var k := 0
	for j in range(rh - 1):
		for i in range(rw - 1):
			var v00 := j * rw + i
			indices[k] = v00
			indices[k + 1] = v00 + rw
			indices[k + 2] = v00 + 1
			indices[k + 3] = v00 + 1
			indices[k + 4] = v00 + rw
			indices[k + 5] = v00 + rw + 1
			k += 6
	# 共享 shader 的着色掩码：从 terrain_masks.png 采样写入 UV/UV2
	# （与 review 渲染器同机制：UV=(plateau_d, shore_d) 米，UV2=(lake_d, cls)）
	var masks := _load_mask_uvs(rw, rh)
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
	_height_samples = heights
	_height_w = rw
	_height_h = rh
	var hmin := 1.0e9
	var hmax := -1.0e9
	for height in heights:
		hmin = minf(hmin, height)
		hmax = maxf(hmax, height)
	print(
		"G4PERF terrain_built path=", data_path,
		" source=", w, "x", h,
		" render=", rw, "x", rh,
		" height=[", snappedf(hmin, 0.01), ",", snappedf(hmax, 0.01), "]"
	)


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
