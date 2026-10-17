extends Node

## 地图材质掩码跨度合同回归（2026-10-12，P1）。
##
## 缺陷：GeneratedTerrain 的 `_world_span` 初值 256，而 `_enter_tree`/`_ready` 的
## `_apply_material()` 早于 `_build_water_occupancy()`（后者才读 `Map.size`）→ 512 图的
## `mask_world_size` 绑定 256。shader 用 `muv = worldXZ / mask_world_size` 且
## `repeat_disable`，于是掩码被压进半跨度：出生地直条色块、河道与桥/高度场错位。
##
## 本探针断言的是**实际 ShaderMaterial 参数**（不是内部 `_world_span`）：
## 入树后与 `_ready` 之后，材质跨度都必须等于地图世界跨度；并对河道/两岸/台地内外/
## 桥头/远端(x>256)样本核对 shader 掩码 UV 与逻辑占用格取到同一格。
## 覆盖：四个大厅图 + 当前最新随机图 + 运行时构造的合法 256 夹具 + 非生成图对照。

const LOBBY_MAPS := [
	"res://source/match/maps/PlainAndSimple.tscn",
	"res://source/match/maps/generated/47-903520021-767a002977/map_47-903520021-767a002977.tscn",
	"res://source/match/maps/generated/36-1846106761-767a002977/map_36-1846106761-767a002977.tscn",
	"res://source/match/maps/generated/8-561215132-767a002977/map_8-561215132-767a002977.tscn",
]
const NEWEST_RANDOM_MAP := \
	"res://source/match/maps/generated/61-727778310-7544ea830a/map_61-727778310-7544ea830a.tscn"
const CONTROL_MAP := "res://source/match/maps/BigArena.tscn"
const TERRAIN_SCRIPT := preload("res://source/match/maps/generated/GeneratedTerrain.gd")

## 夹具：只需要一个带 `size` 的 Map 祖先（G4 判定先看 height_data_path，再看 size）。
class MapLike extends Node3D:
	var size := Vector2(256.0, 256.0)


var failures: Array[String] = []
var cases: Array[Dictionary] = []
## `_pick_samples` 上一轮在掩码里实际发现的地貌类别（供契约断言"存在即采样"）。
var last_categories: Array[String] = []
var output := OS.get_environment("AIRTS_TERRAIN_SPAN_OUT")


func _ready() -> void:
	# 本地形夹具不得安装会扫描用户会话的 UI。
	var adjutant := get_node_or_null("/root/AdjutantButton")
	if adjutant != null:
		var install_callback := Callable(adjutant, "_on_node_added")
		if get_tree().node_added.is_connected(install_callback):
			get_tree().node_added.disconnect(install_callback)
	print("TERRAIN-MASK-SPAN-CONTRACT BEGIN pid=", OS.get_process_id())
	for path in LOBBY_MAPS:
		await _run_scene_case(path)
	await _run_scene_case(NEWEST_RANDOM_MAP)
	await _run_fixture_256_case()
	await _run_scene_case(CONTROL_MAP)
	_report()
	await get_tree().process_frame
	get_tree().quit(1 if not failures.is_empty() else 0)


## 期望跨度：G4 生成图取 Map.size；非生成图走语义默认值（256）。
func _expected_span(map_node: Node, terrain: Node) -> float:
	var map_size: Variant = map_node.get("size")
	if map_size is Vector2 and map_size.x > 1.0 and terrain.get("height_data_path") != "":
		return maxf(map_size.x, map_size.y)
	return float(terrain.get("_world_span"))


