extends Node

## 空间网格索敌索引正确性冒烟测试（2026-09-26 第一轮流畅度优化配套）。
## 覆盖：圆内/圆外/恰好边界（<=）、负坐标、跨多格检测半径、跨格移动/传送、
## 死亡注销（tree_exited 兜底）、归属变化（网格与队伍无关）、相位槽稳定性、
## 按 Match 隔离、兜底对账、固定种子随机样本下
## "网格查询+精确过滤" 与 "旧全场组扫描+精确过滤" 的结果一致性。
## 使用轻量 FakeUnit（Area3D + player 属性），不依赖完整 Match 场景。
## 注册语义镜像真实漏斗：`_make_unit` 调 `grid.register()`（等价
## `_setup_unit_groups` 的预置路径）；仅第 9 项刻意绕过以验证兜底对账。

const GridScript = preload("res://source/match/TargetAcquisitionGrid.gd")

## 网格只依赖：is_inside_tree / global_position / tree_exited / 分组。
## player 属性供精确过滤读取（与真实 Unit.gd 的"父节点即玩家"语义一致）。
class FakeUnit extends Area3D:
	var player: Node

	func _init():
		add_to_group("units")

var _failures := 0


func _ready():
	await get_tree().process_frame
	_run_all()
	print("Target acquisition grid smoke test completed: %d failure(s)" % _failures)
	SmokeTestExit.request(get_tree(), 0 if _failures == 0 else 1)


func _run_all():
	var match_a := _make_match("MatchA")
	var grid_a: Node = match_a.get_node("TargetAcquisitionGrid")
	var player_blue := _make_player(match_a, "Blue")
	var player_red := _make_player(match_a, "Red")

	# ---- 1) 圆内命中 / 圆外排除 / 恰好边界（旧语义 distance <= range） ----
	var near := _make_unit(grid_a, player_red, Vector3(10, 0, 10))
	var far := _make_unit(grid_a, player_red, Vector3(80, 0, 80))
	var boundary := _make_unit(grid_a, player_red, Vector3(15, 0, 0))   # 距原点恰 15
	_check_set(_exact(grid_a, Vector3.ZERO, 15.0, player_blue), [near, boundary],
		"半径 15 应含 10m 单位与恰好 15m 边界单位，不含 80m 单位")
	_check(_candidates(grid_a, Vector3.ZERO, 1.0).is_empty(),
		"检测圆内无单位时候选为空")

	# ---- 2) 负坐标与跨多格半径 ----
	var neg := _make_unit(grid_a, player_red, Vector3(-25, 0, -25))
	_check_set(_exact(grid_a, Vector3(-20, 0, -20), 10.0, player_blue), [neg],
		"负坐标格（floori 向下取整）应命中 (-25,-25) 单位")
	var wide := _make_unit(grid_a, player_red, Vector3(30, 0, 0))
	var wide2 := _make_unit(grid_a, player_red, Vector3(0, 0, -30))
	_check_set(_exact(grid_a, Vector3.ZERO, 35.0, player_blue), [near, boundary, wide, wide2],
		"半径 35 跨多格查询应覆盖四象限单位（(-25,-25) 距 35.36 被精确过滤排除）")

	# ---- 3) 跨格移动 / 传送：刷新在物理帧末统一 O(N) 生效 ----
	near.global_position = Vector3(50, 0, 50)
	await _wait_physics_frames(3)
	_check_set(_exact(grid_a, Vector3(50, 0, 50), 3.0, player_blue), [near],
		"跨格移动后新位置应可查到")
	_check_set(_exact(grid_a, Vector3(10, 0, 10), 3.0, player_blue), [],
		"旧格子不应再有该单位（无陈旧索引）")

	# ---- 4) 死亡/移除注销：tree_exited 兜底，不返回悬空引用 ----
	boundary.free()
	await get_tree().process_frame
	_check_set(_exact(grid_a, Vector3.ZERO, 16.0, player_blue), [],
		"已释放单位应从索引掉出且原圆内无残留")

	# ---- 5) 归属变化：网格与队伍无关（空间索引），队伍由调用方实时读取 ----
	near.player = player_blue
	_check(_candidates(grid_a, Vector3(50, 0, 50), 5.0).has(near),
		"归属变化后网格候选仍在（队伍语义在精确过滤层，行为与旧扫描一致）")

	# ---- 6) 相位槽：注册顺序决定、连续递增、稳定可复现 ----
	var last_slot: int = grid_a.get_phase_slot(wide2)
	for i in range(25):
		var unit := _make_unit(grid_a, player_red, Vector3(-60.0 + i, 0, 60))
		var slot: int = grid_a.get_phase_slot(unit)
		_check(slot == (last_slot + 1) % grid_a.STAGGER_SLOTS,
			"相位槽应按注册顺序连续递增（第 %d 个）" % i)
		last_slot = slot

	# ---- 7) 按 Match 隔离：另一局的网格查不到本局单位、相位计数独立 ----
	var match_b := _make_match("MatchB")
	var grid_b: Node = match_b.get_node("TargetAcquisitionGrid")
	var player_b := _make_player(match_b, "BlueB")
	_make_unit(grid_b, player_b, Vector3(0, 0, 0))
	var b_cands: Array = grid_b.acquire_candidates(Vector3.ZERO, 5.0)
	_check(b_cands.size() == 1 and not b_cands.has(near),
		"MatchB 的网格只含本局单位（跨局隔离）")
	var probe_b := _make_unit(grid_b, player_b, Vector3(6, 0, 6))
	_check(grid_b.get_phase_slot(probe_b) == 1 % grid_b.STAGGER_SLOTS,
		"MatchB 相位计数独立于 MatchA")

	# ---- 8) 固定种子随机样本：网格查询+精确过滤 == 旧全场组扫描+精确过滤 ----
	var rng := RandomNumberGenerator.new()
	rng.seed = 20260926
	for i in range(120):
		_make_unit(grid_a, player_red if i % 2 == 0 else player_blue,
			Vector3(rng.randf_range(-90, 90), 0, rng.randf_range(-90, 90)))
	var mismatches := 0
	for q in range(500):
		var origin := Vector3(rng.randf_range(-100, 100), 0, rng.randf_range(-100, 100))
		var radius := rng.randf_range(0.5, 40.0)
		var via_grid := _exact_ids(grid_a, origin, radius, player_blue)
		var via_scan := _scan_ids(origin, radius, player_blue)
		if via_grid != via_scan:
			mismatches += 1
			if mismatches <= 3:
				push_error("网格与全场扫描结果不一致: origin=%s r=%.2f" % [origin, radius])
	_check(mismatches == 0, "500 组随机查询：网格+精确过滤 与 旧全场扫描+精确过滤 完全一致")

	# ---- 9) 兜底对账：绕过注册漏斗直接入组的单位最终被补注册 ----
	var orphan := FakeUnit.new()
	orphan.player = player_red
	orphan.position = Vector3(70, 0, 70)
	player_red.add_child(orphan)
	var reconciled := false
	for i in range(40):
		await get_tree().physics_frame
		if grid_a.acquire_candidates(Vector3(70, 0, 70), 2.0).has(orphan):
			reconciled = true
			break
	_check(reconciled, "绕过注册漏斗的单位应在兜底对账（≤30 物理帧）后被索引")


