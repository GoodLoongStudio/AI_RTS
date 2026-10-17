extends Node

## 锁死"逻辑地形（生成图）上建筑足迹权威"的回归测试。
##
## 【2026-10-12 建筑卡单位根因】所有带 height_data_path 的地图都不烘导航网格
## （`Navigation.should_skip_runtime_navigation` 为真），于是 `GeneratedTerrain`
## 登记的结构足迹是这类图上**唯一**的"楼在哪"判据。旧实现只有一个圆，
## 还要再乘 `STRUCTURE_STAMP_RADIUS_SCALE=0.85`：
## 实测车厂 BoxShape3D=(7.944,3.672,6.108) ⇒ 半宽 3.972/3.054、角点 5.011，
## 而障碍 `radius=3.972` → 判定圆只有 3.376，于是
##   ① X 方向外墙 3.376~3.972 这段"楼里"被当成可走（欠 0.60m）；
##   ② 角点方向最多欠 1.64m ⇒ 单位被合法地送进楼体，卡死在墙角；
##   ③ Z 方向 3.054~3.376 这段真实楼外却被多禁 0.32m（工人贴不上墙）。
## 本测试同时判 ①②（新口径必须禁行）与 ③（新口径必须放行），
## 所以它**不是**"把范围放大就算过"——只放大或只缩小都会红。
## 另外判 `structure_approach_point` 在没有导航网格时必须仍然给出错开的落点：
## 旧实现在这里直接 return null，三辆矿车挤成同一个点
## （实测 `_RefineryJamProbe` 90s：交付=0、卡住 261.2s、三车全判 drop_overlap）。
const MAP_SCENE := "res://source/match/maps/PlainAndSimple.tscn"
const BASE := Vector3(120.0, 0.0, 96.0)
const MovementUtils = preload("res://source/match/utils/UnitMovementUtils.gd")
const PROBE_EPSILON_M := 0.2

var _failures := 0
var _m: Node = null
var _player: Node = null


func _ready():
	get_tree().create_timer(420.0).timeout.connect(func() -> void:
		push_error("[FOOTPRINT] 超时兜底退出")
		get_tree().quit(2))
	var settings = load("res://source/data-model/MatchSettings.gd").new()
	var hs = load("res://source/data-model/PlayerSettings.gd").new()
	hs.controller = Constants.PlayerType.HUMAN
	hs.color = Constants.Player.COLORS[0]
	settings.players.append(hs)
	settings.visible_player = 0
	_m = load("res://source/match/Match.tscn").instantiate()
	_m.settings = settings
	_m.map = load(MAP_SCENE).instantiate()
	add_child(_m)
	get_tree().current_scene = _m
	for _f in range(200):
		await get_tree().physics_frame
	_player = _m.get_node("Players").get_children()[0]
	var terrain: Node = _m.map.find_child("Terrain", true, false)
	if terrain == null or not terrain.has_method("is_ground_blocked"):
		_check(false, "夹具地图必须是逻辑地形并暴露 is_ground_blocked")
		_finish()
		return
	_check(Utils.Match.is_logic_terrain_map(_m.map), "夹具必须是逻辑地形（生成图口径）")
	await _run_footprint(terrain)
	await _run_approach(terrain)
	await _run_corner_drive(terrain)
	await _run_wedge_escape(terrain)
	_finish()


func _spawn(scene_name: String, at: Vector3) -> Node3D:
	var unit: Node3D = (load("res://source/match/units/%s.tscn" % scene_name) as PackedScene).instantiate()
	_m.call("_setup_and_spawn_unit", unit, Transform3D(Basis.IDENTITY, at), _player, false)
	return unit


