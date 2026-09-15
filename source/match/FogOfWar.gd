extends Node3D

const DynamicCircle2D = preload("res://source/generic-scenes-and-nodes/2d/DynamicCircle2D.tscn")

const DEFAULT_SIZE = Vector2i(100, 100)

@export_range(1, 10) var texture_units_per_world_unit = 2  # px/m
@export var fog_circle_color = Color(0.25, 0.25, 0.25)
@export var shroud_circle_color = Color(1.0, 1.0, 1.0)

var _unit_to_circles_mapping = {}
## Updating every physics tick made large maps spend a surprising amount of CPU just
## moving 2D reveal circles. Visibility changes are not frame critical, so keep a small
## fixed cadence and reuse the same group query instead of running it at 60 Hz.
const SYNC_INTERVAL := 0.10
var _sync_elapsed := SYNC_INTERVAL
## Parent `visible = false` does not stop SubViewport UPDATE_ALWAYS. Large G4 maps
## keep the overlay hidden and freeze both fog render targets so they stop costing
## a full extra pass every frame.
var _runtime_enabled := true
var _fog_dirty := true
const DISABLED_VIEWPORT_SIZE := Vector2i(8, 8)

@onready var _revealer = find_child("Revealer")
@onready var _fog_viewport = find_child("FogViewport")
@onready var _fog_viewport_container = find_child("FogViewportContainer")
@onready var _combined_viewport = find_child("CombinedViewport")
@onready var _screen_overlay = find_child("ScreenOverlay")


func _ready():
	if not _runtime_enabled:
		set_runtime_enabled(false)
		if _revealer != null:
			_revealer.hide()
		var editor_circle := find_child("EditorOnlyCircle")
		if editor_circle != null:
			editor_circle.queue_free()
		return
	if _fog_viewport.size == DEFAULT_SIZE:
		resize(find_parent("Match").find_child("Map").size)
	_screen_overlay.material_override.set_shader_parameter(
		"texture_units_per_world_unit", texture_units_per_world_unit
	)
	_revealer.hide()
	find_child("EditorOnlyCircle").queue_free()
	_fog_dirty = true


func _physics_process(delta):
	if not _runtime_enabled:
		return
	var t0 := Time.get_ticks_usec()
	_sync_elapsed += delta
	if _sync_elapsed < SYNC_INTERVAL:
		return
	_sync_elapsed = fmod(_sync_elapsed, SYNC_INTERVAL)
	_sync_revealed_circles()
	if Engine.get_physics_frames() % 40 == 0:
		print("G4PERF fog_sync_us=", Time.get_ticks_usec() - t0)


func refresh_now() -> void:
	if not _runtime_enabled:
		return
	_sync_revealed_circles()
	_paint_fog_viewports()
	_notify_minimap_fog()


func _sync_revealed_circles() -> void:
	var units_synced = {}
	var units_to_sync = get_tree().get_nodes_in_group("revealed_units")
	for unit in units_to_sync:
		if not unit.is_revealing():
			continue
		units_synced[unit] = 1
		if not _unit_is_mapped(unit):
			_map_unit_to_new_circles(unit)
		_sync_circles_to_unit(unit)
	for mapped_unit in _unit_to_circles_mapping.keys():
		if not mapped_unit in units_synced:
			_cleanup_mapping(mapped_unit)
	_fog_dirty = true


func _process(_delta):
	if not _runtime_enabled or not _fog_dirty:
		return
	_fog_dirty = false
	_paint_fog_viewports()


func is_runtime_enabled() -> bool:
	return _runtime_enabled


func set_runtime_enabled(enabled: bool) -> void:
	_runtime_enabled = enabled
	visible = enabled
	set_physics_process(enabled)
	set_process(enabled)
	if _screen_overlay != null:
		_screen_overlay.visible = enabled
	if not enabled:
		if _fog_viewport != null:
			_fog_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
			_fog_viewport.size = DISABLED_VIEWPORT_SIZE
		if _combined_viewport != null:
			_combined_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
			_combined_viewport.size = DISABLED_VIEWPORT_SIZE
	else:
		_paint_fog_viewports()
		_notify_minimap_fog()
	print(
		"G4PERF fog_runtime enabled=",
		enabled,
		" fog_update=",
		_fog_viewport.render_target_update_mode if _fog_viewport != null else -1,
		" combined_update=",
		_combined_viewport.render_target_update_mode if _combined_viewport != null else -1
	)


