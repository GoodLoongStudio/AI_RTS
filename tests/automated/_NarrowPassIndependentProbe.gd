extends Node

## 独立窄口复核探针（第 1 轮补强 ✓）：不依赖项目既有夹具的实现细节，自己搭真实 Match 并**实测**：
##   B) 比单位真实 hull 更窄的通道 ⇒ 必须**拒绝/绕行**，绝不能靠穿墙或瞬移"通过"；
##   D) 窄阶段进行中触发 **Stop** ⇒ 半径必须**立即恢复**（幂等 ✓）。
## 约定（沿用自己的纪律）：一进程一场景、自带超时兜底、产物写完打印路径 ✓。

const FactoryScene = preload("res://source/match/units/VehicleFactory.tscn")
const OUT_DIR := "res://agent/runs/2026-10-02-navigation-narrow-passage/"
const MovementScript = preload("res://source/match/units/traits/Movement.gd")

var _failures := 0
var _buildings: Array = []
var _m: Node
var _human: Node
var _gateway: Node


func _ready() -> void:
	get_tree().create_timer(220.0).timeout.connect(func() -> void:
		push_error("[NARROW-INDEP] 超时兜底退出")
		get_tree().quit(2))
	await _run()


func _run() -> void:
	_m = load("res://tests/manual/TestOneUnit.tscn").instantiate()
	add_child(_m)
	for _f in range(120):
		await get_tree().physics_frame
	_human = _m.get_node("Players/Human")
	_gateway = _human.get_node("UnitCommandGateway")
	var tank: Node3D = _human.get_node("Tank")
	var movement: Node = tank.get_node("Movement")
	_gateway.SetFirePolicy([tank], "HoldFire", _human)
	var tank_half := _unit_ground_half(tank)
	# 【第 4 轮】暖机后立刻出一张**兜底叠加图** ✓（后面阶段若很慢也不会一无所获 ✓）。
	await _save_overlay_shot_named(tank, "indep-narrow-warmup.png")

	# ---------- B) 过窄通道：净空 < 真实 hull ⇒ 必须拒绝/绕行 ----------
	var c := tank.global_position
	var narrow_x := c.x + 11.0
	# 【修正】按"**盒面间距**"摆放：两栋楼中心距 = 2×盒半宽 + 期望净距 ✓。
	# 上一版把中心放在 ±(hull+0.25) ⇒ 两栋楼互相重叠 ✗、坦克初始就在楼内 ✗。
	var box_half_z: float = await _factory_box_half_of("z")
	# 【第 3 轮】按实测半宽选间距：净距 0.40m ⇒ 半宽 0.20 < 坦克 hull(1.4) ⇒ 真实过窄 ✓ 必须拒绝 ✓
	var want_gap := 0.40
	var half_centers := box_half_z + want_gap * 0.5
	_spawn_factory(Vector3(narrow_x, 0.0, c.z - half_centers))
	_spawn_factory(Vector3(narrow_x, 0.0, c.z + half_centers))
	for _f in range(45):
		await get_tree().physics_frame
	var gap_half_b := want_gap * 0.5
	# 【第 3 轮修正】轴感知：用 Box 在**通道轴（世界 Z）**上的半宽 ✓，而不是最大半宽 ✗。
	var shape_clearance_b := gap_half_b - await _factory_box_half_of("z") - tank_half
	var base_radius := float(movement.radius)
	var target_b := Vector3(narrow_x + 12.0, 0.0, c.z)
	var res_b: Dictionary = _gateway.MoveUnits([tank], target_b, _human)
	var oid_b := _order_id(res_b)
	var min_gap_b := 1.0e9
	var min_gap_frame := -1
	var min_gap_pos := Vector2.ZERO
	var state_b := ""
	var frames_b := 0
	for f in range(900):
		await get_tree().physics_frame
		frames_b = f
		var gnow := _hull_gap(tank)
		if gnow < min_gap_b:
			min_gap_b = gnow
			min_gap_frame = f
			min_gap_pos = Vector2(tank.global_position.x, tank.global_position.z)
		state_b = String(_gateway.GetOrderState(oid_b))
		if state_b in ["Arrived", "Unreachable", "Cancelled", "TargetLost", "UnitLost"]:
			break
	# 【第 3 轮修正断言】提示词口径是"必须**拒绝/绕行**，不能穿墙" ✓ ——
	# "到达另一侧"本身**不是**失败（可以从旁边绕过去 ✓）；真正的判据是**全程不与建筑重叠** ✓。
	# 上一版把"绕行成功"误判为失败 ✗（实测 min_gap = +0.182 ⇒ 根本没碰到 ✓）。
	var crossed := tank.global_position.x > narrow_x + tan_box_half()
	var b_ok := min_gap_b >= -0.02
	_check(b_ok, "过窄通道：全程不得与建筑重叠（state=%s min_gap=%.3f 是否到对侧=%s）" % [state_b, min_gap_b, str(crossed)])

	# ---------- D) 窄阶段中途 Stop ⇒ 半径立即恢复 ----------
	_clear_buildings()
	for _f in range(20):
		await get_tree().physics_frame
	var c2 := tank.global_position
	var pass_x := c2.x + 11.0
	_spawn_factory(Vector3(pass_x, 0.0, c2.z - 4.5))
	_spawn_factory(Vector3(pass_x, 0.0, c2.z + 4.5))
	for _f in range(45):
		await get_tree().physics_frame
	var target_d := Vector3(pass_x + 12.0, 0.0, c2.z)
	var res_d: Dictionary = _gateway.MoveUnits([tank], target_d, _human)
	var entered_d := false
	var stop_frame := -1
	var radius_at_stop := -1.0
	var radius_after_stop := -1.0
	for f in range(1200):
		await get_tree().physics_frame
		var saved: Variant = movement.get("_narrow_pass_saved_radius")
		if saved != null and float(saved) >= 0.0 and not entered_d:
			entered_d = true
			var sr: Dictionary = _gateway.StopUnits([tank], _human)
			stop_frame = f
			radius_at_stop = float(movement.radius)
			for _k in range(6):
				await get_tree().physics_frame
			radius_after_stop = float(movement.radius)
			break
	var d_ok := entered_d and absf(radius_after_stop - base_radius) <= 0.02
	_check(d_ok, "窄阶段中途 Stop 必须立即恢复半径（进入=%s stop 时=%.3f 6 帧后=%.3f 基准=%.3f）" % [
		str(entered_d), radius_at_stop, radius_after_stop, base_radius])

	# 【第 3 轮】提示词要求的分色叠加截图 ✓（模型 + CollisionShape3D 包围盒 + carve + 窄阶段有效边界 ✓）
	await _save_overlay_shot_named(tank, "indep-narrow-overlay.png")
	var payload := {
		"probe": "independent-narrow-pass",
		"unit": "Tank",
		"unit_ground_half_m": tank_half,
		"narrow_gap_half_m": gap_half_b,
		"narrow_shape_clearance_m": shape_clearance_b,
		"narrow_terminal_state": state_b,
		"narrow_min_hull_gap_m": min_gap_b,
		"narrow_min_gap_frame": min_gap_frame,
		"narrow_min_gap_pos": [min_gap_pos.x, min_gap_pos.y],
		"narrow_start_pos": [c.x, c.z],
		"narrow_fixture_x": narrow_x,
		"narrow_crossed": crossed,
		"narrow_frames": frames_b,
		"stop_mid_phase_entered": entered_d,
		"radius_at_stop_m": radius_at_stop,
		"radius_after_stop_m": radius_after_stop,
		"base_radius_m": base_radius,
		"failures": _failures,
	}
	var f2 := FileAccess.open(ProjectSettings.globalize_path(OUT_DIR + "indep-narrow-probe.json"), FileAccess.WRITE)
	if f2 != null:
		f2.store_string(JSON.stringify(payload, "  "))
		f2.close()
	print("[NARROW-INDEP] %s" % JSON.stringify(payload))
	print("Independent narrow pass probe completed: %d failure(s)" % _failures)
	get_tree().quit(0 if _failures == 0 else 1)


