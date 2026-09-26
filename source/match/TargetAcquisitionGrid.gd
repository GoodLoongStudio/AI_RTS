extends Node

## 空间网格索敌索引（2026-09-26 第一轮"大量单位流畅度优化"）。
##
## ## 为什么需要它
## `WaitingForTargets._get_units_to_attack()` 原先每 167ms 对全场
## `get_nodes_in_group("units")` 做一次 O(N) 扫描：N 个待机单位 = 每秒 6·N² 次
## 候选检查（400 单位 ≈ 96 万次/秒），且每个 Timer 同帧启动 → 集中尖峰。
##
## ## 职责边界（只做空间候选筛选）
## 网格只回答"检测圆覆盖哪些格子里有哪些单位"；敌我关系、攻击域、
## 视野/射程与姿态规则、有效性仍由调用方按原规则精确检查——行为零迁移。
##
## ## 生命周期（与 Match 隔离，每局一个实例）
## - 注册：`Match._setup_unit_groups()`（出场唯一漏斗 `_setup_and_spawn_unit`
##   与预置单位路径都会走到）→ `register()`；`MatchSignals.unit_spawned`
##   （此时变换已写入）→ `assign_cell()`。
## - 注销：`MatchSignals.unit_died`（`Unit.gd` 死亡路径 emit 后才 queue_free）。
## - 兜底对账：低频（每 30 物理帧）扫描 `units` 组补注册——只补"漏注册"，
##   查询永远不会回退到全场扫描（避免掩盖索引错误）。
## - 换局：网格是 Match 子节点，随 Match 释放；`_exit_tree` 清空全部字典，
##   无跨局污染。
##
## ## 索引更新与查询的先后关系（必须了解）
## - 位置刷新：本节点 `_physics_process`（`process_priority` 设为极大值 →
##   在所有单位 Movement 的 `_physics_process` 之后执行）做一次统一 O(N)
##   跨格迁移，快照 = "本物理帧末"的位置。
## - 查询：`WaitingForTargets` 的 Timer 回调发生在 idle（_process）阶段，
##   读到的就是最近一次物理帧末的快照；快照滞后的上限是 1 个物理 tick
##   （60Hz 图 16.7ms / 大地图 20Hz 50ms），跨格瞬间以格子为粒度保守覆盖，
##   精确距离仍由调用方按查询时的实际判定完成。
## - 出生当帧即可被查到（`assign_cell` 在变换写入后调用）；死亡当帧即注销。

const CELL_SIZE := 10.0
## 索敌相位槽数：错峰把不同单位的查询起点分摊到一个索敌周期内。
const STAGGER_SLOTS := 10
## 兜底对账周期（物理帧）。
const RECONCILE_INTERVAL_TICKS := 30

## 测试与环境开关（缺省 = 网格 + 错峰都开启，正常游戏默认生效）：
## AIRTS_TARGETING=baseline   → 关网格，回到全场组扫描基线（对照测量用）
## AIRTS_TARGETING=nostagger  → 网格开启，错峰关闭（对照测量用）
var use_grid := true
var use_stagger := true

## 诊断计数（WaitingForTargets 累加查询侧；本节点累加维护侧）。
## 全部为普通整数累加，开销可忽略；不逐帧打印。
var stats := {
	"query_calls": 0,            # acquire_candidates 调用次数
	"candidates_returned": 0,    # 网格返回的候选总数
	"scan_time_us": 0,           # 查询侧累计耗时（含基线组扫描）
	"peak_frame_scan_us": 0,     # 单帧查询侧耗时峰值
	"index_maintain_us": 0,      # 索引维护累计耗时（刷新+对账+注册）
	"registered": 0,             # 当前注册单位数
	"cell_moves": 0,             # 跨格迁移次数
	"reconciled": 0,             # 兜底补注册次数
}
var _frame_scan_us := 0
var _cells := {}          # Vector2i -> Array[Unit 引用]
var _unit_cells := {}     # Unit -> Vector2i
var _unit_slots := {}     # Unit -> int（错峰相位，注册顺序决定，稳定可重复）
var _slot_counter := 0
var _pending := {}        # Unit -> true（已注册、待定位格）
var _reconcile_countdown := RECONCILE_INTERVAL_TICKS
var _maintain_accum_us := 0


