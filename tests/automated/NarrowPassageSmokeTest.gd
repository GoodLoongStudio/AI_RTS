extends Node

## 真实 Match 窄通道验收：两座矩形建筑的包含圆会挡住坦克，
## 但真实 Box 脚印 + 0.10m 净空可以通过。验证窄阶段只短时缩小
## Movement.radius，并在到达/新命令后恢复，不修改 CollisionShape3D。

const SmokeTestWarmup = preload("res://tests/automated/SmokeTestWarmup.gd")
const MatchScene = preload("res://tests/manual/TestOneUnit.tscn")
const FactoryScene = preload("res://source/match/units/VehicleFactory.tscn")
const MovementScript = preload("res://source/match/units/traits/Movement.gd")

var _failures := 0
var _buildings: Array[Node3D] = []
const SCREENSHOT_DIR := "res://agent/runs/2026-10-02-navigation-narrow-passage/screenshots"


func _ready() -> void:
	var match_instance: Node = MatchScene.instantiate()
	add_child(match_instance)
	await SmokeTestWarmup.wait_for_units(get_tree(), 1)

	var human: Node = match_instance.get_node("Players/Human")
	var tank: Node3D = human.get_node("Tank")
	var gateway: Node = human.get_node("UnitCommandGateway")
	var movement: Node = tank.get_node("Movement")
	await SmokeTestWarmup.wait_for_navigation(get_tree(), movement, tank.global_position)

	# 关闭这两座夹具自身的 nav carve，专门观察 Movement 的真实形状推出层；
	# 它们仍注册为静态障碍，不能绕过碰撞几何。
	var center_z := tank.global_position.z
	var wall_x := tank.global_position.x + 11.0
	_spawn_factory(match_instance, human, Vector3(wall_x, 0.0, center_z - 4.5))
	_spawn_factory(match_instance, human, Vector3(wall_x, 0.0, center_z + 4.5))
	await _wait_frames(45)
	var hud := match_instance.get_node_or_null("HUD")
	if hud != null:
		hud.visible = false
	var fog := match_instance.get_node_or_null("FogOfWar")
	if fog != null:
		fog.visible = false

	gateway.SetFirePolicy([tank], "HoldFire", human)
	var base_radius := float(movement.radius)
	var target := Vector3(wall_x + 12.0, 0.0, center_z)
	var result: Dictionary = gateway.MoveUnits([tank], target, human)
	var order_id := _order_id(result)
	print("[NARROW-SETUP] start=(%.2f,%.2f) target=(%.2f,%.2f) movement_target=%s committed=%s next=%s path=%s" % [
		tank.global_position.x, tank.global_position.z, target.x, target.z,
		str(movement.target_position), str(movement.get("_committed_target")),
		str(movement.get_next_path_position()), str(movement.get_current_navigation_path())])
	for fixture in _buildings:
		var fixture_obstacle := fixture.get_node_or_null("MovementObstacle")
		print("[NARROW-SETUP] fixture=%s pos=(%.2f,%.2f) affect=%s avoidance=%s radius=%s" % [
			fixture.name, fixture.global_position.x, fixture.global_position.z,
			str(fixture_obstacle.get("affect_navigation_mesh")) if fixture_obstacle != null else "<none>",
			str(fixture_obstacle.get("avoidance_enabled")) if fixture_obstacle != null else "<none>",
			str(fixture_obstacle.get("radius")) if fixture_obstacle != null else "<none>"])
	var entered := false
	var min_radius := base_radius
	# 【2026-10-02 第 1 轮补强】min_hull_gap 不再写死：每帧按"单位真实地面 hull ↔ 两座工厂真实 Box 面"实测。
	var min_hull_gap := 1.0e9
	var exit_frame := -1
	var entered_frame := -1
	var restored_after_enter := false
	var terminal := ""
	var screenshot_taken := false
	for frame in range(2400):
		await get_tree().physics_frame
		if frame % 180 == 0:
			print("[NARROW-PASS-POS] frame=%d pos=(%.2f,%.2f) next=(%.2f,%.2f) final=(%.2f,%.2f) nav_finished=%s reachable=%s mode=%s radius=%.2f order=%s" % [
				frame, tank.global_position.x, tank.global_position.z,
				movement.get_next_path_position().x, movement.get_next_path_position().z,
				movement.get_final_position().x, movement.get_final_position().z,
				str(movement.is_navigation_finished()), str(movement.is_target_reachable()),
				String(movement.get("_recovery_mode")),
				float(movement.radius), String(gateway.GetOrderState(order_id))])
		var current_radius := float(movement.radius)
		min_radius = minf(min_radius, current_radius)
		min_hull_gap = minf(min_hull_gap, _measured_hull_gap(tank))
		if movement.get("_narrow_pass_saved_radius") != null and float(movement.get("_narrow_pass_saved_radius")) >= 0.0:
			entered = true
			if entered_frame < 0:
				entered_frame = frame
				await _save_narrow_screenshot(wall_x, center_z, "narrow_pass_active.png")
				screenshot_taken = true
		elif entered_frame >= 0 and frame > entered_frame + 3 and absf(current_radius - base_radius) <= 0.02:
			restored_after_enter = true
		terminal = String(gateway.GetOrderState(order_id))
		if terminal in ["Arrived", "Unreachable", "Cancelled", "TargetLost", "UnitLost"]:
			exit_frame = frame
			break

	_check(entered, "真实 Match 窄口必须至少进入一次 narrow_pass（stats=%s）" % str(MovementScript.recovery_stats))
	_check(min_radius <= base_radius * 0.81, "窄阶段必须实际收紧 Movement.radius（%.3f→%.3f）" % [base_radius, min_radius])
	_check(terminal == "Arrived", "真实形状可通过的窄口必须到达（state=%s）" % terminal)
	_check(absf(float(movement.radius) - base_radius) <= 0.02, "终态必须恢复原 Movement.radius")
	_check(restored_after_enter or terminal == "Arrived", "窄阶段超时/到达后必须恢复半径")
	_check(_planar_distance(tank.global_position, target) <= 2.0, "窄口到达误差应合理（%.2fm）" % _planar_distance(tank.global_position, target))

	var before_override := float(movement.radius)
	var override_target := tank.global_position + Vector3(-3.0, 0.0, 0.0)
	var override_result: Dictionary = gateway.MoveUnits([tank], override_target, human)
	await _wait_frames(4)
	_check(absf(float(movement.radius) - base_radius) <= 0.02, "新命令不得继承窄阶段缩小半径（before=%.3f）" % before_override)
	var override_state := await _wait_terminal(gateway, _order_id(override_result), 600)
	_check(override_state == "Arrived", "窄阶段结束后普通短移动仍应到达（state=%s）" % override_state)

	print("[NARROW-PASS] state=%s entered=%s min_radius=%.3f base_radius=%.3f restored=%s stats=%s" % [
		terminal, entered, min_radius, base_radius, restored_after_enter, str(MovementScript.recovery_stats)])
	# 【2026-10-02 第 1 轮补强】几何量全部**实测**（此前是写死的字符串 ✗）。
	var geometry := _measure_gap_geometry(tank, base_radius)
	var payload := {
		"unit": "Tank",
		"shape": "VehicleFactory Box + Tank Cylinder",
		"circle_clearance": geometry.get("circle_clearance_m", 0.0),
		"circle_verdict": geometry.get("circle_verdict", "unknown"),
		"shape_clearance": geometry.get("shape_clearance_m", 0.0),
		"shape_verdict": geometry.get("shape_verdict", "unknown"),
		"unit_ground_half_m": geometry.get("unit_half_m", 0.0),
		"gap_half_m": geometry.get("gap_half_m", 0.0),
		"entered": entered,
		"restored": absf(float(movement.radius) - base_radius) <= 0.02,
		"terminal_state": terminal,
		"min_hull_gap": (min_hull_gap if min_hull_gap < 1.0e8 else -1.0),
		"elapsed_frames": (exit_frame if exit_frame >= 0 else 2400),
		"stats": MovementScript.recovery_stats,
		"screenshot_taken": screenshot_taken,
	}
	var file := FileAccess.open("res://tmp_logs/narrow_passage_probe.json", FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(payload, "  "))
		file.close()

	_clear_buildings()
	match_instance.queue_free()
	await get_tree().process_frame
	print("Narrow passage smoke test completed: %d failure(s)" % _failures)
	SmokeTestExit.request(get_tree(), 0 if _failures == 0 else 1)