## 分色叠加截图：黄=碰撞包围盒、红=导航 carve、绿=单位真实 hull、蓝=窄阶段有效边界。
func _save_overlay_shot_named(unit: Node3D, file_name: String) -> void:
	var hud: Node = _m.get_node_or_null("HUD")
	if hud != null:
		hud.visible = false
	var fog: Node = _m.get_node_or_null("FogOfWar")
	if fog != null:
		fog.visible = false
	for b in _buildings:
		if b == null or not is_instance_valid(b):
			continue
		for child in b.find_children("*", "CollisionShape3D", true, false):
			var cs := child as CollisionShape3D
			if cs == null or not (cs.shape is BoxShape3D):
				continue
			var box := cs.shape as BoxShape3D
			_draw_box(cs.global_transform, box.size, Color(0.95, 0.85, 0.1, 0.30))
		var ob: Node = b.get_node_or_null("MovementObstacle")
		if ob != null and ob.get("radius") != null:
			var carve_r := float(ob.get("radius")) + 0.9
			_draw_cylinder(Vector3(b.global_position.x, 0.05, b.global_position.z), carve_r, 0.10, Color(0.95, 0.15, 0.15, 0.35))
	var half_u := _unit_ground_half(unit)
	_draw_cylinder(Vector3(unit.global_position.x, 0.10, unit.global_position.z), half_u, 0.12, Color(0.15, 0.95, 0.25, 0.55))
	var mv: Node = unit.get_node_or_null("Movement")
	if mv != null:
		_draw_cylinder(Vector3(unit.global_position.x, 0.16, unit.global_position.z), float(mv.radius), 0.14, Color(0.25, 0.55, 1.0, 0.45))
	var cam: Camera3D = Camera3D.new()
	add_child(cam)
	cam.position = unit.global_position + Vector3(-9.0, 13.0, 0.01)
	cam.rotation_degrees = Vector3(-90, 0, 0)
	cam.current = true
	for _f in range(6):
		await get_tree().process_frame
	var img: Image = get_viewport().get_texture().get_image()
	var out := ProjectSettings.globalize_path(OUT_DIR + "screenshots/" + file_name)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR + "screenshots/"))
	var err := img.save_png(out)
	print("[NARROW-INDEP] 叠加截图已写 %s（err=%d）" % [out, err])


