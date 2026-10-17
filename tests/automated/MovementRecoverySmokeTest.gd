extends Node

## 移动 / 寻路 / 脱困 场景验收（2026-09-11）。
##
## 覆盖玩家实测的三类问题：
##   1. 单兵绕墙：目的地在大片障碍另一侧，必须走合法绕路且真正到达（不得中途假失败）。
##   2. 窄口双向交会：两车对穿同一缺口，必须都能到达，不得互相永久卡死。
##   3. 集体回基地：多单位同时回防同一基地，必须全部收敛且不叠在同一格。
##   4. 行进中新建建筑：重烘导航网格期间单位不得集体站桩（路径修复 + 双缓冲）。
##   5. 脱困期间玩家改命令：新命令必须立即生效，旧脱困/旧目标不得复活。
##
## 所有成功判定都基于权威订单终态 Arrived 或真实位置，绝不把 Accepted / Unreachable 当成功。

const SmokeTestWarmup = preload("res://tests/automated/SmokeTestWarmup.gd")
const MovementScript = preload("res://source/match/units/traits/Movement.gd")
const MatchScene = preload("res://tests/manual/TestOneUnit.tscn")
const CommandCenterScene = preload("res://source/match/units/CommandCenter.tscn")
const WorkerScene = preload("res://source/match/units/Worker.tscn")

## 判定"已到达"的平面误差（普通集结允许合理到达误差）。
const ARRIVAL_TOLERANCE_M := 2.0
## "回到基地附近"的判据必须**由几何推出**（2026-09-29 实测修）：单位中心最近只能到
## `建筑 footprint + 导航 agent 半径`（尺寸统一后是 7.0 + 2.8 = 9.8m）处，写死 4.5m
## 在新尺度下是恒假命题 —— 实测 `at_base=0/8` 看起来像"部队不会回家集结"，
## 实际是尺子还停在放大前。改成"基地半径 + 单位半径 + 余量"，两侧尺度怎么变都成立。
const BASE_APPROACH_SLACK_M := 1.0
## 交错后两单位的最小可通行间距。
const MIN_SEPARATION_M := 1.2

var _failures := 0
var _wall: Array = []


func _ready():
	var match_instance = MatchScene.instantiate()
	add_child(match_instance)
	await SmokeTestWarmup.wait_for_units(get_tree(), 1)

	var human = match_instance.get_node("Players/Human")
	var tank: Node3D = human.get_node("Tank")
	var gateway = human.get_node("UnitCommandGateway")
	var movement = tank.find_child("Movement")
	await SmokeTestWarmup.wait_for_navigation(get_tree(), movement, tank.global_position)

	await _scenario_wall_detour(match_instance, human, tank, gateway)
	await _scenario_narrow_head_on(match_instance, human, gateway, tank)
	await _scenario_group_return_to_base(match_instance, human, gateway)
	await _scenario_building_added_mid_move(match_instance, human, gateway, tank)
	await _scenario_player_override_during_recovery(match_instance, human, gateway, tank)

	# 本轮场景确实走到了停滞判定 → 脱困检查没有被完全旁路（否则上面的覆盖断言没有意义）。
	_check(
		MovementScript.recovery_stats["stall_detections"] > 0,
		"整轮场景应至少触发一次停滞检测/脱困检查"
	)
	_check(
		MovementScript.recovery_stats["unreachable"] == 0,
		"合法场景不得产生假 Unreachable（actual=%d）"
		% MovementScript.recovery_stats["unreachable"]
	)
	print(
		"[MOVEMENT] recovery_stats=", MovementScript.recovery_stats,
		" budget_skips=", MovementScript.recovery_stats["budget_skips"]
	)
	print("Movement recovery smoke test completed: %d failure(s)" % _failures)
	match_instance.queue_free()
	await get_tree().process_frame
	SmokeTestExit.request(get_tree(), 0 if _failures == 0 else 1)