func _ready() -> void:
	var targeting := OS.get_environment("AIRTS_TARGETING")
	# baseline = Match 不创建本节点（差分用旧代码等价形态）；
	# basestats = 节点仅作统计宿主，查询走旧全场组扫描（性能对照的 A 版本）；
	# nostagger = 网格开启、错峰关闭（B 版本）；缺省 = 网格 + 错峰（C 版本/正常游戏）。
	use_grid = targeting != "baseline" and targeting != "basestats"
	use_stagger = use_grid and targeting != "nostagger"
	# 物理帧内最后执行：确保刷新快照晚于所有单位 Movement 的位置写入。
	process_priority = 100000
	MatchSignals.unit_spawned.connect(_on_unit_spawned)
	MatchSignals.unit_died.connect(_on_unit_died)


func _exit_tree() -> void:
	if MatchSignals.unit_spawned.is_connected(_on_unit_spawned):
		MatchSignals.unit_spawned.disconnect(_on_unit_spawned)
	if MatchSignals.unit_died.is_connected(_on_unit_died):
		MatchSignals.unit_died.disconnect(_on_unit_died)
	_cells.clear()
	_unit_cells.clear()
	_unit_slots.clear()
	_pending.clear()


## 供 `Match._setup_unit_groups()` 调用（出场唯一漏斗）。
## 预置单位此时已在场景树内 → 立即定位；生产路径此时还没 add_child，
## 变换也未写入 → 留在 `_pending`，由 `unit_spawned`（变换已写）定位。
func register(unit) -> void:
	if _unit_cells.has(unit) or _pending.has(unit):
		return
	_unit_slots[unit] = _slot_counter % STAGGER_SLOTS
	_slot_counter += 1
	stats["registered"] = _unit_cells.size() + _pending.size()
	# 兜底注销：unit_died 之外还有直接 free() 的路径（测试/模组），
	# 离树即掉索引，避免悬空引用滞留格桶。
	unit.tree_exited.connect(_drop.bind(unit))
	if unit.is_inside_tree():
		_assign_cell(unit)
	else:
		_pending[unit] = true


## 错峰相位槽（WaitingForTargets 用它决定首个索敌回调的相位）。
## 注册顺序稳定 → 同一局内分配确定且可重复；不依赖随机数或墙上时钟。
func get_phase_slot(unit) -> int:
	return int(_unit_slots.get(unit, 0))


## 索敌候选查询：返回检测圆（XZ 平面）覆盖格子里的全部注册单位。
## 不做敌我/域/姿态过滤——调用方按原规则精确检查（含 is_instance_valid）。
## 注意：本方法不计入诊断计数——"索敌总耗时"必须包含调用方的精确过滤，
## 由 `note_scan()` 在调用方统一记录（基线与网格两种口径对称）。
func acquire_candidates(origin: Vector3, radius: float) -> Array:
	var result: Array = []
	if not use_grid:
		# 基线口径：全场组扫描（仅供对照测量，正常游戏不会走到这里）。
		return get_tree().get_nodes_in_group("units")
	var min_x := floori((origin.x - radius) / CELL_SIZE)
	var max_x := floori((origin.x + radius) / CELL_SIZE)
	var min_z := floori((origin.z - radius) / CELL_SIZE)
	var max_z := floori((origin.z + radius) / CELL_SIZE)
	for cx in range(min_x, max_x + 1):
		for cz in range(min_z, max_z + 1):
			# 注意：_cells.get 缺键返回 null，不能用 Array 类型变量接（会运行时报错）。
			var bucket = _cells.get(Vector2i(cx, cz))
			if bucket != null and not bucket.is_empty():
				result.append_array(bucket)
	return result


## 调用方（WaitingForTargets）在"候选收集 + 精确过滤"完成后调用：
## candidate_checks = 精确检查次数（每个候选恰检查一次），elapsed_us = 全程耗时。
func note_scan(candidate_checks: int, elapsed_us: int) -> void:
	stats["query_calls"] += 1
	stats["candidates_returned"] += candidate_checks
	stats["scan_time_us"] += elapsed_us
	_frame_scan_us += elapsed_us
	if _frame_scan_us > int(stats["peak_frame_scan_us"]):
		stats["peak_frame_scan_us"] = _frame_scan_us