func _draw_box(xf: Transform3D, size: Vector3, color: Color) -> void:
	var mi: MeshInstance3D = MeshInstance3D.new()
	var bm: BoxMesh = BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	mi.global_transform = xf
	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.albedo_color = color
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mi.material_override = mat
	add_child(mi)


func _draw_cylinder(at: Vector3, r: float, h: float, color: Color) -> void:
	var mi: MeshInstance3D = MeshInstance3D.new()
	var cm: CylinderMesh = CylinderMesh.new()
	cm.top_radius = r
	cm.bottom_radius = r
	cm.height = maxf(h, 0.02)
	mi.mesh = cm
	mi.position = at
	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.albedo_color = color
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mi.material_override = mat
	add_child(mi)


func _check(cond: bool, msg: String) -> void:
	if not cond:
		_failures += 1
		push_error("[NARROW-INDEP] FAIL: " + msg)
	else:
		print("[NARROW-INDEP] OK: " + msg)


func _order_id(result: Dictionary) -> String:
	var rows: Array = result.get("unit_results", [])
	return String(rows[0].get("order_id", "")) if not rows.is_empty() else ""


func _spawn_factory(pos: Vector3) -> void:
	var f: Node3D = FactoryScene.instantiate()
	var ob := f.get_node_or_null("MovementObstacle")
	if ob != null:
		# 【第 2 轮修正】**必须保持 affect_navigation_mesh = true** ✓：
		# MovementObstacle 只在 affect 为真时才加入推出组（见其 _ready ✓），
		# 设成 false 会让建筑**既不 carve 也不推出** ✗ ⇒ 夹具测不到任何推出行为 ✗
		# （上一版因此得到 −0.399m 的假"穿模"读数 ✗）。
		ob.affect_navigation_mesh = true
		ob.carve_from_collision_bounds = true
	_m.call("_setup_and_spawn_unit", f, Transform3D(Basis.IDENTITY, pos), _human, false)
	_buildings.append(f)