# ------------------------------------------------------------------ helpers

func _make_match(match_name: String) -> Node3D:
	var match_node := Node3D.new()
	match_node.name = match_name
	add_child(match_node)
	var grid: Node = GridScript.new()
	grid.name = "TargetAcquisitionGrid"
	match_node.add_child(grid)
	return match_node


func _make_player(match_node: Node3D, player_name: String) -> Node:
	var player := Node3D.new()
	player.name = player_name
	player.set_script(preload("res://source/match/players/Player.gd"))
	match_node.add_child(player)
	return player


## 镜像真实注册漏斗：入树后立即 register（等价 `_setup_unit_groups` 预置路径）。
func _make_unit(grid: Node, player: Node, position: Vector3) -> FakeUnit:
	var unit := FakeUnit.new()
	unit.player = player
	unit.position = position
	player.add_child(unit)
	grid.register(unit)
	return unit


## 查询网格候选（仅空间筛选，无精确过滤）。
func _candidates(grid: Node, origin: Vector3, radius: float) -> Array:
	return grid.acquire_candidates(origin, radius)


## 网格候选 + 与 WaitingForTargets 相同的精确过滤（只保留队伍和距离语义）。
func _exact(grid: Node, origin: Vector3, radius: float, query_player: Node) -> Array:
	return grid.acquire_candidates(origin, radius).filter(
		func(unit):
			return is_instance_valid(unit) and unit.player != query_player \
				and origin.distance_to(unit.global_position) <= radius
	)


func _exact_ids(grid: Node, origin: Vector3, radius: float, query_player: Node) -> Array:
	var ids: Array = _exact(grid, origin, radius, query_player).map(
		func(unit): return unit.get_instance_id()
	)
	ids.sort()
	return ids


## 旧实现的参照口径：全场组扫描 + 同一精确过滤。
func _scan_ids(origin: Vector3, radius: float, query_player: Node) -> Array:
	var ids: Array = get_tree().get_nodes_in_group("units").filter(
		func(unit):
			return is_instance_valid(unit) and unit.player != query_player \
				and origin.distance_to(unit.global_position) <= radius
	).map(
		func(unit): return unit.get_instance_id()
	)
	ids.sort()
	return ids


func _wait_physics_frames(count: int) -> void:
	for i in range(count):
		await get_tree().physics_frame


func _check_set(actual: Array, expected: Array, message: String) -> void:
	var actual_ids: Array = actual.map(func(u): return u.get_instance_id())
	var expected_ids: Array = expected.map(func(u): return u.get_instance_id())
	actual_ids.sort()
	expected_ids.sort()
	if actual_ids != expected_ids:
		_failures += 1
		push_error("集合断言失败: %s (actual=%d expected=%d)" % [
			message, actual_ids.size(), expected_ids.size()])


func _check(condition: bool, message: String) -> void:
	if condition:
		return
	_failures += 1
	push_error("Target acquisition grid assertion failed: %s" % message)
