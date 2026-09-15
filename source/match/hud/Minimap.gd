extends PanelContainer

const Unit = preload("res://source/match/units/Unit.gd")
const Moving = preload("res://source/match/units/actions/Moving.gd")

const GROUND_LEVEL_PLANE = Plane(Vector3.UP, 0)
const MINIMAP_PIXELS_PER_WORLD_METER = 2
## Native minimap textures larger than the HUD are pure overhead (the viewport is
## 2D-only, yet a 4096² texture still has to be composited every frame). Keep a
## bounded texture and derive the world scale from its actual size.
const MAX_MINIMAP_VIEWPORT_EDGE := 512.0
const MINIMAP_UI_SIZE = Vector2(176, 176)  # 仅作旧 HUD 左下角回退；侧栏槽已是正方形并铺满
const CAMERA_INDICATOR_COLOR = Color(0.35, 0.93, 1.0, 0.95)
const CAMERA_FOOTPRINT_COLOR = Color(0.35, 0.93, 1.0, 0.10)

## ---- 副官指令标记（2026-09-10）----
## 主画面信标可能落在相机视野外（副官常在探索地图边缘），小地图上同时给出
## 目标点标记 + 受令单位到目标的连线，保证"副官在指挥哪里"始终可见。
const CommandVisualizerScript = preload("res://source/match/hud/CommandVisualizer.gd")
## 2026-09-14 用户反馈"信标轨迹留太久、太明显"：小地图标记同步收紧
##（8s→3s、7px→5px、连线更细更淡），与主画面信标（2.4s）节奏一致。
const ORDER_MARK_LIFETIME := 3.0
const ORDER_MARK_SIZE := Vector2(5, 5)
const ORDER_LINE_WIDTH := 1.4

var _unit_to_corresponding_node_mapping = {}
var _camera_movement_active = false
var _camera_footprint: Polygon2D
var _map_size := Vector2.ZERO
var _minimap_pixels_per_world_meter := float(MINIMAP_PIXELS_PER_WORLD_METER)
var _order_marks: Array = []
const UNIT_SYNC_INTERVAL := 0.10
var _unit_sync_elapsed := UNIT_SYNC_INTERVAL
var _cached_unit_nodes: Array = []
var _unit_by_name: Dictionary = {}
var _static_preview_applied := false
var _hud_overlay: Control = null

@onready var _match = find_parent("Match")
@onready var _camera_indicator = find_child("CameraIndicator") as Line2D
@onready var _viewport_background = find_child("Background")
@onready var _texture_rect = find_child("MinimapTextureRect")


func _ready():
	if not FeatureFlags.show_minimap:
		queue_free()
		return
	_remove_dummy_nodes()
	_configure_fixed_minimap_layout()
	_configure_camera_indicator()
	# 大地图先铺 G2 预览底图；迷雾遮罩等 Match 就绪后再跟主画面同步。
	if _is_large_map_now():
		_show_static_preview_now()
	if _match != null:
		await _match.ready
	var map_node = _match.find_child("Map") if _match != null else null
	if map_node != null:
		_map_size = map_node.size
	if not _static_preview_applied and _is_large_map_now():
		_show_static_preview_now()
	_rebind_viewport_texture()
	if _static_preview_applied:
		print("[G4PERF] minimap preview=static size=%s scale=%.3f" % [
			str(_map_size), _minimap_pixels_per_world_meter
		])
	else:
		var longest := maxf(_map_size.x, _map_size.y)
		if longest * _minimap_pixels_per_world_meter > MAX_MINIMAP_VIEWPORT_EDGE:
			_minimap_pixels_per_world_meter = MAX_MINIMAP_VIEWPORT_EDGE / maxf(longest, 1.0)
		var minimap_viewport := _minimap_viewport()
		if minimap_viewport != null:
			minimap_viewport.size = Vector2i(
				maxi(1, int(round(_map_size.x * _minimap_pixels_per_world_meter))),
				maxi(1, int(round(_map_size.y * _minimap_pixels_per_world_meter)))
			)
			_add_fog_disabled_backdrop(minimap_viewport)
			_rebind_viewport_texture()
			print("[G4PERF] minimap viewport=%dx%d scale=%.3f" % [
				minimap_viewport.size.x, minimap_viewport.size.y, _minimap_pixels_per_world_meter
			])
		else:
			push_warning("[MINIMAP] MinimapViewport 丢失，只铺静态预览")
			_show_static_preview_now()
	if _texture_rect != null:
		_texture_rect.gui_input.connect(_on_gui_input)
	MatchSignals.order_visualized.connect(_on_order_visualized)
	_sync_minimap_fog_mask()
	call_deferred("_sync_minimap_fog_mask")
	var tree := get_tree()
	if tree != null:
		tree.create_timer(0.35).timeout.connect(_sync_minimap_fog_mask)
		tree.create_timer(1.2).timeout.connect(_sync_minimap_fog_mask)
	_update_camera_indicator()


