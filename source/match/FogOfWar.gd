extends Node3D

const DynamicCircle2D = preload("res://source/generic-scenes-and-nodes/2d/DynamicCircle2D.tscn")
const _PerfBuckets = preload("res://source/match/PerfBuckets.gd")

## 视野圈半径口径（2026-10-01 明确，两层语义不许混称）：
## ① 迷雾/探明圈 = **基础视野控制圈**：以单位中心为圆心、sight_range 为半径——
##    语义是"中心到地标的持续可见距离"（地图控制圈）。
## ② 单位可见性判定 = **表面到表面**：UnitVisibilityHandler 用 sight_range_against
##    （= sight_range + 观察者半径 + 目标半径）——目标是本体，探出其半径即被看见。
## 两者是同一"基础距离 + 半径"公式的控制圈特例与目标项，见 Unit.center_distance_limit_for。

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
## 已警告过"缺 sight_range"的单位种类（type_id|脚本名），避免逐帧刷屏。
var _missing_sight_range_warned := {}
const UnitScript = preload("res://source/match/units/Unit.gd")
const DISABLED_VIEWPORT_SIZE := Vector2i(8, 8)

## ── 已探明网格（2026-09-28，放置判据"已探明即可造"的数据源）──────────────
## 为什么要有：建筑放置的 C# `FullyVisible` 要求 footprint 圆心+16 圆周采样点
## "当前可见"。单位整体放大后（矿场 footprint 9.8m）采样环远超工人视野并集
## （5+2=7m），矿场全图无合法落点（2026-09-28 用户实报"不能建造"）。
## 放置端放宽为"可见 或 已探明"，本网格就是"已探明"的权威记录：
## 谁家的单位画出过迷雾圈，谁家的地就算探明过。
## 与 GPU 迷雾同源同拍（_sync_revealed_circles），所见即所得；按玩家分账，
## AI 自己的探索不会算到人类头上。格子 2m 一格，2048m 图也只占 ~1MB。
const EXPLORED_CELL_M := 2.0
## 与 C# SightCompensation 同口径：可见判定是 sight+2，探索累积必须用同一半径，
## 保证"现在可见 ⇒ 现在已探明"（放宽是单调的，旧行为可建的点新行为必可建）。
const EXPLORED_SIGHT_COMPENSATION_M := 2.0
var _explored_grids := {}  # player Node -> PackedByteArray（1=已探明）
var _explored_grid_size := Vector2i.ZERO

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
		# sight_range 为空 = 平衡目录未命中或 ConfigureUnit 还没跑到。
		# 旧行为是每帧抛 "Invalid operands 'Nil' and 'int'" 并中断本函数。
		# 现在按种类警告一次，用未配置兜底视野把圈画出来；目录稍后写入真实值时下一拍改半径。
		var sight_m := _resolved_sight_range_m(unit)
		# 已探明网格与迷雾圈同源同拍：这只单位此刻画出了迷雾圈，
		# 它主人的地盘就按同一半径记一笔"探明过"。
		_mark_explored(unit, sight_m)
		units_synced[unit] = 1
		if not _unit_is_mapped(unit):
			_map_unit_to_new_circles(unit, sight_m)
		else:
			_apply_circle_radius(unit, sight_m)
		_sync_circles_to_unit(unit)
	for mapped_unit in _unit_to_circles_mapping.keys():
		if not mapped_unit in units_synced:
			_cleanup_mapping(mapped_unit)
	_fog_dirty = true


## 每个"缺 sight_range 的单位种类"只警告一次（按 type_id + 脚本名归并），
## 既留下可定位的日志又不刷屏。根因修好后这里应当一条都不出。
func _warn_missing_sight_range(unit) -> void:
	var script: Script = unit.get_script()
	var key := "%s|%s" % [
		str(unit.get("unit_type_id")),
		script.resource_path.get_file() if script != null else "<no script>",
	]
	if _missing_sight_range_warned.has(key):
		return
	_missing_sight_range_warned[key] = true
	push_warning(
		"[FOG] 单位缺 sight_range（平衡目录未命中）type_id=%s 节点=%s，迷雾圈改用兜底视野 %.0fm"
		% [key, String(unit.name), UnitScript.UNCONFIGURED_SIGHT_RANGE_M]
	)


var _fog_hold_frames := 0


func _process(_delta):
	var t0 := 0
	if _PerfBuckets.enabled:
		t0 = Time.get_ticks_usec()
	if not _runtime_enabled:
		if t0 != 0:
			_PerfBuckets.add("fog_process", int(Time.get_ticks_usec() - t0))
		return
	# 迷雾圈同步是 0.1s 一拍。内容没变时继续 UPDATE_ALWAYS 会每帧重画同一张纹理。
	# 变脏后用 ALWAYS 画满两帧（避开 UPDATE_ONCE 首帧全黑），再停到下一拍。
	if not _fog_dirty:
		if _fog_hold_frames > 0:
			_fog_hold_frames -= 1
			if _fog_hold_frames == 0:
				_pause_fog_viewports()
		if t0 != 0:
			_PerfBuckets.add("fog_process", int(Time.get_ticks_usec() - t0))
		return
	_fog_dirty = false
	_paint_fog_viewports()
	_fog_hold_frames = 2
	if t0 != 0:
		_PerfBuckets.add("fog_process", int(Time.get_ticks_usec() - t0))


func _pause_fog_viewports() -> void:
	if _fog_viewport != null:
		_fog_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	if _combined_viewport != null:
		_combined_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED


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
	_reset_explored_grids(map_size)
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