func _run_scene_case(path: String) -> void:
	var label := path.get_file()
	if not ResourceLoader.exists(path):
		failures.append("%s: 场景不存在 %s" % [label, path])
		return
	var map_node := (load(path) as PackedScene).instantiate()
	add_child(map_node)
	var terrain := map_node.get_node_or_null("Geometry/Terrain")
	var record := {"map": path, "label": label, "has_terrain": terrain != null}
	if terrain == null:
		# 对照图（如 BigArena）没有 GeneratedTerrain：只要求不崩、不产生跨度断言。
		print("SKIP %s: no Geometry/Terrain" % label)
		cases.append(record)
		map_node.queue_free()
		await get_tree().process_frame
		await get_tree().process_frame
		return
	await get_tree().process_frame
	await get_tree().process_frame
	_check_case(label, map_node, terrain, record)
	cases.append(record)
	map_node.queue_free()
	await get_tree().process_frame
	await get_tree().process_frame


func _check_case(label: String, map_node: Node, terrain: Node, record: Dictionary) -> void:
	var material := terrain.get("material_override") as ShaderMaterial
	var expected := _expected_span(map_node, terrain)
	var logic_span := float(terrain.get("_world_span"))
	var bindings: Array = terrain.get_meta("material_span_bindings", [])
	record["expected_span"] = expected
	record["logic_world_span"] = logic_span
	record["semantic_span"] = float(terrain.get("semantic_span"))
	record["bindings"] = bindings
	record["material_span_after_ready"] = (
		material.get_shader_parameter("mask_world_size") if material != null else null
	)
	if material == null:
		failures.append("%s: 地形没有 ShaderMaterial override" % label)
		return
	var after_ready: Variant = material.get_shader_parameter("mask_world_size")
	var first_binding: Variant = bindings[0] if not bindings.is_empty() else null
	record["material_span_first_binding"] = (
		(first_binding as Dictionary).get("span") if first_binding is Dictionary else null
	)
	if after_ready == null:
		# 非生成图（无 terrain_masks.png）本就不绑定掩码跨度，只核对逻辑跨度。
		failures.append("%s: 材质没有 mask_world_size（无掩码图，生成图不该出现）" % label)
	elif absf(float(after_ready) - expected) > 0.01:
		failures.append(
			(
				"%s: _ready 后材质跨度 %s != 地图跨度 %.2f"
				% [label, str(after_ready), expected]
			)
		)
	if bindings.is_empty():
		failures.append("%s: 没有材质绑定跨度记录（无法证明首帧）" % label)
	elif record.material_span_first_binding == null:
		failures.append("%s: 首次材质绑定记录缺 span 字段" % label)
	elif absf(float(record.material_span_first_binding) - expected) > 0.01:
		failures.append(
			(
				"%s: 首次材质绑定跨度 %s != 地图跨度 %.2f"
				% [label, str(record.material_span_first_binding), expected]
			)
		)
	if absf(logic_span - expected) > 0.01:
		failures.append("%s: 逻辑跨度 %.2f != 地图跨度 %.2f" % [label, logic_span, expected])
	print(
		(
			"PASS-SPAN %s expected=%.1f first=%s after_ready=%.1f logic=%.1f"
			% [
				label,
				expected,
				str(record.material_span_first_binding),
				float(record.material_span_after_ready),
				logic_span,
			]
		)
	)
	_check_mask_alignment(label, terrain, material, record)