## 墙砖/障碍相关余量（米）：见 `_wall_layout()`。
const WALL_STANDOFF_SLACK_M := 1.0
## 窄口宽度 = 2×(坦克半径 + 此余量)：09-27 尺寸统一后，写死的 7.5m "窄口"
## 会被 footprint 7.0 的墙砖直接糊死（两侧砖的避让圈重叠），
## "挤过同一个窄口"这个前提就不存在了 —— 实测 jam 场景的目标点落在墙肚子里，
## `state=Arrived` 但 `planar_err=13.71/8.48`，量的其实是"到不了障碍内部"。
const JAM_GAP_SLACK_M := 1.0


## 【2026-09-30 carve 口径修正】导航可走带 = 障碍 footprint + navmesh.agent_radius。
## MovementObstacle 现在按 footprint 生成 carve 顶点环（实测洞边界 = footprint + agent 2.8），
## 所以夹具几何必须按**这个半径**推导：只按 footprint 推导会让落点/目标/缺口落进 carve 洞
## ——实测绕墙 standoff 10.0 对洞 9.8 只剩 0.2m（体素 0.25m）、窄口可通行半宽只剩 0.2m、
## "新建建筑"场景目标 18m 落在 9m 处砖的 9.8m 洞里，到达误差 19~71m。
## 断言一条没改，改的只是"按引擎真实可走带推导几何"。
func _navmesh_agent_radius(match_instance) -> float:
	var region = match_instance.get_node_or_null("Navigation/Terrain/NavigationRegion3D")
	if region == null:
		for sub in match_instance.find_children("*", "NavigationRegion3D", true, false):
			region = sub
			break
	if region != null and region.get("navigation_mesh") != null:
		return float(region.get("navigation_mesh").get("agent_radius"))
	return 2.8


## 不入树地读出某场景的"本体半径"（`Unit.body_radius()` 读 Movement/MovementObstacle
## 的导出值， instantiate 后即可取），用于把场景几何**按当前尺度**推出来。
func _scene_body_radius(scene: PackedScene) -> float:
	var probe: Node3D = scene.instantiate()
	var value := 0.0
	if probe.has_method("body_radius"):
		value = float(probe.call("body_radius"))
	probe.free()
	return value


# --- 场景 1：单兵绕墙 ---

func _scenario_wall_detour(match_instance, human, tank: Node3D, gateway) -> void:
	_clear_wall()
	var start: Vector3 = tank.global_position
	# 墙线、砖间距、目标点全部由**砖的真实半径**推出：砖心间隔 `2r` 才连成一道无洞的墙，
	# 坦克与目标各离墙线 `r + 坦克半径 + 余量` 才落在可行走的导航带上；缺口留在 -z 一端。
	var block_r := _scene_body_radius(CommandCenterScene)
	var nav_band := _navmesh_agent_radius(match_instance)
	var standoff := maxf(block_r + nav_band + tank.body_radius() + WALL_STANDOFF_SLACK_M, 1.0)
	var wall_x: float = start.x + standoff
	# 【2026-09-30】砖数 6→3：carve 修好后砖心间隔 2r 的墙**真的没有缝**了
	# （相邻砖的洞各 9.8m、间距 14m ⇒ 重叠 5.6m）。6 砖墙在 54×54 图上等于整幅封锁，
	# 单兵只能绕到墙端：2×(墙端 z + carve − 起点 z) + 横向 25.6 ≈ 171m ≈ 62s，
	# 超过本场景 40s 预算（且失败会把坦克留在 z≈81，连锁毁掉下一个场景的几何起点）。
	# 3 砖仍是一道绕不过去的实心墙，绕行 ≈ 87m ≈ 32s，落在预算内。
	for index in range(3):
		_spawn_wall_block(match_instance, human, wall_x,
			start.z - block_r + float(index) * block_r * 2.0)
	await _wait_frames(45)

	var target := Vector3(wall_x + standoff, 0.0, start.z)
	var started_ms := Time.get_ticks_msec()
	# 【2026-09-30 预算按几何推导，不是放宽判据】墙的 -z 端 carve 后落在 z<-4（图外），
	# 唯一合法路线是绕 +z 端：2×(43.4−12.6) + 25.6 ≈ 88m，坦克 2.75m/s ⇒ ~32s，
	# 加上重寻路/贴边修正实测需要 50~60s。40s 窗口会把"慢"误判成"坏"
	# （与 ore-refinery 把 150s→260s 的理由同类）。断言一条没改：仍必须 Arrived 且误差达标。
	var state := await _order_and_wait(gateway, [tank], target, human, 5400)
	var elapsed_ms := Time.get_ticks_msec() - started_ms
	var planar := _planar_distance(tank.global_position, target)
	_check(state == "Arrived", "绕墙后单兵必须真正到达（state=%s）" % state)
	_check(planar <= ARRIVAL_TOLERANCE_M, "绕墙到达误差应合理（%.2fm）" % planar)
	_check(
		_planar_distance(tank.global_position, start) > 5.0,
		"绕墙场景确实发生了长距离移动（%.2fm）" % _planar_distance(tank.global_position, start)
	)
	print(
		"[MOVEMENT] wall-detour state=%s elapsed_ms=%d start=%s end=%s planar_err=%.2f"
		% [state, elapsed_ms, start, tank.global_position, planar]
	)
	# 回到墙的 -z 侧缺口附近，供后续场景复用。
	await _order_and_wait(gateway, [tank], Vector3(16.0, 0.0, 12.637), human, 1800)