func _resolved_sight_range_m(unit) -> float:
	var sight = unit.get("sight_range")
	if sight != null and (typeof(sight) == TYPE_FLOAT or typeof(sight) == TYPE_INT):
		return float(sight)
	_warn_missing_sight_range(unit)
	return UnitScript.UNCONFIGURED_SIGHT_RANGE_M


func _apply_circle_radius(unit, sight_m: float) -> void:
	var circles = _unit_to_circles_mapping[unit]
	var radius: float = sight_m * float(texture_units_per_world_unit)
	circles[0].radius = radius
	circles[1].radius = radius


func _map_unit_to_new_circles(unit, sight_m: float):
	var shroud_circle = DynamicCircle2D.instantiate()
	shroud_circle.color = fog_circle_color
	shroud_circle.radius = sight_m * texture_units_per_world_unit
	_fog_viewport.add_child(shroud_circle)
	var fow_circle = DynamicCircle2D.instantiate()
	fow_circle.color = shroud_circle_color
	fow_circle.radius = sight_m * texture_units_per_world_unit
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


func _reset_explored_grids(map_size: Vector2) -> void:
	_explored_grid_size = Vector2i(
		maxi(1, int(ceil(map_size.x / EXPLORED_CELL_M))),
		maxi(1, int(ceil(map_size.y / EXPLORED_CELL_M)))
	)
	_explored_grids.clear()


func _mark_explored(unit, sight_m: float) -> void:
	if _explored_grid_size == Vector2i.ZERO:
		return
	var player = unit.get_parent()
	var grid = _explored_grids.get(player)
	if grid == null:
		grid = PackedByteArray()
		grid.resize(_explored_grid_size.x * _explored_grid_size.y)
		grid.fill(0)
	var pos: Vector3 = unit.global_transform.origin
	var reach := sight_m + EXPLORED_SIGHT_COMPENSATION_M
	var min_cx := maxi(0, int(floor((pos.x - reach) / EXPLORED_CELL_M)))
	var min_cz := maxi(0, int(floor((pos.z - reach) / EXPLORED_CELL_M)))
	var max_cx := mini(_explored_grid_size.x - 1, int(ceil((pos.x + reach) / EXPLORED_CELL_M)))
	var max_cz := mini(_explored_grid_size.y - 1, int(ceil((pos.z + reach) / EXPLORED_CELL_M)))
	var reach_sq := reach * reach
	var marked := false
	for cz in range(min_cz, max_cz + 1):
		var row_base := cz * _explored_grid_size.x
		for cx in range(min_cx, max_cx + 1):
			var dx := (cx + 0.5) * EXPLORED_CELL_M - pos.x
			var dz := (cz + 0.5) * EXPLORED_CELL_M - pos.z
			if dx * dx + dz * dz <= reach_sq:
				grid[row_base + cx] = 1
				marked = true
	if marked or not _explored_grids.has(player):
		# PackedByteArray 是 COW 值类型：字典里的副本不会随局部变量自动更新，
		# 变更后必须写回，否则探索进度永远落在字典外（静默丢失）。
		_explored_grids[player] = grid


## 放置判据（C# FullyVisible）的"已探明"查询：每个 footprint 采样点
## "当前可见 或 已探明"任一成立即放行。迷雾运行时被关掉（性能开关/观战）
## = 全图视为已探明；网格未初始化时返回 false，放置端退回纯"当前可见"
## 口径（等于旧行为，不会误放开）。
func is_explored(player, world_pos: Vector3) -> bool:
	if not _runtime_enabled:
		return true
	if _explored_grid_size == Vector2i.ZERO:
		return false
	var grid = _explored_grids.get(player)
	if grid == null:
		return false
	var cx := int(floor(world_pos.x / EXPLORED_CELL_M))
	var cz := int(floor(world_pos.z / EXPLORED_CELL_M))
	if cx < 0 or cz < 0 or cx >= _explored_grid_size.x or cz >= _explored_grid_size.y:
		return false
	return grid[cz * _explored_grid_size.x + cx] == 1


## 该玩家**当前**能不能看见这个世界点。
## 沿用单位可见性的表面到表面口径：sight_range_against（没有目标时用 sight_range）
## 再加与迷雾圈相同的 EXPLORED_SIGHT_COMPENSATION_M。只数这个玩家自己的、活着的、
## 已完工单位，不新做射线视线，也不把「曾经探明」当成现在看得见。
## 迷雾运行时关掉（测试/观战/性能开关）时全图算看得见，避免采集在无关夹具里停摆。
func player_can_see(player, world_pos: Vector3, target = null) -> bool:
	if not _runtime_enabled:
		return true
	if player == null:
		return false
	var flat_target := world_pos * Vector3(1, 0, 1)
	for unit in get_tree().get_nodes_in_group("units"):
		if not is_instance_valid(unit) or unit.get_parent() != player:
			continue
		if "hp" in unit and unit.hp != null and float(unit.hp) <= 0.0:
			continue
		if unit.has_method("is_constructed") and not unit.is_constructed():
			continue
		var sight_value = unit.get("sight_range")
		if sight_value == null:
			continue
		var sight := float(sight_value)
		if not is_finite(sight) or sight <= 0.0:
			continue
		var limit := sight
		if target != null and unit.has_method("sight_range_against"):
			limit = float(unit.sight_range_against(target))
		limit += EXPLORED_SIGHT_COMPENSATION_M
		var flat_position: Vector3 = unit.global_position
		var delta := (flat_position * Vector3(1, 0, 1)) - flat_target
		if delta.length() <= limit:
			return true
	return false