func reset_stats() -> void:
	for key in ["query_calls", "candidates_returned", "scan_time_us",
			"peak_frame_scan_us", "index_maintain_us", "cell_moves", "reconciled"]:
		stats[key] = 0
	_frame_scan_us = 0


## 每帧帧尾调用（由 WaitingForTargets 在 _process 末尾推不动——改为
## 本节点 _process 内清零，保证 peak 是"单帧"口径）。
func _process(_delta) -> void:
	_frame_scan_us = 0


func _physics_process(_delta) -> void:
	# basestats/baseline 模式：网格未启用，无索引维护成本（A 版本口径纯净）。
	if not use_grid:
		return
	var t0 := Time.get_ticks_usec()
	# 1) 待定位（本物理帧内出生）的单位补格。
	if not _pending.is_empty():
		for unit in _pending.keys():
			if is_instance_valid(unit) and unit.is_inside_tree():
				_assign_cell(unit)
			_pending.erase(unit)
	# 2) 统一 O(N) 跨格迁移：快照 = 本物理帧末位置。
	for unit in _unit_cells.keys():
		if not is_instance_valid(unit):
			_drop(unit)
			continue
		var key := _cell_of(unit.global_position)
		if key != _unit_cells[unit]:
			_move_unit(unit, key)
	# 3) 低频兜底对账：补注册绕过漏斗出现的单位（如测试直接 add_child）。
	_reconcile_countdown -= 1
	if _reconcile_countdown <= 0:
		_reconcile_countdown = RECONCILE_INTERVAL_TICKS
		for unit in get_tree().get_nodes_in_group("units"):
			if not _unit_cells.has(unit) and not _pending.has(unit):
				register(unit)
				stats["reconciled"] += 1
	_maintain_accum_us = Time.get_ticks_usec() - t0
	stats["index_maintain_us"] += _maintain_accum_us


## 网格外直查（调试/测试用）：与查询同一套精确距离语义的暴力参照。
func debug_brute_force(origin: Vector3, radius: float) -> Array:
	var result: Array = []
	for unit in _unit_cells.keys():
		if is_instance_valid(unit):
			var dx: float = unit.global_position.x - origin.x
			var dz: float = unit.global_position.z - origin.z
			if dx * dx + dz * dz <= radius * radius:
				result.append(unit)
	return result


func _on_unit_spawned(unit) -> void:
	# 仅接受属于本 Match 的单位（同进程多局/测试场景隔离）。
	if not is_instance_valid(unit) or not _belongs_to_match(unit):
		return
	if _pending.has(unit):
		_pending.erase(unit)
		_assign_cell(unit)


func _on_unit_died(unit) -> void:
	if _belongs_to_match(unit):
		_drop(unit)


func _belongs_to_match(unit) -> bool:
	return unit != null and is_instance_valid(unit) and unit.find_parent("Match") == get_parent()


func _assign_cell(unit) -> void:
	var key := _cell_of(unit.global_position)
	_unit_cells[unit] = key
	if not _cells.has(key):
		_cells[key] = []
	_cells[key].append(unit)


func _move_unit(unit, key: Vector2i) -> void:
	var old_key: Vector2i = _unit_cells[unit]
	var bucket = _cells.get(old_key)
	if bucket != null:
		bucket.erase(unit)
		if bucket.is_empty():
			_cells.erase(old_key)
	_unit_cells[unit] = key
	if not _cells.has(key):
		_cells[key] = []
	_cells[key].append(unit)
	stats["cell_moves"] += 1


func _drop(unit) -> void:
	_pending.erase(unit)
	if not _unit_cells.has(unit):
		return
	var bucket = _cells.get(_unit_cells[unit])
	if bucket != null:
		bucket.erase(unit)
		if bucket.is_empty():
			_cells.erase(_unit_cells[unit])
	_unit_cells.erase(unit)
	stats["registered"] = _unit_cells.size() + _pending.size()


func _cell_of(position: Vector3) -> Vector2i:
	return Vector2i(floori(position.x / CELL_SIZE), floori(position.z / CELL_SIZE))