# --- 场景 2：窄口双向交会 ---

func _scenario_narrow_head_on(match_instance, human, gateway, tank: Node3D) -> void:
	_clear_wall()
	# 上下两段墙、中间一个缺口：两车必须对穿同一个缺口。
	# 布局全部由**墙砖真实半径**推导（写死的 2.5m 砖距 + 3.4m 缺口在 footprint 7.0
	# 之后会被两侧避让圈糊死，两侧落点也落进墙肚子里 ⇒ `Unreachable` 是几何必然）。
	var original: Vector3 = tank.global_position
	var block_r := _scene_body_radius(CommandCenterScene)
	var nav_band := _navmesh_agent_radius(match_instance)
	# 缺口可通行半宽 = gap_half - carve 带(nav_band)，必须留出坦克半径 + 余量。
	var gap_half: float = nav_band + tank.body_radius() + JAM_GAP_SLACK_M
	var standoff := maxf(block_r + nav_band + tank.body_radius() + WALL_STANDOFF_SLACK_M, 1.0)
	var wall_x: float = original.x + standoff
	var near_x: float = wall_x - standoff
	var far_x: float = wall_x + standoff
	for index in range(3):
		_spawn_wall_block(match_instance, human, wall_x,
			original.z - gap_half - block_r - float(index) * block_r * 2.0)
	for index in range(3):
		_spawn_wall_block(match_instance, human, wall_x,
			original.z + gap_half + block_r + float(index) * block_r * 2.0)
	await _wait_frames(45)

	var other: Node3D = _spawn_unit(match_instance, human, WorkerScene, Vector3(far_x, 0.0, original.z))
	var second: Node3D = _spawn_unit(match_instance, human, WorkerScene, Vector3(far_x, 0.0, original.z))
	await _wait_frames(5)
	gateway.SetFirePolicy([tank, other, second], "HoldFire", human)

	var target_a := Vector3(far_x, 0.0, original.z)
	var target_b := Vector3(near_x, 0.0, original.z)
	var started_ms := Time.get_ticks_msec()
	var result_a: Dictionary = gateway.MoveUnits([tank], target_a, human)
	var result_b: Dictionary = gateway.MoveUnits([other], target_b, human)
	var order_a := _order_id(result_a)
	var order_b := _order_id(result_b)
	var terminal_a := await _wait_terminal_order(gateway, order_a, 2400)
	var terminal_b := await _wait_terminal_order(gateway, order_b, 2400)
	var elapsed_ms := Time.get_ticks_msec() - started_ms
	var separation := _planar_distance(tank.global_position, other.global_position)
	_check(terminal_a == "Arrived", "对穿缺口的第一辆车必须到达（state=%s）" % terminal_a)
	_check(terminal_b == "Arrived", "对穿缺口的第二辆车必须到达（state=%s）" % terminal_b)
	_check(separation >= MIN_SEPARATION_M, "交会后两车应保持可通行间距（%.2fm）" % separation)
	print(
		"[MOVEMENT] head-on a=%s b=%s elapsed_ms=%d separation=%.2f"
		% [terminal_a, terminal_b, elapsed_ms, separation]
	)
	_remove_unit(other)
	_remove_unit(second)