## 掩码坐标一致性：shader UV（世界/材质跨度）与逻辑占用格（世界/_world_span）必须同格。
func _check_mask_alignment(
	label: String, terrain: Node, material: ShaderMaterial, record: Dictionary
) -> void:
	var mask_path: String = str(terrain.get("height_data_path")).get_base_dir() + "/terrain_masks.png"
	var abs_path := ProjectSettings.globalize_path(mask_path)
	if not FileAccess.file_exists(abs_path):
		print("SKIP-SAMPLES %s: 无 terrain_masks.png" % label)
		return
	var img := Image.load_from_file(abs_path)
	if img == null or img.is_empty():
		failures.append("%s: 掩码图读不出来 %s" % [label, abs_path])
		return
	img.convert(Image.FORMAT_RGBA8)
	var tex_w := img.get_width()
	var tex_h := img.get_height()
	var logic_w := int(terrain.get("_water_w"))
	var logic_h := int(terrain.get("_water_h"))
	if logic_w < 2 or logic_h < 2:
		print("SKIP-SAMPLES %s: 逻辑占用格未建立" % label)
		return
	var logic_bits: PackedByteArray = terrain.get("_water_bits")
	var mask_span := float(material.get_shader_parameter("mask_world_size"))
	var logic_span := float(terrain.get("_world_span"))
	var bridge_rects: Array = terrain.get("_bridge_rects")
	var samples := _pick_samples(img, terrain, tex_w, tex_h, bridge_rects)
	print("SAMPLE-KINDS %s %s" % [label, str(samples.map(func(s): return s.kind))])
	# 契约：掩码里**存在的**每个类别都必须被采样且坐标对齐；类别本身不存在的
	# （如 Plain & Simple 平地图没有河/台地）不硬凑样本。合成夹具同规则。
	var present_kinds: Dictionary = {}
	for sample in samples:
		present_kinds[sample.kind] = true
	for kind in last_categories:
		if not present_kinds.has(kind):
			failures.append("%s: 掩码存在类别 %s 但没有取到样本" % [label, kind])
	if samples.size() < 2:
		failures.append(
			"%s: 样本不足（%d），无法核对掩码对齐" % [label, samples.size()]
		)
		return
	var aligned := 0
	var cells_agree := 0
	var cells_checked := 0
	for sample in samples:
		var world: Vector3 = sample["world"]
		var kind: String = sample["kind"]
		var uv_shader := Vector2(world.x, world.z) / mask_span
		var uv_logic := Vector2(world.x, world.z) / logic_span
		if uv_shader.distance_to(uv_logic) > 0.0005:
			failures.append(
				(
					"%s/%s: shader UV %s 与逻辑 UV %s 不一致"
					% [label, kind, str(uv_shader), str(uv_logic)]
				)
			)
			continue
		aligned += 1
		var ix := clampi(int(round(uv_shader.x * float(tex_w - 1))), 0, tex_w - 1)
		var iz := clampi(int(round(uv_shader.y * float(tex_h - 1))), 0, tex_h - 1)
		var lx := clampi(int(round(uv_logic.x * float(logic_w - 1))), 0, logic_w - 1)
		var lz := clampi(int(round(uv_logic.y * float(logic_h - 1))), 0, logic_h - 1)
		if ix != lx or iz != lz:
			failures.append(
				(
					"%s/%s: shader 纹素 (%d,%d) 与逻辑格 (%d,%d) 不是同一格"
					% [label, kind, ix, iz, lx, lz]
				)
			)
			continue
		# 禁行契约是**单向**的：掩码判禁（水/岩）的格，逻辑必须禁；反过来不成立——
		# 逻辑侧还会按高度场二次盖章（_stamp_steep_cliffs/_stamp_submerged_cells），
		# 更严是设计意图。桥面 rect 内逻辑故意放行，按 stamp_sensitive 跳过。
		if sample.get("stamp_sensitive", false):
			continue
		var color := img.get_pixel(ix, iz)
		var shore_d := (color.g - 0.5) * 600.0
		var cls := color.a * 2.0 - 1.0
		if absf(shore_d + 0.4) < 1.0 or absf(cls - 0.35) < 0.1:
			continue
		var mask_blocked := shore_d < -0.4 or cls > 0.35
		var logic_blocked := logic_bits[lz * logic_w + lx] != 0
		cells_checked += 1
		if not mask_blocked:
			continue
		if logic_blocked:
			cells_agree += 1
		else:
			failures.append(
				(
					"%s/%s: 掩码判禁但逻辑放行 @(%d,%d)"
					% [label, kind, lx, lz]
				)
			)
	record["samples"] = samples.size()
	record["samples_aligned"] = aligned
	record["cells_checked"] = cells_checked
	record["cells_agree"] = cells_agree
	print(
		(
			"PASS-SAMPLES %s samples=%d aligned=%d cells %d/%d 一致"
			% [label, samples.size(), aligned, cells_agree, cells_checked]
		)
	)