## 沿 dir（XZ）方向的**盒面 + 单位 hull** 净空：净空 = 到盒中心的投影距离 − 盒在该轴的半宽 − 单位 hull 半宽。
## 【修正】此前用"盒子最大半宽"（含长轴 ✗）导致净空被低估约 1m ⇒ 必须按**通道轴**取 ✓。
func _obb_clearance_along(unit: Node3D, box_node: Node3D, dir: Vector2, unit_half: float) -> float:
	var to := Vector2(unit.global_position.x - box_node.global_position.x,
		unit.global_position.z - box_node.global_position.z)
	var proj := absf(to.dot(dir))
	var half_along := 0.0
	for child in box_node.find_children("*", "CollisionShape3D", true, false):
		var cs := child as CollisionShape3D
		if cs != null and cs.shape is BoxShape3D:
			var b := cs.shape as BoxShape3D
			var xf: Transform3D = cs.global_transform
			var local_dir := xf.basis.inverse() * Vector3(dir.x, 0.0, dir.y)
			half_along = maxf(half_along, absf(local_dir.x) * b.size.x * 0.5 + absf(local_dir.z) * b.size.z * 0.5)
	return proj - half_along - unit_half


## 单位"真实地面 hull"沿 +X 的半宽（碰撞形状与近地视觉取大者）；用于一切净空判定。
func _unit_ground_half(unit: Node3D) -> float:
	var half := 0.0
	for child in unit.find_children("*", "CollisionShape3D", true, false):
		var cs := child as CollisionShape3D
		if cs == null or cs.shape == null or cs.disabled:
			continue
		if cs.shape is CylinderShape3D:
			half = maxf(half, (cs.shape as CylinderShape3D).radius)
		elif cs.shape is BoxShape3D:
			var b := cs.shape as BoxShape3D
			half = maxf(half, maxf(b.size.x, b.size.z) * 0.5)
		elif cs.shape is CapsuleShape3D:
			half = maxf(half, (cs.shape as CapsuleShape3D).radius)
	if half <= 0.0:
		half = float(unit.get("radius"))
	return half


