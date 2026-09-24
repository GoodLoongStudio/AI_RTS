extends Node3D

const SIGHT_COMPENSATION = 2.0  # compensates for blurry edges of FoW

const Structure = preload("res://source/match/units/Structure.gd")

var _units_processed_at_least_once = {}
var _structure_to_dummy_mapping = {}
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
	_sweep_stale_ghosts()
	var all_units = _cached_units
	# Group membership can change when a player is revealed/concealed without a spawn
	# signal. Filtering the cached array is cheap and avoids repeated scene-tree scans.
	var revealed_units = all_units.filter(func(unit): return is_instance_valid(unit) and unit.is_in_group("revealed_units"))
	for unit in all_units:
		if not is_instance_valid(unit):
			continue
		# 【2026-09-23 修"敌方死亡的建筑还在"】`queue_free()` 是帧末延迟释放：建筑死亡
		# 当帧仍在 units 组里、`visible` 还是上一拍留下的 true。若本拍落在死亡信号
		# **之后**，就会判定"建筑脱视野"→ 给一座已死的建筑新建残影；而 `_on_unit_died`
		# 已经跑完（那一刻残影还不存在），于是残影永久留在场上——玩家就看到刚打掉的
		# 建筑还立在那里。对已判死的单位整条可见性链路一律跳过。
		if unit.is_queued_for_deletion():
			continue
		_recalculate_unit_visibility(unit, revealed_units)


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
	# 已判死的建筑不再生成残影（帧末才真正释放，此刻仍在组里）。没有这道闸，
	# 死亡当帧的可见性更新会把残影建在死亡信号之后，谁都不会再清它。
	if unit.is_queued_for_deletion():
		return
	var dummy = unit.find_child("Geometry").duplicate()
	dummy.global_transform = unit.find_child("Geometry").global_transform
	add_child(dummy)
	_structure_to_dummy_mapping[unit] = dummy


## 兜底清扫：键单位已释放/已判死的残影一律清掉。正常死亡在 `_on_unit_died`
## 里即时清；这里是防线——任何来路的泄漏（含上面那道闸漏掉的时序）最多停留一拍。
func _sweep_stale_ghosts() -> void:
	if _structure_to_dummy_mapping.is_empty():
		return
	var stale: Array = []
	for unit in _structure_to_dummy_mapping:
		if not is_instance_valid(unit) or unit.is_queued_for_deletion():
			stale.append(unit)
	for unit in stale:
		var ghost = _structure_to_dummy_mapping[unit]
		_structure_to_dummy_mapping.erase(unit)
		if is_instance_valid(ghost):
			ghost.queue_free()


func _try_removing_dummy_structure(unit):
	if unit in _structure_to_dummy_mapping:
		_structure_to_dummy_mapping[unit].queue_free()
		_structure_to_dummy_mapping.erase(unit)


func _on_unit_died(unit):
	_cached_units.erase(unit)
	_cache_dirty = true
	_units_processed_at_least_once.erase(unit)
	if unit in _structure_to_dummy_mapping:
		# 【2026-09-23 修"敌人建筑被打掉了怎么还在"】建筑已毁，它的迷雾残影
		# 必须**立即**清除。旧实现把残影挂成"孤儿 dummy"、等玩家重新照到该位置
		# 才删：副官部队打掉敌方建筑、转移阵地后，玩家会在原位置看到一个
		# 一模一样的建筑残影——那就是用户报的"建筑被打掉了怎么还在"。
		# 迷雾残影的本意是"看不见但存在的建筑"；已销毁的建筑不存在，
		# 留着就是错误信息（玩家刚刚亲手打掉它，却看它还立在那里）。
		_structure_to_dummy_mapping[unit].queue_free()
		_structure_to_dummy_mapping.erase(unit)


func _on_unit_spawned(_unit):
	_cache_dirty = true
	# Keep the first visibility decision responsive while the regular cadence handles
	# subsequent movement/reveal updates.
	_update_elapsed = UPDATE_INTERVAL


func _refresh_unit_cache() -> void:
	# 已判死的单位不进缓存：它们帧末就释放，不该再参与可见性判定（否则会把
	# 残影建到死亡之后，见 _physics_process 里的 queued_for_deletion 跳过）。
	_cached_units = get_tree().get_nodes_in_group("units").filter(
		func(unit): return is_instance_valid(unit) and not unit.is_queued_for_deletion()
	)
	_cache_dirty = false