## 河道 / 两岸 / 台地内外 / 桥头 / 远端(x>256 或 z>256)，全部按世界坐标取样。
func _pick_samples(
	img: Image, terrain: Node, tex_w: int, tex_h: int, bridge_rects: Array
) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var world_span := float(terrain.get("_world_span"))
	var seen := {}
	var water_cell := Vector2i(-1, -1)
	var bank_cells: Array[Vector2i] = []
	var plateau_in := Vector2i(-1, -1)
	var plateau_out := Vector2i(-1, -1)
	for iz in range(tex_h):
		for ix in range(tex_w):
			var color := img.get_pixel(ix, iz)
			var shore_d := (color.g - 0.5) * 600.0
			var cls := color.a * 2.0 - 1.0
			if water_cell.x < 0 and shore_d < -3.0:
				water_cell = Vector2i(ix, iz)
			if cls > 0.55 and plateau_in.x < 0:
				plateau_in = Vector2i(ix, iz)
			if cls < -0.3 and plateau_out.x < 0:
				plateau_out = Vector2i(ix, iz)
			if bank_cells.size() < 4 and shore_d > -0.5 and shore_d < 2.5:
				bank_cells.append(Vector2i(ix, iz))
		if water_cell.x >= 0 and plateau_in.x >= 0 and plateau_out.x >= 0:
			break
	var picked: Array = []
	if water_cell.x >= 0:
		picked.append({"cell": water_cell, "kind": "river", "stamp_sensitive": false})
	if plateau_in.x >= 0:
		picked.append({"cell": plateau_in, "kind": "plateau_in", "stamp_sensitive": false})
	if plateau_out.x >= 0:
		picked.append({"cell": plateau_out, "kind": "plateau_out", "stamp_sensitive": false})
	for cell in bank_cells:
		picked.append({"cell": cell, "kind": "bank", "stamp_sensitive": false})
	if not bridge_rects.is_empty():
		var rect: Rect2 = bridge_rects[0]
		picked.append(
			{
				"world": Vector3(rect.position.x, 0.0, rect.position.y),
				"kind": "bridge_head",
				"stamp_sensitive": true,
			}
		)
	# 桥面走廊内逻辑故意放行（_stamp_bridges_walkable），任何样本落入桥 rect 都按盖章敏感处理。
	for entry in picked:
		if entry.stamp_sensitive:
			continue
		var probe_world: Vector3 = entry.get("world", Vector3.ZERO)
		if entry.get("cell", Vector2i(-1, -1)).x >= 0:
			var cu := (float(entry.cell.x) + 0.5) / float(tex_w)
			var cv := (float(entry.cell.y) + 0.5) / float(tex_h)
			probe_world = Vector3(cu * world_span, 0.0, cv * world_span)
		for rect2 in bridge_rects:
			var grown := Rect2(rect2.position - Vector2(3.0, 3.0), rect2.size + Vector2(6.0, 6.0))
			if grown.has_point(Vector2(probe_world.x, probe_world.z)):
				entry.stamp_sensitive = true
				break
	# 远端样本：跨度 256 以上的象限（512 图才存在；256 图自动跳过）。
	if world_span > 300.0:
		picked.append(
			{"world": Vector3(world_span * 0.82, 0.0, world_span * 0.31), "kind": "far_x_gt_256",
				"stamp_sensitive": true}
		)
		picked.append(
			{"world": Vector3(world_span * 0.28, 0.0, world_span * 0.79), "kind": "far_z_gt_256",
				"stamp_sensitive": true}
		)
	for entry in picked:
		var cell: Vector2i = entry.get("cell", Vector2i(-1, -1))
		var world: Vector3 = entry.get("world", Vector3.ZERO)
		if cell.x >= 0:
			var u := (float(cell.x) + 0.5) / float(tex_w)
			var v := (float(cell.y) + 0.5) / float(tex_h)
			world = Vector3(u * world_span, 0.0, v * world_span)
		var key := "%s" % str(world.snapped(Vector3(0.5, 0.0, 0.5)))
		if seen.has(key):
			continue
		seen[key] = true
		out.append({"world": world, "kind": entry.kind, "stamp_sensitive": entry.stamp_sensitive})
	last_categories.clear()
	if water_cell.x >= 0:
		last_categories.append("river")
	if plateau_in.x >= 0:
		last_categories.append("plateau_in")
	if plateau_out.x >= 0:
		last_categories.append("plateau_out")
	if not bank_cells.is_empty():
		last_categories.append("bank")
	if not bridge_rects.is_empty():
		last_categories.append("bridge_head")
	if world_span > 300.0:
		last_categories.append_array(["far_x_gt_256", "far_z_gt_256"])
	return out