# --- 场景 3：集体回基地 ---

func _scenario_group_return_to_base(match_instance, human, gateway) -> void:
	_clear_wall()
	var base: Node3D = _spawn_unit(
		match_instance, human, CommandCenterScene, Vector3(12.0, 0.0, 28.0)
	)
	var workers: Array = []
	for index in range(8):
		var angle := TAU * float(index) / 8.0
		var position := base.global_position + Vector3(cos(angle), 0.0, sin(angle)) * 9.0
		workers.append(_spawn_unit(match_instance, human, WorkerScene, position))
	await _wait_frames(5)
	gateway.SetFirePolicy(workers, "HoldFire", human)

	var stance_result: Dictionary = gateway.SetEngagementStance(workers, "ReturnToBase", human)
	var order_ids: Array = []
	for entry in stance_result["unit_results"]:
		order_ids.append(String(entry["order_id"]))

	var started_ms := Time.get_ticks_msec()
	var arrived := 0
	var retry_alive := 900
	while retry_alive > 0:
		await get_tree().physics_frame
		retry_alive -= 1
		arrived = 0
		var all_terminal := true
		for order_id in order_ids:
			var state: String = gateway.GetOrderState(order_id)
			if state == "Arrived":
				arrived += 1
			elif not state in ["Unreachable", "TargetLost", "Cancelled", "UnitLost"]:
				all_terminal = false
		if all_terminal:
			break
		# 已抵达的持续姿态会保留订单，用位置判定收敛。
		if arrived == workers.size():
			break
		if arrived > 0 and _all_workers_at_base(workers, base):
			break
	var elapsed_ms := Time.get_ticks_msec() - started_ms
	var at_base := 0
	var rally_distance := _base_rally_distance(base, workers)
	for worker in workers:
		if _planar_distance(worker.global_position, base.global_position) <= rally_distance:
			at_base += 1
	var min_separation := _min_pairwise_separation(workers)
	_check(at_base >= 7, "集体回基地应至少 7/8 抵达基地附近（实际 %d）" % at_base)
	_check(min_separation >= MIN_SEPARATION_M, "回基地后不得互相叠住（最小间距 %.2fm）" % min_separation)
	print(
		"[MOVEMENT] group-return arrived=%d/8 at_base=%d min_sep=%.2f elapsed_ms=%d stats=%s"
		% [arrived, at_base, min_separation, elapsed_ms, MovementScript.recovery_stats]
	)
	for worker in workers:
		_remove_unit(worker)
	_remove_unit(base)


# --- 场景 4：行进中新建建筑 ---

func _scenario_building_added_mid_move(match_instance, human, gateway, tank: Node3D) -> void:
	_clear_wall()
	await _wait_frames(20)
	var start: Vector3 = tank.global_position
	# 目标保持在导航网格内（地图 54x54，只能沿 +x 拉开距离）。
	# 【2026-09-30】距离必须按"砖 footprint + carve 带 + 坦克半径"推导：砖盖在
	# start.x+9 时自己就挖出 9.8m 的洞，写死 18m 的目标正好落进洞里（实测误差 19.4m）。
	var step: float = (
		_scene_body_radius(CommandCenterScene)
		+ _navmesh_agent_radius(match_instance)
		+ float(tank.body_radius())
	)
	var target := Vector3(start.x + step * 2.0, 0.0, start.z)
	var started_ms := Time.get_ticks_msec()
	var result: Dictionary = gateway.MoveUnits([tank], target, human)
	var order_id := _order_id(result)
	# 让单位先跑起来，再在它的前方"突然"盖楼（触发运行时导航重烘）。
	await _wait_frames(30)
	for index in range(3):
		_spawn_wall_block(match_instance, human, start.x + step, start.z - 3.0 + float(index) * 3.0)
	var state := await _wait_terminal_order(gateway, order_id, 2400)
	var elapsed_ms := Time.get_ticks_msec() - started_ms
	var planar := _planar_distance(tank.global_position, target)
	_check(state == "Arrived", "重烘导航网格期间单位不得站桩，必须到达（state=%s）" % state)
	_check(planar <= ARRIVAL_TOLERANCE_M, "新建建筑后到达误差应合理（%.2fm）" % planar)
	print(
		"[MOVEMENT] building-mid-move state=%s elapsed_ms=%d planar_err=%.2f stats=%s"
		% [state, elapsed_ms, planar, MovementScript.recovery_stats]
	)
	_clear_wall()