## 逐帧实测：单位 hull 表面到两座工厂真实 Box 面的最小间隙（= min_hull_gap 的来源 ✓）。
func _measured_hull_gap(unit: Node3D) -> float:
	# 【修正 2】改用**真实的"圆心到矩形最近点"距离**再减单位 hull 半宽 ✓：
	# 一维投影在建筑拐角处会失真（实测出现 −0.159m 的假穿模 ✗）。
	var half_u := _unit_ground_half(unit)
	var best := 1.0e9
	var p2 := Vector2(unit.global_position.x, unit.global_position.z)
	for b in _buildings:
		if b == null or not is_instance_valid(b):
			continue
		for child in b.find_children("*", "CollisionShape3D", true, false):
			var cs := child as CollisionShape3D
			if cs == null or not (cs.shape is BoxShape3D):
				continue
			var box := cs.shape as BoxShape3D
			var xf: Transform3D = cs.global_transform
			var local := xf.affine_inverse() * Vector3(p2.x, xf.origin.y, p2.y)
			var h := box.size * 0.5
			var clamped := Vector3(clampf(local.x, -h.x, h.x), 0.0, clampf(local.z, -h.z, h.z))
			var world: Vector3 = xf * clamped
			var dist := Vector2(world.x - p2.x, world.z - p2.y).length()
			best = minf(best, dist - half_u)
	return best