func _run_footprint(terrain: Node) -> void:
	var factory := _spawn("VehicleFactory", BASE)
	for _f in range(60):
		await get_tree().physics_frame
	var shape: CollisionShape3D = factory.find_child("CollisionShape3D", true, false)
	_check(shape != null and shape.shape is BoxShape3D, "车厂必须是 BoxShape3D（本测试的判据前提）")
	if shape == null or not (shape.shape is BoxShape3D):
		return
	var half: Vector3 = (shape.shape as BoxShape3D).size * 0.5
	var center: Vector3 = factory.global_position * Vector3(1, 0, 1)
	print("[FOOTPRINT] 车厂半宽=%.3f/%.3f 角点=%.3f" % [
		half.x, half.z, Vector2(half.x, half.z).length()])
	# ① X 面：楼内 0.2m 必须禁行。旧圆口径在 3.376~3.972 这段放行 ⇒ 旧代码在此转红。
	_check(bool(terrain.is_ground_blocked(
		center + Vector3(half.x - PROBE_EPSILON_M, 0.0, 0.0))),
		"X 方向外墙内侧应判禁行（实测旧圆少禁 %.2fm）" % (half.x - _legacy_stamp_radius(half.x)))
	_check(not bool(terrain.is_ground_blocked(
		center + Vector3(half.x + PROBE_EPSILON_M, 0.0, 0.0))),
		"X 方向外墙外侧不应多禁")
	# ③ Z 面：真实楼外却曾被多禁 0.32m ⇒ 只放大不通过本条。
	_check(not bool(terrain.is_ground_blocked(
		center + Vector3(0.0, 0.0, half.z + PROBE_EPSILON_M))),
		"Z 方向外墙外侧应放行（旧圆在此多禁 %.2fm）" % (_legacy_stamp_radius(half.x) - half.z))
	# ② 角点：沿对角把两个半宽都推出去才算离开楼体。
	_check(bool(terrain.is_ground_blocked(center + Vector3(
		half.x - PROBE_EPSILON_M, 0.0, half.z - PROBE_EPSILON_M))),
		"墙角内侧应判禁行（旧圆沿角点最多欠 %.2fm）" % (Vector2(half.x, half.z).length()
			- _legacy_stamp_radius(half.x)))
	_check(not bool(terrain.is_ground_blocked(center + Vector3(
		half.x + PROBE_EPSILON_M, 0.0, half.z + PROBE_EPSILON_M))),
		"墙角外侧应放行")
	factory.queue_free()
	for _f in range(30):
		await get_tree().physics_frame


## 旧口径的判定圆半径（`MovementObstacle.radius × 0.85`），只为把实测差额打进日志。
func _legacy_stamp_radius(collider_half_x: float) -> float:
	return maxf(collider_half_x * 0.85, 1.15)


func _run_approach(terrain: Node) -> void:
	var factory := _spawn("VehicleFactory", BASE)
	var workers: Array = []
	# 三辆车故意放在**同一个起点**：这样"落点必须不同"只能靠车道错开实现，
	# 而不是靠它们本来就站在三个方向上（旧实现给不出落点，三车必然塌成楼心一点）。
	for i in 3:
		workers.append(_spawn("Worker", BASE + Vector3(-20.0, 0.0, 0.0)))
	for _f in range(60):
		await get_tree().physics_frame
	var points: Array = []
	for worker in workers:
		var point: Variant = MovementUtils.structure_approach_point(worker, factory)
		_check(point is Vector3, "逻辑地形必须给出建筑靠近落点（旧实现在此返回 null）")
		if point is Vector3:
			points.append(point)
			_check(not bool(terrain.is_ground_blocked(point as Vector3)),
				"靠近落点不得落在建筑足迹内")
			var gap := _collider_surface_gap(point as Vector3, factory)
			_check(gap > 0.0, "靠近落点应在真实外墙外（实测表面间隙 %.2fm）" % gap)
	_check(points.size() == 3, "三辆工人应各拿到一个落点")
	for i in range(points.size()):
		for j in range(i + 1, points.size()):
			_check((points[i] as Vector3).distance_to(points[j] as Vector3) > 0.5,
				"落点必须按车道错开（%.2fm 会被判成同一个目标 → drop_overlap）"
				% (points[i] as Vector3).distance_to(points[j] as Vector3))
	factory.queue_free()
	for worker in workers:
		worker.queue_free()


## 落点到车厂 BoxShape3D 表面的带符号平面距离（负=在盒内）。
func _collider_surface_gap(point: Vector3, factory: Node3D) -> float:
	var shape: CollisionShape3D = factory.find_child("CollisionShape3D", true, false)
	var half: Vector3 = (shape.shape as BoxShape3D).size * 0.5
	var origin: Vector3 = factory.global_position
	var inside_x := absf(point.x - origin.x) <= half.x
	var inside_z := absf(point.z - origin.z) <= half.z
	if inside_x and inside_z:
		return -minf(half.x - absf(point.x - origin.x), half.z - absf(point.z - origin.z))
	return Vector2(maxf(absf(point.x - origin.x) - half.x, 0.0),
		maxf(absf(point.z - origin.z) - half.z, 0.0)).length()