func _is_large_map_now() -> bool:
	var map_node: Node = _match.get_node_or_null("Map") if _match != null else null
	if map_node == null:
		return false
	var map_size = map_node.get("size")
	return map_size is Vector2 and (map_size.x >= 256.0 or map_size.y >= 256.0)


func _hide_minimap_fog_mask() -> void:
	var fog_mask := find_child("FogOfWarMask", true, false) as Control
	if fog_mask != null:
		fog_mask.visible = false


func _ensure_hud_fog_mask() -> ColorRect:
	var fog_mask := find_child("FogOfWarMask", true, false) as ColorRect
	if fog_mask == null or _texture_rect == null:
		return fog_mask
	# 遮罩不能留在 MinimapViewport 里：子视口再采 CombinedViewport 在 Godot 4
	# 里经常拿到全黑纹理，预览图被盖死，玩家看成“没有小地图”。
	if fog_mask.get_parent() != _texture_rect:
		var old_parent := fog_mask.get_parent()
		if old_parent != null:
			old_parent.remove_child(fog_mask)
		_texture_rect.add_child(fog_mask)
		fog_mask.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		fog_mask.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return fog_mask


func _sync_minimap_fog_mask() -> void:
	var fog_mask := _ensure_hud_fog_mask()
	if fog_mask == null:
		return
	if not _minimap_fog_is_enabled():
		fog_mask.visible = false
		return
	var fog: Node = _match.get_node_or_null("FogOfWar") if _match != null else null
	var combined: SubViewport = (
		fog.get_node_or_null("CombinedViewport") as SubViewport if fog != null else null
	)
	if combined == null:
		fog_mask.visible = false
		return
	combined.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	var live_tex: Texture2D = combined.get_texture()
	var fog_ready := false
	if live_tex != null:
		var img: Image = live_tex.get_image()
		if img != null and not img.is_empty():
			var peak := 0
			var step := maxi(1, img.get_width() / 32)
			for y in range(0, img.get_height(), step):
				for x in range(0, img.get_width(), step):
					peak = maxi(peak, int(img.get_pixel(x, y).r * 255.0))
					if peak > 16:
						break
				if peak > 16:
					break
			if peak > 16:
				if fog_mask.material is ShaderMaterial:
					(fog_mask.material as ShaderMaterial).set_shader_parameter(
						"reference_texture", ImageTexture.create_from_image(img)
					)
				fog_ready = true
	# 开雾纹理还是全黑时宁可不盖遮罩，也不能把预览图盖成黑块。
	fog_mask.visible = fog_ready
	fog_mask.z_index = 90


func _generated_map_id(map_node: Node) -> String:
	if map_node == null:
		return ""
	var terrain := map_node.find_child("Terrain", true, false)
	if terrain != null:
		var source_path := str(terrain.get("height_data_path"))
		if source_path.contains("/generated/"):
			return source_path.get_base_dir().get_file()
	var scene_path := String(map_node.scene_file_path)
	if scene_path.contains("/generated/"):
		return scene_path.get_base_dir().get_file()
	return ""


func _minimap_viewport() -> SubViewport:
	return find_child("MinimapViewport", true, false) as SubViewport


func _rebind_viewport_texture() -> void:
	if _static_preview_applied:
		return
	var vp := _minimap_viewport()
	if vp == null or _texture_rect == null:
		return
	_texture_rect.texture = vp.get_texture()


func _show_static_preview_now() -> void:
	var map_node: Node = _match.get_node_or_null("Map") if _match != null else null
	if map_node != null:
		var map_size = map_node.get("size")
		if map_size is Vector2:
			_map_size = map_size
	var image := _load_minimap_preview(map_node)
	if image == null or image.is_empty():
		image = _load_colorized_terrain_mask(map_node)
	if image == null or image.is_empty() or _texture_rect == null:
		return
	if _map_size.x > 0.0:
		_minimap_pixels_per_world_meter = float(image.get_width()) / _map_size.x
	var preview_tex := ImageTexture.create_from_image(image)
	if _texture_rect != null:
		_texture_rect.texture = preview_tex
	var vp := _minimap_viewport()
	if vp != null:
		vp.size = Vector2i(image.get_width(), image.get_height())
		_add_backdrop_image(vp, image)
	_static_preview_applied = true
	print("[MINIMAP] static preview %dx%d" % [image.get_width(), image.get_height()])


