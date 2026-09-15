extends Node3D

const SIGHT_COMPENSATION = 2.0  # compensates for blurry edges of FoW

const Structure = preload("res://source/match/units/Structure.gd")

var _units_processed_at_least_once = {}
var _structure_to_dummy_mapping = {}
var _orphaned_dummies = []
# 【2026-09-15 主线程减负】0.10 → 0.20：本处理器是 O(单位数 × 可见单位数) 的距离判定
# （对每个单位遍历 revealed_units），60v60 场景每秒约 3.6 万次距离计算，全部落在主线程
# 的 `_physics_process` 里。显隐延迟多 0.1s 玩家不可察觉，计算量直接减半。
# 根治需空间分区（网格索引），另开一轮；若显隐手感异常，改回 0.10 即可完全回退。
const UPDATE_INTERVAL := 0.20
var _update_elapsed := UPDATE_INTERVAL
var _cached_units: Array = []
var _cache_dirty := true


func _ready():
	MatchSignals.unit_spawned.connect(_on_unit_spawned)
	MatchSignals.unit_died.connect(_on_unit_died)
	_refresh_unit_cache()


func _physics_process(delta):
	_update_elapsed += delta
	if _update_elapsed < UPDATE_INTERVAL and not _cache_dirty:
		return
	_update_elapsed = fmod(_update_elapsed, UPDATE_INTERVAL)
	if _cache_dirty:
		_refresh_unit_cache()
	var all_units = _cached_units
	# Group membership can change when a player is revealed/concealed without a spawn
	# signal. Filtering the cached array is cheap and avoids repeated scene-tree scans.
	var revealed_units = all_units.filter(func(unit): return is_instance_valid(unit) and unit.is_in_group("revealed_units"))
	for unit in all_units:
		if not is_instance_valid(unit):
			continue
		_recalculate_unit_visibility(unit, revealed_units)
	for orphaned_dummy in _orphaned_dummies:
		_recalcuate_orphaned_dummy_existence(orphaned_dummy, revealed_units)


func _is_disabled():
	return not visible


func _recalculate_unit_visibility(unit, revealed_units = null):
	if unit == null or not is_instance_valid(unit):
		return
	if unit.is_in_group("revealed_units") or _is_disabled():
		_update_unit_visibility(unit, true)
		return

	var should_be_visible = false
	if revealed_units == null:
		revealed_units = _cached_units.filter(
			func(a_unit): return a_unit.is_in_group("revealed_units")
		)
	for revealed_unit in revealed_units:
		if (
			revealed_unit.is_revealing()
			and revealed_unit.sight_range != null
			and (
				(revealed_unit.global_position * Vector3(1, 0, 1)).distance_squared_to(
					unit.global_position * Vector3(1, 0, 1)
				)
				<= pow(float(revealed_unit.sight_range) + SIGHT_COMPENSATION, 2.0)
			)
		):
			should_be_visible = true
			break
	_update_unit_visibility(unit, should_be_visible)


func _update_unit_visibility(unit, should_be_visible):
	if (
		unit in _units_processed_at_least_once
		and unit is Structure
		and unit.visible != should_be_visible
	):
		if unit.visible:
			_create_dummy_structure(unit)
		else:
			_try_removing_dummy_structure(unit)
	unit.visible = should_be_visible
	_units_processed_at_least_once[unit] = true


func _create_dummy_structure(unit):
	if unit in _structure_to_dummy_mapping:
		return
	var dummy = unit.find_child("Geometry").duplicate()
	dummy.global_transform = unit.find_child("Geometry").global_transform
	add_child(dummy)
	_structure_to_dummy_mapping[unit] = dummy


func _try_removing_dummy_structure(unit):
	if unit in _structure_to_dummy_mapping:
		_structure_to_dummy_mapping[unit].queue_free()
		_structure_to_dummy_mapping.erase(unit)


func _recalcuate_orphaned_dummy_existence(orphaned_dummy, revealed_units = null):
	if orphaned_dummy == null or not is_instance_valid(orphaned_dummy):
		_orphaned_dummies.erase(orphaned_dummy)
		return
	var should_exist = true
	if revealed_units == null:
		revealed_units = _cached_units.filter(
			func(unit): return unit.is_in_group("revealed_units")
		)
	for revealed_unit in revealed_units:
		if (
			revealed_unit.is_revealing()
			and revealed_unit.sight_range != null
			and (
				(revealed_unit.global_position * Vector3(1, 0, 1)).distance_squared_to(
					orphaned_dummy.global_position * Vector3(1, 0, 1)
				)
				<= pow(float(revealed_unit.sight_range) + SIGHT_COMPENSATION, 2.0)
			)
		):
			should_exist = false
			break
	if not should_exist:
		_orphaned_dummies.erase(orphaned_dummy)
		orphaned_dummy.queue_free()


func _on_unit_died(unit):
	_cached_units.erase(unit)
	_cache_dirty = true
	_units_processed_at_least_once.erase(unit)
	if unit in _structure_to_dummy_mapping:
		var orphaned_dummy = _structure_to_dummy_mapping[unit]
		_structure_to_dummy_mapping.erase(unit)
		_orphaned_dummies.append(orphaned_dummy)
		_recalcuate_orphaned_dummy_existence(orphaned_dummy)


func _on_unit_spawned(_unit):
	_cache_dirty = true
	# Keep the first visibility decision responsive while the regular cadence handles
	# subsequent movement/reveal updates.
	_update_elapsed = UPDATE_INTERVAL


func _refresh_unit_cache() -> void:
	_cached_units = get_tree().get_nodes_in_group("units")
	_cache_dirty = false