## 合法 256 夹具：运行时生成 33×33 高度场 + 128×128 掩码，写 user:// 后现场组装
## Map.size=256 / semantic_span=256 的节点链，验证 256 历史导出图不受本次改动影响。
func _run_fixture_256_case() -> void:
	var label := "fixture256"
	var dir := "user://terrain_span_fixture256"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	var grid := 33
	var file := FileAccess.open(dir + "/height_data.bin", FileAccess.WRITE)
	if file == null:
		failures.append("%s: 无法写夹具高度场" % label)
		return
	file.store_32(grid)
	file.store_32(grid)
	var heights := PackedFloat32Array()
	heights.resize(grid * grid)
	for j in grid:
		for i in grid:
			var u := float(i) / float(grid - 1)
			var v := float(j) / float(grid - 1)
			heights[j * grid + i] = 0.6 + 0.5 * sin(u * TAU) * cos(v * TAU)
	file.store_buffer(heights.to_byte_array())
	file.close()
	var img := Image.create(128, 128, false, Image.FORMAT_RGBA8)
	for j in 128:
		for i in 128:
			var u := float(i) / 127.0
			var v := float(j) / 127.0
			# 中间一条河（shore_d 为负）+ 紧邻两岸（shore_d≈1m）+ 远处干地。
			var shore_d := 30.0
			var dv := absf(v - 0.5)
			if dv < 0.02:
				shore_d = -6.0
			elif dv < 0.045:
				# 3.0m：RGBA8 量化（Godot 截断而非四舍五入）后回读约 +1.18m，
				# 稳定落在探针的"两岸"判据 (-0.5, 2.5) 内。
				shore_d = 3.0
			# 左上台地（cls>0，且在干地上）与右下斜坡（cls<0）。
			var cls := 0.0
			if u < 0.25 and v < 0.25:
				cls = 0.8
			elif u > 0.75 and v > 0.75:
				cls = -0.6
			img.set_pixel(i, j, Color(0.5, shore_d / 600.0 + 0.5, 0.5, (cls + 1.0) * 0.5))
	img.save_png(dir + "/terrain_masks.png")
	var map_node := MapLike.new()
	map_node.name = "Map"
	map_node.size = Vector2(256.0, 256.0)
	var geometry := Node3D.new()
	geometry.name = "Geometry"
	map_node.add_child(geometry)
	var terrain := TERRAIN_SCRIPT.new()
	terrain.name = "Terrain"
	terrain.height_data_path = dir + "/height_data.bin"
	terrain.semantic_span = 256.0
	terrain.world_scale = 1.0
	geometry.add_child(terrain)
	add_child(map_node)
	await get_tree().process_frame
	await get_tree().process_frame
	var record := {"map": "user://fixture256", "label": label, "has_terrain": true}
	_check_case(label, map_node, terrain, record)
	cases.append(record)
	map_node.queue_free()
	await get_tree().process_frame
	await get_tree().process_frame


func _report() -> void:
	if not output.is_empty():
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(output))
		var file := FileAccess.open(output.path_join("terrain_mask_span_contract.json"), FileAccess.WRITE)
		file.store_string(JSON.stringify({"cases": cases, "failures": failures}, "\t"))
		file.close()
	for failure in failures:
		print("CONTRACT-FAIL ", failure)
	print("TERRAIN-MASK-SPAN-CONTRACT cases=%d failures=%d" % [cases.size(), failures.size()])