func _freeze_live_minimap_viewport() -> void:
	var minimap_viewport := find_child("MinimapViewport") as SubViewport
	if minimap_viewport == null:
		return
	minimap_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	minimap_viewport.render_target_clear_mode = SubViewport.CLEAR_MODE_NEVER
	minimap_viewport.size = Vector2i(8, 8)
	minimap_viewport.process_mode = Node.PROCESS_MODE_DISABLED

## 对局是否开启战争迷雾（决定小地图保留迷雾遮罩，还是用静态底图兜底）。
## 判据取 Match 的实际状态、不按地图尺寸猜：Match 在 FULL 可见性与大地图两种
## 情况下会关闭迷雾（见 Match.gd::_ready / _apply_large_map_playable_presentation）。
func _minimap_fog_is_enabled() -> bool:
	var fog: Node = null
	if _match != null:
		fog = _match.find_child("FogOfWar", true, false)
	if fog == null:
		return true
	if not fog.visible:
		return false
	if fog.has_method("is_runtime_enabled"):
		return bool(fog.is_runtime_enabled())
	return true


## 迷雾被关闭的对局（大地图 / 全可见 Full）里小地图只剩灰底 + 单位点，
## 这里用大厅那张真实预览图兜底当底图（没有预览再退回 terrain_masks 上色）。
##
## ⚠ 必须按【迷雾的实际开关状态】判断，不能像早期版本那样无条件执行：
## 普通对局下无条件执行会隐藏 FogOfWarMask（战争迷雾消失）、并把底图换成
## 大厅预览大图（背景完全不对）——2026-09-15 用户实测报错，勿回退。
func _add_fog_disabled_backdrop(minimap_viewport: SubViewport) -> void:
	if _minimap_fog_is_enabled():
		return
	var fog_mask := find_child("FogOfWarMask", true, false) as Control
	if fog_mask != null:
		fog_mask.visible = false
	var map_node := _match.find_child("Map") if _match != null else null
	var image := _load_minimap_preview(map_node)
	if image == null:
		image = _load_colorized_terrain_mask(map_node)
	if image == null:
		print("[MINIMAP] no generated backdrop source map=", str(map_node))
		return
	print("[MINIMAP] generated backdrop loaded size=", image.get_width(), "x", image.get_height())
	_add_backdrop_image(minimap_viewport, image)


func _add_backdrop_image(minimap_viewport: SubViewport, image: Image) -> void:
	var old := minimap_viewport.get_node_or_null("GeneratedTerrainBackdrop")
	if old != null:
		old.queue_free()
	var backdrop := TextureRect.new()
	backdrop.name = "GeneratedTerrainBackdrop"
	backdrop.texture = ImageTexture.create_from_image(image)
	backdrop.position = Vector2.ZERO
	backdrop.size = Vector2(minimap_viewport.size)
	backdrop.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	backdrop.stretch_mode = TextureRect.STRETCH_SCALE
	backdrop.mouse_filter = Control.MOUSE_FILTER_IGNORE
	minimap_viewport.get_node("Background").add_sibling(backdrop)


func _load_minimap_preview(map_node: Node) -> Image:
	var map_id := _generated_map_id(map_node)
	var candidates: Array[String] = []
	if not map_id.is_empty():
		candidates.append("res://source/match/maps/generated/%s/minimap_preview.png" % map_id)
		candidates.append("res://assets/map_previews/map_%s.png" % map_id)
	if map_node != null:
		var slug := String(map_node.scene_file_path).get_file().get_basename()
		if not slug.is_empty():
			candidates.append("res://assets/map_previews/%s.png" % slug)
	for res_path in candidates:
		if ResourceLoader.exists(res_path):
			var tex = load(res_path)
			if tex is Texture2D:
				var from_res: Image = (tex as Texture2D).get_image()
				if from_res != null and not from_res.is_empty():
					return from_res
		var abs_path := ProjectSettings.globalize_path(res_path)
		if FileAccess.file_exists(abs_path):
			var from_disk := Image.load_from_file(abs_path)
			if from_disk != null and not from_disk.is_empty():
				return from_disk
	return null