## 端到端行为判据：命令工人**直穿**车厂（目标在楼另一侧），逐帧采样"单位中心是否落在
## 碰撞盒里"。旧口径下判定圆只有 3.376m，X 面 3.376~3.972 那段被当成可走，
## 单位中心会被允许进入楼体 0.60m（沿角点 1.64m）并停在那里 ⇒ 用户看到的"卡在墙角"。
## 只断言几何不变量；"到底有没有绕过楼"按实测打印，不拿来当绿灯（图上没有导航网格，
## 直穿指令本来就只能贴着楼走，把它写成断言会把另一道专项混进本测试）。
func _run_corner_drive(terrain: Node) -> void:
	var factory := _spawn("VehicleFactory", BASE)
	var worker := _spawn("Worker", BASE + Vector3(-14.0, 0.0, 0.0))
	for _f in range(60):
		await get_tree().physics_frame
	var movement: Node = worker.find_child("Movement", true, false)
	movement.call("move", BASE + Vector3(14.0, 0.0, 0.0))
	var inside_frames := 0
	var deepest := 0.0
	for frame in range(480):
		await get_tree().physics_frame
		if frame % 6 != 0:
			continue
		var gap := _collider_surface_gap(worker.global_position, factory)
		if gap < 0.0:
			inside_frames += 1
			deepest = minf(deepest, gap)
	var planar_travel := Vector2(
		worker.global_position.x - BASE.x, worker.global_position.z - BASE.z).length()
	var blocked_now := bool(terrain.is_ground_blocked(worker.global_position))
	print("[FOOTPRINT] 直穿车厂 480 帧：中心在盒内 %d 帧，最深 %.2fm，终点离楼心 %.1fm，终点仍判禁行=%s"
		% [inside_frames, deepest, planar_travel, str(blocked_now)])
	_check(inside_frames == 0,
		"单位中心不得停在建筑碰撞盒内（实测 %d 帧、最深 %.2fm）" % [inside_frames, deepest])
	worker.queue_free()
	factory.queue_free()
	for _f in range(30):
		await get_tree().physics_frame


## 照抄用户 2026-10-12 截图的症状：坦克压在车厂西墙里（中心落在足迹内），
## 给它一条离开命令，要求它**自己脱困**并走到目的地。
## 这条测的是"卡住之后有没有出路"，与前面三条（足迹判得准不准）不同轴：
## 足迹判严之后，若脱困层不认新足迹，单位会因每一步都被判禁行而**冻在楼里**，
## 那比原来的"穿模"更糟 —— 所以这条必须单独判。
func _run_wedge_escape(terrain: Node) -> void:
	var factory := _spawn("VehicleFactory", BASE)
	var shape: CollisionShape3D = factory.find_child("CollisionShape3D", true, false)
	if shape == null or not (shape.shape is BoxShape3D):
		return
	var half: Vector3 = (shape.shape as BoxShape3D).size * 0.5
	# 中心放在西墙内侧 0.5m：车体必然与楼体重叠（截图就是这个状态）。
	var wedge_at := factory.global_position + Vector3(half.x - 0.5, 0.0, 0.0)
	var tank := _spawn("Tank", wedge_at)
	for _f in range(60):
		await get_tree().physics_frame
	_check(bool(terrain.is_ground_blocked(tank.global_position)),
		"夹具前提：坦克中心应确实压在车厂足迹内（截图状态）")
	var destination := factory.global_position + Vector3(-26.0, 0.0, 0.0)
	var movement: Node = tank.find_child("Movement", true, false)
	movement.call("move", destination)
	var escape_frame := -1
	for frame in range(600):
		await get_tree().physics_frame
		if escape_frame < 0 and not bool(terrain.is_ground_blocked(tank.global_position)):
			escape_frame = frame
	_check(escape_frame >= 0, "被压在楼里的坦克必须能自己脱困（600 帧内中心仍未离开足迹）")
	var arrived := Vector2(
		tank.global_position.x - destination.x,
		tank.global_position.z - destination.z).length()
	print("[FOOTPRINT] 楔入脱困：离开足迹用了 %d 帧（%.1fs），600 帧后离命令目标 %.2fm" % [
		escape_frame, escape_frame * 1.0 / float(Engine.physics_ticks_per_second), arrived])
	_check(arrived <= maxf(float(movement.get("radius")), 0.35) + 1.5,
		"脱困后应走到命令目标（实测差 %.2fm）" % arrived)
	tank.queue_free()
	factory.queue_free()
	for _f in range(30):
		await get_tree().physics_frame


func _check(passed: bool, message: String) -> void:
	if passed:
		return
	_failures += 1
	push_error("[FOOTPRINT] 断言失败: " + message)


func _finish() -> void:
	print("Logic terrain footprint regression: %d failure(s)" % _failures)
	get_tree().quit(1 if _failures > 0 else 0)