func reveal():
	_revealer.show()


func resize(map_size: Vector2):
	if not _runtime_enabled:
		if _fog_viewport != null:
			_fog_viewport.size = DISABLED_VIEWPORT_SIZE
		if _combined_viewport != null:
			_combined_viewport.size = DISABLED_VIEWPORT_SIZE
		return
	# 2048m 图 × 2px/m = 4096² 会让 simple_fog_of_war 对 UV 外像素 ALPHA=1（整屏黑）。
	# 256+ 生成图封顶 512²，密度回写到 texture_units_per_world_unit。
	var max_edge := 512.0 if maxf(map_size.x, map_size.y) >= 256.0 else 1024.0
	var px_x := map_size.x * float(texture_units_per_world_unit)
	var px_y := map_size.y * float(texture_units_per_world_unit)
	var longest := maxf(px_x, px_y)
	if longest > max_edge:
		texture_units_per_world_unit = maxi(
			1, int(round(float(texture_units_per_world_unit) * max_edge / longest))
		)
	var new_size := Vector2i(
		maxi(1, int(round(map_size.x * float(texture_units_per_world_unit)))),
		maxi(1, int(round(map_size.y * float(texture_units_per_world_unit))))
	)
	if _fog_viewport != null:
		_fog_viewport.size = new_size
	if _combined_viewport != null:
		_combined_viewport.size = new_size
	if _screen_overlay != null and _screen_overlay.material_override != null:
		_screen_overlay.material_override.set_shader_parameter(
			"texture_units_per_world_unit", texture_units_per_world_unit
		)
		if _combined_viewport != null:
			_screen_overlay.material_override.set_shader_parameter(
				"world_visibility_texture", _combined_viewport.get_texture()
			)
	_paint_fog_viewports()
	_notify_minimap_fog()
	print(
		"G4PERF fog_resize ",
		new_size.x,
		"x",
		new_size.y,
		" px_per_m=",
		texture_units_per_world_unit
	)


func _paint_fog_viewports() -> void:
	if not _runtime_enabled:
		return
	# 512² 2D 视口用 ALWAYS：UPDATE_ONCE 在小地图采样时经常还是全黑，
	# 遮罩把预览盖死，玩家看成“没有小地图”。
	if _fog_viewport != null:
		_fog_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	if _combined_viewport != null:
		_combined_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS


func _notify_minimap_fog() -> void:
	var match_node := find_parent("Match")
	if match_node == null:
		return
	var minimap := match_node.find_child("Minimap", true, false)
	if minimap != null and minimap.has_method("_sync_minimap_fog_mask"):
		minimap.call_deferred("_sync_minimap_fog_mask")


func _unit_is_mapped(unit):
	return unit in _unit_to_circles_mapping


func _map_unit_to_new_circles(unit):
	var shroud_circle = DynamicCircle2D.instantiate()
	shroud_circle.color = fog_circle_color
	shroud_circle.radius = unit.sight_range * texture_units_per_world_unit
	_fog_viewport.add_child(shroud_circle)
	var fow_circle = DynamicCircle2D.instantiate()
	fow_circle.color = shroud_circle_color
	fow_circle.radius = unit.sight_range * texture_units_per_world_unit
	_fog_viewport_container.add_sibling(fow_circle)
	_unit_to_circles_mapping[unit] = [shroud_circle, fow_circle]


func _sync_circles_to_unit(unit):
	var unit_pos_3d = unit.global_transform.origin
	var unit_pos_2d = Vector2(unit_pos_3d.x, unit_pos_3d.z) * texture_units_per_world_unit
	_unit_to_circles_mapping[unit][0].position = unit_pos_2d
	_unit_to_circles_mapping[unit][1].position = unit_pos_2d


func _cleanup_mapping(unit):
	_unit_to_circles_mapping[unit][0].queue_free()
	_unit_to_circles_mapping[unit][1].queue_free()
	_unit_to_circles_mapping.erase(unit)