func _load_colorized_terrain_mask(map_node: Node) -> Image:
	var terrain := map_node.find_child("Terrain", true, false) if map_node != null else null
	var source_path := str(terrain.get("height_data_path")) if terrain != null else ""
	var mask_path := ""
	if not source_path.is_empty():
		mask_path = source_path.get_base_dir() + "/terrain_masks.png"
	if (mask_path.is_empty() or not FileAccess.file_exists(mask_path)) and map_node != null:
		mask_path = String(map_node.scene_file_path).get_base_dir() + "/terrain_masks.png"
	if not FileAccess.file_exists(mask_path):
		var abs_mask := ProjectSettings.globalize_path(mask_path)
		if FileAccess.file_exists(abs_mask):
			mask_path = abs_mask
		else:
			return null
	var src := Image.load_from_file(mask_path)
	if src == null or src.is_empty():
		src = Image.load_from_file(ProjectSettings.globalize_path(mask_path))
	if src == null or src.is_empty():
		return null
	src.convert(Image.FORMAT_RGBA8)
	if src.get_width() > 256 or src.get_height() > 256:
		src.resize(256, 256, Image.INTERPOLATE_BILINEAR)
	var w := src.get_width()
	var h := src.get_height()
	var out := Image.create(w, h, false, Image.FORMAT_RGBA8)
	var land := Color(0.42, 0.55, 0.28, 1)
	var water := Color(0.14, 0.34, 0.52, 1)
	var bank := Color(0.62, 0.52, 0.32, 1)
	for y in range(h):
		for x in range(w):
			var px := src.get_pixel(x, y)
			var shore := (px.g - 0.5) * 600.0
			var lake := (px.b - 0.5) * 600.0
			var water_d := minf(shore, lake)
			if water_d < 2.0:
				out.set_pixel(x, y, water)
			elif water_d < 12.0:
				out.set_pixel(x, y, bank)
			else:
				out.set_pixel(x, y, land)
	return out


func _configure_fixed_minimap_layout():
	# ViewportTexture 默认会把 TextureRect 撑成渲染分辨率。忽略贴图固有尺寸，
	# 让小地图铺满正方形槽；地图本身也是正方形时 KEEP_ASPECT_CENTERED 刚好填满。
	_texture_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_texture_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_texture_rect.custom_minimum_size = Vector2.ZERO
	_texture_rect.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_texture_rect.size_flags_vertical = Control.SIZE_EXPAND_FILL
	custom_minimum_size = Vector2.ZERO
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	clip_contents = true
	var outer_container := get_parent() as Control
	if outer_container != null and outer_container.custom_minimum_size == Vector2.ZERO:
		outer_container.custom_minimum_size = MINIMAP_UI_SIZE


func _configure_camera_indicator():
	# Standard RTS minimap camera footprint: a translucent polygon plus a bright outline.
	_camera_indicator.default_color = CAMERA_INDICATOR_COLOR
	_camera_indicator.width = 2.0
	_camera_indicator.antialiased = true
	_camera_indicator.z_index = 101

	_camera_footprint = Polygon2D.new()
	_camera_footprint.name = "CameraFootprint"
	_camera_footprint.color = CAMERA_FOOTPRINT_COLOR
	_camera_footprint.z_index = 100
	_camera_indicator.get_parent().add_child(_camera_footprint)


func _process(_delta):
	# Camera movement itself is render-frame smooth, so the minimap footprint should follow it
	# every rendered frame instead of lagging behind on physics ticks.
	_update_camera_indicator()
	_process_order_marks()


func _physics_process(_delta):
	_unit_sync_elapsed += _delta
	if _unit_sync_elapsed < UNIT_SYNC_INTERVAL:
		return
	_unit_sync_elapsed = fmod(_unit_sync_elapsed, UNIT_SYNC_INTERVAL)
	_sync_real_units_with_minimap_representations()


func _remove_dummy_nodes():
	for dummy_node in find_children("EditorOnlyDummy*"):
		dummy_node.queue_free()