## 几何对照：同一通道下，"包含圆口径"与"真实形状口径"的净空各是多少（实测 ✓）。
func _measure_gap_geometry(unit: Node3D, base_radius: float) -> Dictionary:
	var half_u := _unit_ground_half(unit)
	var out := {"unit_half_m": half_u, "gap_half_m": 0.0,
		"circle_clearance_m": 0.0, "shape_clearance_m": 0.0,
		"circle_verdict": "unknown", "shape_verdict": "unknown"}
	if _buildings.size() < 2:
		return out
	var a: Node3D = _buildings[0]
	var b: Node3D = _buildings[1]
	# 通道轴 = 两座工厂的连线方向（本夹具为 ±Z ✓）
	var axis := Vector2(b.global_position.x - a.global_position.x, b.global_position.z - a.global_position.z)
	if axis.length() < 0.0001:
		axis = Vector2.RIGHT
	axis = axis.normalized()
	var gap_half := _planar_distance(a.global_position, b.global_position) * 0.5
	var box_half := 0.0
	var contain_half := 0.0
	for child in a.find_children("*", "CollisionShape3D", true, false):
		var cs := child as CollisionShape3D
		if cs != null and cs.shape is BoxShape3D:
			var bb := cs.shape as BoxShape3D
			var xf: Transform3D = cs.global_transform
			var ld := xf.basis.inverse() * Vector3(axis.x, 0.0, axis.y)
			box_half = maxf(box_half, absf(ld.x) * bb.size.x * 0.5 + absf(ld.z) * bb.size.z * 0.5)
	if box_half <= 0.0:
		var ob := a.get_node_or_null("MovementObstacle")
		if ob != null and ob.get("radius") != null:
			contain_half = float(ob.get("radius"))
	var circle_half := contain_half if contain_half > 0.0 else box_half
	out["gap_half_m"] = gap_half
	out["circle_clearance_m"] = gap_half - circle_half - base_radius
	out["shape_clearance_m"] = gap_half - box_half - half_u
	out["circle_verdict"] = "blocked" if float(out["circle_clearance_m"]) < 0.0 else "pass"
	out["shape_verdict"] = "pass" if float(out["shape_clearance_m"]) >= 0.10 else "blocked"
	return out


func _spawn_factory(match_instance: Node, human: Node, position: Vector3) -> void:
	var factory: Node3D = FactoryScene.instantiate()
	var obstacle := factory.get_node_or_null("MovementObstacle")
	if obstacle != null:
		obstacle.affect_navigation_mesh = false
		# 夹具只用于验证 Movement 的静态形状推出；引擎 NavigationObstacle3D
		# 的 RVO 避让会把两个建筑重新扩大成动态圆形口径，掩盖本测试要验证的层。
		obstacle.avoidance_enabled = false
	match_instance.call("_setup_and_spawn_unit", factory, Transform3D(Basis.IDENTITY, position), human, false)
	# 夹具不参与 nav carve，但仍必须进入持久静态障碍注册表，
	# 这样测试覆盖的是 Movement 的真实脚印推出层，而不是空地直线。
	if obstacle != null:
		obstacle.add_to_group(Constants.Match.Navigation.DOMAIN_TO_OBSTACLE_GROUP_MAPPING[Constants.Match.Navigation.Domain.TERRAIN])
	_buildings.append(factory)


func _clear_buildings() -> void:
	for building in _buildings:
		if is_instance_valid(building):
			building.queue_free()
	_buildings.clear()


func _order_id(result: Dictionary) -> String:
	var rows: Array = result.get("unit_results", [])
	return String(rows[0].get("order_id", "")) if not rows.is_empty() else ""


func _wait_terminal(gateway: Node, order_id: String, max_frames: int) -> String:
	var state := ""
	for _frame in range(max_frames):
		await get_tree().physics_frame
		state = String(gateway.GetOrderState(order_id))
		if state in ["Arrived", "Unreachable", "Cancelled", "TargetLost", "UnitLost"]:
			return state
	return state


func _wait_frames(count: int) -> void:
	for _frame in range(count):
		await get_tree().physics_frame


func _save_narrow_screenshot(wall_x: float, center_z: float, file_name: String) -> void:
	var camera := Camera3D.new()
	camera.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	add_child(camera)
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 18.0
	var focus := Vector3(wall_x, 0.0, center_z)
	camera.global_position = focus + Vector3(0.0, 13.0, 13.0)
	camera.look_at(focus, Vector3.UP)
	camera.current = true
	await get_tree().process_frame
	await get_tree().process_frame
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(SCREENSHOT_DIR))
	var path := SCREENSHOT_DIR + "/" + file_name
	var viewport_texture := get_viewport().get_texture()
	if viewport_texture == null:
		print("[NARROW-SHOT] skipped: headless renderer has no viewport texture path=%s" % path)
		camera.queue_free()
		await get_tree().process_frame
		return
	var image: Image = viewport_texture.get_image()
	var err := image.save_png(path)
	print("[NARROW-SHOT] path=%s err=%d size=%dx%d" % [path, err, image.get_width(), image.get_height()])
	camera.queue_free()
	await get_tree().process_frame


func _planar_distance(first: Vector3, second: Vector3) -> float:
	return Vector2(first.x, first.z).distance_to(Vector2(second.x, second.z))


func _check(condition: bool, message: String) -> void:
	if condition:
		return
	_failures += 1
	push_error("Narrow passage assertion failed: %s" % message)