# --- 场景 5：脱困期间玩家改命令 ---

func _scenario_player_override_during_recovery(match_instance, human, gateway, tank: Node3D) -> void:
	_clear_wall()
	# 制造真实拥堵：一队单位抢同一个落点，且必须挤过同一个窄口（脱困会在此过程中被触发）。
	var original: Vector3 = tank.global_position
	# 窄口宽度按**当前尺度**推导（见 `JAM_GAP_SLACK_M` 的注释）：上下两排砖的内缘
	# 之间留出 `2×(坦克半径 + 余量)`，两侧各自再排 3 块、间隔 `2r`。
	# 【2026-09-30】可通行半宽必须叠加 navmesh carve 带，否则缺口被 carve 糊死。
	var block_r := _scene_body_radius(CommandCenterScene)
	var nav_band := _navmesh_agent_radius(match_instance)
	var gap_half: float = nav_band + tank.body_radius() + JAM_GAP_SLACK_M
	var standoff := maxf(block_r + nav_band + tank.body_radius() + WALL_STANDOFF_SLACK_M, 1.0)
	var wall_x: float = original.x + standoff
	for index in range(3):
		_spawn_wall_block(match_instance, human, wall_x,
			original.z - gap_half - block_r - float(index) * block_r * 2.0)
	for index in range(3):
		_spawn_wall_block(match_instance, human, wall_x,
			original.z + gap_half + block_r + float(index) * block_r * 2.0)
	await _wait_frames(45)

	var crowd: Array = [tank]
	for index in range(5):
		crowd.append(
			_spawn_unit(
				match_instance,
				human,
				WorkerScene,
				Vector3(original.x - 1.5, 0.0, original.z - 3.0 + float(index) * 1.5)
			)
		)
	await _wait_frames(5)
	gateway.SetFirePolicy(crowd, "HoldFire", human)

	var jam_target := Vector3(wall_x + standoff, 0.0, original.z)
	var jam_orders: Dictionary = gateway.MoveUnits(crowd, jam_target, human)
	var tank_jam_order := _order_id(jam_orders)
	var before_detections: int = MovementScript.recovery_stats["stall_detections"]
	await _wait_frames(180)
	var after_detections: int = MovementScript.recovery_stats["stall_detections"]

	# 拥堵仍在进行时玩家改命令：新命令必须立刻接管。
	var movement = tank.find_child("Movement")
	var recover_target := Vector3(original.x - 10.0, 0.0, original.z + 6.0)
	var override: Dictionary = gateway.MoveUnits([tank], recover_target, human)
	var override_order := _order_id(override)
	await _wait_frames(3)
	var released: bool = String(movement.get("_recovery_mode")) == ""
	_check(released, "玩家新命令必须立刻撤销进行中的脱困状态")
	var override_state := await _wait_terminal_order(gateway, override_order, 2400)
	var jammed_state: String = gateway.GetOrderState(tank_jam_order)
	var planar := _planar_distance(tank.global_position, recover_target)
	_check(override_state == "Arrived", "玩家新命令必须正常到达（state=%s）" % override_state)
	_check(planar <= ARRIVAL_TOLERANCE_M, "新命令到达误差应合理（%.2fm）" % planar)
	# 关键：旧目标不得复活。命令层是否把旧订单对象置为 Cancelled 属另一层语义，
	# 这里直接验证"单位最终没有按旧任务走"（位置在 3m 之外）。
	_check(
		_planar_distance(tank.global_position, jam_target) > 3.0,
		"被替换的旧移动任务不得复活（dist_to_old_target=%.2f）"
		% _planar_distance(tank.global_position, jam_target)
	)
	print(
		"[MOVEMENT] override new=%s old=%s planar_err=%.2f recovery_mode=%s detections=%d→%d"
		% [
			override_state, jammed_state, planar,
			String(movement.get("_recovery_mode")), before_detections, after_detections
		]
	)
	for unit in crowd:
		if unit != tank:
			_remove_unit(unit)
	_clear_wall()