func _sync_real_units_with_minimap_representations():
	var units_synced = {}
	_cached_unit_nodes = get_tree().get_nodes_in_group("units") + get_tree().get_nodes_in_group("resource_units")
	_unit_by_name.clear()
	for cached_unit in _cached_unit_nodes:
		if is_instance_valid(cached_unit):
			_unit_by_name[str(cached_unit.name)] = cached_unit
	var units_to_sync = _cached_unit_nodes
	for unit in units_to_sync:
		if not unit.visible:
			continue
		units_synced[unit] = 1
		if not _unit_is_mapped(unit):
			_map_unit(unit)
		_sync_unit(unit)
	for mapped_unit in _unit_to_corresponding_node_mapping:
		if not mapped_unit in units_synced:
			_cleanup_mapping(mapped_unit)


func _unit_is_mapped(unit):
	return unit in _unit_to_corresponding_node_mapping


func _map_unit(unit):
	var node_representing_unit = ColorRect.new()
	node_representing_unit.size = Vector2(3, 3)
	if not unit is Unit:
		node_representing_unit.rotation_degrees = 45
	_viewport_background.add_sibling(node_representing_unit)
	node_representing_unit.pivot_offset = node_representing_unit.size / 2.0
	_unit_to_corresponding_node_mapping[unit] = node_representing_unit


func _sync_unit(unit):
	var unit_pos_3d = unit.global_transform.origin
	var unit_pos_2d = Vector2(unit_pos_3d.x, unit_pos_3d.z) * _minimap_pixels_per_world_meter
	_unit_to_corresponding_node_mapping[unit].position = unit_pos_2d
	var mapped_color := Color.WHITE
	if unit is Unit:
		var owner_player = unit.player
		if owner_player != null and "color" in owner_player:
			mapped_color = owner_player.color
	else:
		mapped_color = unit.color
	_unit_to_corresponding_node_mapping[unit].color = mapped_color


func _cleanup_mapping(unit):
	_unit_to_corresponding_node_mapping[unit].queue_free()
	_unit_to_corresponding_node_mapping.erase(unit)


func _update_camera_indicator():
	if _camera_indicator == null or _camera_footprint == null or _map_size == Vector2.ZERO:
		return
	var viewport := get_viewport()
	var camera := viewport.get_camera_3d()
	if camera == null:
		_camera_indicator.hide()
		_camera_footprint.hide()
		return

	var viewport_size := Vector2(viewport.size)
	var camera_corners := [
		Vector2.ZERO,
		Vector2(viewport_size.x, 0.0),
		viewport_size,
		Vector2(0.0, viewport_size.y),
	]
	var minimap_points := PackedVector2Array()
	for screen_corner in camera_corners:
		var intersection = GROUND_LEVEL_PLANE.intersects_ray(
			camera.project_ray_origin(screen_corner),
			camera.project_ray_normal(screen_corner)
		)
		if intersection == null:
			_camera_indicator.hide()
			_camera_footprint.hide()
			return

		# Keep the footprint readable when the camera reaches a map edge. The actual screen corner
		# may project outside the playable world, but the minimap should show the visible in-map part.
		var world_x := clampf(intersection.x, 0.0, _map_size.x)
		var world_z := clampf(intersection.z, 0.0, _map_size.y)
		minimap_points.append(
			Vector2(world_x, world_z) * _minimap_pixels_per_world_meter
		)

	_camera_footprint.polygon = minimap_points
	var outline_points := PackedVector2Array(minimap_points)
	outline_points.append(minimap_points[0])
	_camera_indicator.points = outline_points
	_camera_indicator.show()
	_camera_footprint.show()


func _texture_rect_position_to_world_position(position_2d_within_texture_rect):
	assert(
		_texture_rect.stretch_mode == _texture_rect.STRETCH_KEEP_ASPECT_CENTERED,
		"world 3d position retrieval algorithm assumes 'STRETCH_KEEP_ASPECT_CENTERED'"
	)
	var texture_rect_size = _texture_rect.size
	var texture_size = _texture_rect.texture.get_size()
	var proportions = texture_rect_size / texture_size
	var scaling_factor = proportions.x if proportions.x < proportions.y else proportions.y
	var scaled_texture_size = texture_size * scaling_factor
	var scaled_texture_position_within_texture_rect = (
		(texture_rect_size - scaled_texture_size) / 2.0
	)
	var rect_containing_scaled_texture = Rect2(
		scaled_texture_position_within_texture_rect, scaled_texture_size
	)
	if rect_containing_scaled_texture.has_point(position_2d_within_texture_rect):
		var position_2d_within_minimap = (
			(position_2d_within_texture_rect - rect_containing_scaled_texture.position)
			/ scaling_factor
		)
		return position_2d_within_minimap / _minimap_pixels_per_world_meter
	return null