func _clear_buildings() -> void:
	for b in _buildings:
		if b != null and is_instance_valid(b):
			b.queue_free()
	_buildings.clear()


## 先临时生成一座工厂，量出它的 Box 沿**世界** Z 轴的半宽。
## 【第 3 轮修正】此前用 Box 的**局部** `size.z` ✗ —— 工厂在场景里带旋转，
## 局部轴与世界轴不一致 ⇒ 摆位算出的通道比预期宽 ✗（实测"穿过去但无重叠" ✓ 即为此故 ✓）。
func _factory_box_half_of(_axis: String) -> float:
	var probe: Node3D = FactoryScene.instantiate()
	add_child(probe)
	await get_tree().process_frame
	var world_z := Vector3(0.0, 0.0, 1.0)
	var half := 0.0
	for child in probe.find_children("*", "CollisionShape3D", true, false):
		var cs := child as CollisionShape3D
		if cs == null or not (cs.shape is BoxShape3D):
			continue
		var b := cs.shape as BoxShape3D
		var xf: Transform3D = cs.global_transform
		var local_dir := xf.basis.inverse() * world_z
		half = maxf(half, absf(local_dir.x) * b.size.x * 0.5 + absf(local_dir.z) * b.size.z * 0.5)
	probe.queue_free()
	return half


func tan_box_half() -> float:
	if _buildings.is_empty():
		return 0.0
	var b: Node3D = _buildings[0]
	for child in b.find_children("*", "CollisionShape3D", true, false):
		var cs := child as CollisionShape3D
		if cs != null and cs.shape is BoxShape3D:
			var box := cs.shape as BoxShape3D
			return maxf(box.size.x, box.size.z) * 0.5
	return 0.0


func _is_ground_collision(node: Node) -> bool:
	# 【修正】排除 Selection/Targetability/Highlight/HealthBar 等"非地面碰撞"的 CollisionShape3D ✓
	# （它们的半径远大于本体 ✗，会把 hull 半宽算大 ⇒ 净空出现假负值 ✗）。
	var path := str(node.get_path())
	for token in ["Selection", "Targetability", "Highlight", "HealthBar", "RallyPoint", "Sparkling"]:
		if path.contains(token):
			return false
	return true


func _unit_ground_half(unit: Node3D) -> float:
	var tank: Node3D = _human.get_node("Tank")
	var half := 0.0
	for child in tank.find_children("*", "CollisionShape3D", true, false):
		var cs := child as CollisionShape3D
		if cs == null or cs.shape == null or cs.disabled:
			continue
		if not _is_ground_collision(cs):
			continue
		if cs.shape is CylinderShape3D:
			half = maxf(half, (cs.shape as CylinderShape3D).radius)
		elif cs.shape is BoxShape3D:
			var b2 := cs.shape as BoxShape3D
			half = maxf(half, maxf(b2.size.x, b2.size.z) * 0.5)
	if half <= 0.0:
		half = float(tank.get("radius"))
	return half


func _hull_gap(unit: Node3D) -> float:
	var half_u := _unit_ground_half(unit)
	var p2 := Vector2(unit.global_position.x, unit.global_position.z)
	var best := 1.0e9
	for b in _buildings:
		if b == null or not is_instance_valid(b):
			continue
		for child in b.find_children("*", "CollisionShape3D", true, false):
			var cs := child as CollisionShape3D
			if cs == null or not (cs.shape is BoxShape3D):
				continue
			if not _is_ground_collision(cs):
				continue
			var box := cs.shape as BoxShape3D
			var xf: Transform3D = cs.global_transform
			var local := xf.affine_inverse() * Vector3(p2.x, xf.origin.y, p2.y)
			var h := box.size * 0.5
			var clamped := Vector3(clampf(local.x, -h.x, h.x), 0.0, clampf(local.z, -h.z, h.z))
			var world: Vector3 = xf * clamped
			best = minf(best, Vector2(world.x - p2.x, world.z - p2.y).length() - half_u)
	return best