# --- 工具 ---

func _spawn_wall_block(match_instance, human, x: float, z: float) -> void:
	var block: Node3D = _spawn_unit(
		match_instance, human, CommandCenterScene, Vector3(x, 0.0, z)
	)
	_wall.append(block)


func _clear_wall() -> void:
	for block in _wall:
		_remove_unit(block)
	_wall.clear()


func _spawn_unit(match_instance, player, scene, position: Vector3) -> Node3D:
	var unit: Node3D = scene.instantiate()
	match_instance.call(
		"_setup_and_spawn_unit", unit, Transform3D(Basis.IDENTITY, position), player, false
	)
	return unit


func _remove_unit(unit) -> void:
	if unit != null and is_instance_valid(unit):
		unit.queue_free()


func _order_and_wait(gateway, units: Array, target: Vector3, human, max_frames: int) -> String:
	var result: Dictionary = gateway.MoveUnits(units, target, human)
	return await _wait_terminal_order(gateway, _order_id(result), max_frames)


func _wait_terminal_order(gateway, order_id: String, max_frames: int) -> String:
	var state := ""
	for _frame in range(max_frames):
		await get_tree().physics_frame
		state = gateway.GetOrderState(order_id)
		if state in ["Arrived", "Unreachable", "Cancelled", "TargetLost", "UnitLost"]:
			return state
	return state


func _order_id(result: Dictionary, index := 0) -> String:
	var unit_results: Array = result.get("unit_results", [])
	if index >= unit_results.size():
		return ""
	return String(unit_results[index].get("order_id", ""))


func _base_rally_distance(base: Node3D, workers: Array) -> float:
	## 集结判据（米）= 基地半径 + 归队单位半径 + 余量。取不到半径时退回旧常量口径。
	var unit_radius := 0.0
	for worker in workers:
		if is_instance_valid(worker) and worker.has_method("body_radius"):
			unit_radius = maxf(unit_radius, float(worker.call("body_radius")))
			break
	if base == null or not base.has_method("body_radius") or unit_radius <= 0.0:
		return 4.5
	# 【2026-09-30 同步口径】基地把单位顶在 carve 洞之外（洞 = 基地半径 + navmesh.agent_radius），
	# 所以「在基地附近」的判据必须覆盖 carve 净空，否则单位明明到了也被判成没到（实测 8/8 Arrived 但 at_base=0）。
	var clearance: float = Utils.Match.Unit.Movement.carve_clearance_of(base)
	return maxf(float(base.call("body_radius")) + unit_radius + BASE_APPROACH_SLACK_M, clearance + unit_radius + BASE_APPROACH_SLACK_M)


func _all_workers_at_base(workers: Array, base: Node3D) -> bool:
	var rally := _base_rally_distance(base, workers)
	for worker in workers:
		if not is_instance_valid(worker):
			return false
		if _planar_distance(worker.global_position, base.global_position) > rally:
			return false
	return true


func _min_pairwise_separation(units: Array) -> float:
	var minimum := INF
	for first in range(units.size()):
		for second in range(first + 1, units.size()):
			if not (is_instance_valid(units[first]) and is_instance_valid(units[second])):
				continue
			minimum = minf(minimum, _planar_distance(units[first].global_position, units[second].global_position))
	return 0.0 if minimum == INF else minimum


func _planar_distance(first: Vector3, second: Vector3) -> float:
	return Vector2(first.x, first.z).distance_to(Vector2(second.x, second.z))


func _wait_frames(count: int) -> void:
	for _frame in range(count):
		await get_tree().physics_frame


func _check(condition: bool, message: String) -> void:
	if condition:
		return
	_failures += 1
	push_error("Movement recovery assertion failed: %s" % message)