func _try_teleporting_camera_based_on_local_texture_rect_position(position_2d_within_texture_rect):
	var world_position_2d = _texture_rect_position_to_world_position(
		position_2d_within_texture_rect
	)
	if world_position_2d == null:
		return
	var world_position_3d = Vector3(world_position_2d.x, 0, world_position_2d.y)
	get_viewport().get_camera_3d().set_position_safely(world_position_3d)


func _issue_movement_action(position_2d_within_texture_rect):
	var world_position_2d = _texture_rect_position_to_world_position(
		position_2d_within_texture_rect
	)
	if world_position_2d == null:
		return
	var abstract_world_position_3d = Vector3(world_position_2d.x, 0, world_position_2d.y)
	var camera = get_viewport().get_camera_3d()
	var target_point_on_colliding_surface = camera.get_ray_intersection(
		camera.unproject_position(abstract_world_position_3d)
	)
	if target_point_on_colliding_surface == null:
		return
	MatchSignals.terrain_targeted.emit(target_point_on_colliding_surface)


func _on_gui_input(event):
	if event is InputEventMouseButton:
		if event.is_pressed() and event.button_index == MOUSE_BUTTON_LEFT:
			_try_teleporting_camera_based_on_local_texture_rect_position(event.position)
			_camera_movement_active = true
		if not event.is_pressed() and event.button_index == MOUSE_BUTTON_LEFT:
			_camera_movement_active = false
		if event.is_pressed() and event.button_index == MOUSE_BUTTON_RIGHT:
			_issue_movement_action(event.position)
	elif event is InputEventMouseMotion and _camera_movement_active:
		_try_teleporting_camera_based_on_local_texture_rect_position(event.position)


## -------- 副官指令标记 --------

func _on_order_visualized(payload) -> void:
	if not (payload is Dictionary):
		return
	if str(payload.get("source", "player")) != "adjutant":
		return
	var raw = payload.get("target", [])
	if not (raw is Array) or raw.size() < 2:
		return
	var action := str(payload.get("action", "move"))
	var color: Color = CommandVisualizerScript.ACTION_COLORS.get(action, Color.WHITE)
	var target_2d := Vector2(float(raw[0]), float(raw[1])) * _minimap_pixels_per_world_meter
	var parent := _viewport_background.get_parent()
	if parent == null:
		return
	var marker := ColorRect.new()
	marker.name = "AdjutantOrderMark"
	marker.size = ORDER_MARK_SIZE
	marker.position = target_2d - ORDER_MARK_SIZE / 2.0
	marker.color = color
	marker.rotation_degrees = 45.0
	marker.z_index = 103
	parent.add_child(marker)
	var line := Line2D.new()
	line.name = "AdjutantOrderLine"
	line.width = ORDER_LINE_WIDTH
	line.default_color = Color(color.r, color.g, color.b, 0.5)
	line.z_index = 102
	parent.add_child(line)
	_order_marks.append({
		"marker": marker,
		"line": line,
		"target": target_2d,
		"units": payload.get("units", []),
		"color": color,
		"expire_at": Time.get_ticks_msec() / 1000.0 + ORDER_MARK_LIFETIME,
	})


func _process_order_marks() -> void:
	if _order_marks.is_empty():
		return
	var now := Time.get_ticks_msec() / 1000.0
	for index in range(_order_marks.size() - 1, -1, -1):
		var entry: Dictionary = _order_marks[index]
		var remain := float(entry["expire_at"]) - now
		if remain <= 0.0:
			(entry["marker"] as Node).queue_free()
			(entry["line"] as Node).queue_free()
			_order_marks.remove_at(index)
			continue
		var alpha := clampf(remain / 2.0, 0.0, 1.0)
		(entry["marker"] as CanvasItem).modulate = Color(1, 1, 1, alpha)
		(entry["line"] as CanvasItem).modulate = Color(1, 1, 1, alpha)
		# 连线起点跟随受令单位当前位置（单位在移动，固定起点会误导）。
		var from_2d := Vector2.ZERO
		var found := false
		for unit_name in entry["units"]:
			var unit = _unit_by_name.get(str(unit_name))
			if unit != null and is_instance_valid(unit):
				from_2d = Vector2(unit.global_position.x, unit.global_position.z) \
					* _minimap_pixels_per_world_meter
				found = true
				break
		var line := entry["line"] as Line2D
		line.points = PackedVector2Array([from_2d, entry["target"]]) if found \
			else PackedVector2Array()
