extends Node

## 独立验证探针 #2（verifier 自写）：蓝图 ghost 世界尺寸 vs 真实落地建筑世界尺寸。
##
## 为什么不能只量"用 identity 变换直接 spawn 的建筑"：真实玩家放置走的是
##   Ra3Sidebar → MatchSignals.place_structure → StructurePlacementHandler._start_structure_placement
##   →（用户点击）_finish_structure_placement → C# StructurePlacementRuntime.Place(..., 蓝图.global_transform, ...)
##   → Match._setup_and_spawn_unit(structure, transform=蓝图的 global_transform, ...)
## 这条链上，蓝图节点在 _start_structure_placement 里被**乘过 Visual 缩放**（建筑 = 3.0），
## 而 _setup_and_spawn_unit 会整支套用传入的 Transform3D（含 scale）。本探针逐段实测这条链。
##
## 三段：
##   A 引理：同一个场景，identity 基 vs 缩放基（×3）交给 _setup_and_spawn_unit → 量落地 root scale
##   B 定理：走真实 handler 落地，量 落地建筑 root scale / 视觉世界尺寸，与 ghost、与 identity 参照对比
##   C 对照：炮塔类（Visual 缩放在几何子场景叶子、handler 读到的 Visual.scale = 1）重复 B

const MAP_SCENE := "res://source/match/maps/PlainAndSimple.tscn"
const BUILDING := "res://source/match/units/VehicleFactory.tscn"
const TURRET := "res://source/match/units/AntiGroundTurret.tscn"
const REPORT_PATH := "res://build/indep_verify/probe2_report.json"

var _match: Node = null
var _human: Node = null
var _handler: Node = null
var _runtime: Node = null
var _balance: Node = null
var _cc: Node3D = null
var _rows: Array = []


func _ready():
	var settings = load("res://source/data-model/MatchSettings.gd").new()
	var hs = load("res://source/data-model/PlayerSettings.gd").new()
	hs.controller = Constants.PlayerType.HUMAN
	hs.color = Constants.Player.COLORS[0]
	settings.players.append(hs)
	settings.visible_player = 0
	_match = load("res://source/match/Match.tscn").instantiate()
	_match.settings = settings
	_match.map = load(MAP_SCENE).instantiate()
	add_child(_match)
	get_tree().current_scene = _match
	var deadline := Time.get_ticks_msec() + 90000
	while Time.get_ticks_msec() < deadline:
		await get_tree().physics_frame
		var players: Node = _match.get_node_or_null("Players")
		if players == null or players.get_child_count() < 1:
			continue
		for sub in players.get_child(0).get_children():
			if sub is Node3D and sub.get_script() != null \
					and "CommandCenter" in str(sub.get_script().resource_path):
				_cc = sub
		if _cc != null:
			break
	if _cc == null:
		print("[IVR2] 对局未就绪：找不到 CommandCenter")
		_finish()
		return
	_human = _match.get_node("Players").get_children()[0]
	_handler = _human.get_node_or_null("StructurePlacementHandler")
	_runtime = _match.get_node_or_null("StructurePlacementRuntime")
	_balance = _match.get_node_or_null("BalanceConfigRuntime")
	print("[IVR2] handler=%s runtime=%s balance=%s" % [
		str(_handler != null), str(_runtime != null), str(_balance != null)])
	var injected: bool = _human.add_resources({"resource_a": 500000, "resource_b": 500000}, "ScriptedAdjustment")
	print("[IVR2] 资源注入=%s" % str(injected))
	await get_tree().physics_frame

	await _lemma_scaled_spawn()
	await _ghost_size_table()
	await _real_placement("building", BUILDING)
	await _real_placement("turret", TURRET)
	_finish()


## A 引理：同一场景两种基，直接走 Match._setup_and_spawn_unit。
func _lemma_scaled_spawn() -> void:
	var anchor: Vector3 = _cc.global_position + Vector3(0.0, 0.0, -40.0)
	for scale in [1.0, 3.0]:
		var unit: Node3D = load(BUILDING).instantiate()
		var t := Transform3D(Basis.IDENTITY.scaled(Vector3(scale, scale, scale)), anchor)
		_match.call("_setup_and_spawn_unit", unit, t, _human, false)
		await get_tree().physics_frame
		await get_tree().physics_frame
		var m := _measure_unit(unit)
		m["lemma_basis_scale"] = scale
		m["kind"] = "lemma_identity" if scale == 1.0 else "lemma_scaled"
		_rows.append(m)
		print("[IVR2] 引理 basis ×%.1f → root_local=%s root_global=%s visual_ws=%s coll_r=%s vis_out=%s" % [
			scale, _fmt(m["root_local_scale"]), _fmt(m["root_global_scale"]),
			_f(m["visual_world_scale"]), _f(m["collision_world_radius"]), _f(m["visual_outer_radius"])])
		unit.queue_free()
		await get_tree().process_frame


## 八栋建筑/炮塔的 ghost 世界尺寸 vs 参照建筑（identity 落地）世界尺寸。
## 只建蓝图不落地 —— 不会占用"一次一个工地"名额。
const ALL_STRUCTURES := [
	"res://source/match/units/CommandCenter.tscn",
	"res://source/match/units/VehicleFactory.tscn",
	"res://source/match/units/Barracks.tscn",
	"res://source/match/units/AircraftFactory.tscn",
	"res://source/match/units/OreRefinery.tscn",
	"res://source/match/units/AntiGroundTurret.tscn",
	"res://source/match/units/AntiAirTurret.tscn",
	"res://source/match/units/MachineGunTurret.tscn",
]


func _ghost_size_table() -> void:
	var reference_spot: Vector3 = _cc.global_position + Vector3(0.0, 0.0, -80.0)
	for scene_path in ALL_STRUCTURES:
		var reference: Node3D = load(scene_path).instantiate()
		_match.call("_setup_and_spawn_unit", reference,
			Transform3D(Basis.IDENTITY, reference_spot), _human, false)
		await get_tree().physics_frame
		var ref_m := _measure_unit(reference)
		reference.queue_free()
		await get_tree().process_frame
		_handler.call("_cancel_structure_placement")
		_handler.call("_start_structure_placement", load(scene_path))
		await get_tree().process_frame
		var ghost: Node3D = _handler.get("_active_blueprint_node")
		if ghost == null:
			print("[IVR2] ghost表 %s 蓝图未建立" % scene_path.get_file())
			continue
		var probe: Node3D = load(scene_path).instantiate()
		var proto_visual: Node = probe.get_node_or_null("Geometry")
		if proto_visual == null:
			proto_visual = probe.get_node_or_null("DetachTransform/Geometry")
		var proto_scale: Array = _v3((proto_visual as Node3D).scale) if proto_visual is Node3D else [0.0, 0.0, 0.0]
		probe.free()
		var ghost_m := _measure_unit(ghost)
		var row := {
			"kind": "ghost_table", "scene": scene_path,
			"prototype_visual_local_scale": proto_scale,
			"ghost_global_scale": _v3(ghost.global_transform.basis.get_scale()),
			"ghost_visual_outer_radius": ghost_m["visual_outer_radius"],
			"reference_visual_outer_radius": ref_m["visual_outer_radius"],
			"reference_visual_world_scale": ref_m["visual_world_scale"],
			"reference_collision_world_radius": ref_m["collision_world_radius"],
			"ghost_vs_reference": snappedf(
				float(ghost_m["visual_outer_radius"]) / maxf(float(ref_m["visual_outer_radius"]), 0.0001), 0.001),
		}
		_rows.append(row)
		print("[IVR2] ghost表 %-22s proto视觉scale=%s ghost_global=%s ghost外缘=%s 参照外缘=%s 比=%.3f（参照 coll_r=%s）" % [
			scene_path.get_file(), _fmt(proto_scale), _fmt(row["ghost_global_scale"]),
			_f(row["ghost_visual_outer_radius"]), _f(row["reference_visual_outer_radius"]),
			row["ghost_vs_reference"], _f(row["reference_collision_world_radius"])])
		_handler.call("_cancel_structure_placement")
		await get_tree().process_frame


## 等到己方所有建筑完工（"一次一个工地"会拒绝后续 Place）。
func _wait_all_constructed(max_frames: int) -> int:
	var frames := 0
	while frames < max_frames:
		var busy := false
		for child in _human.get_children():
			if child.has_method("is_constructed") and not child.is_constructed():
				busy = true
				break
		if not busy:
			break
		await get_tree().physics_frame
		frames += 1
	return frames


## B/C：真实 handler 路径。
func _real_placement(label: String, scene_path: String) -> void:
	var waited := await _wait_all_constructed(1500)
	print("[IVR2] %s 等待己方工地完工用了 %d 物理帧" % [label, waited])
	var cost: Dictionary = _balance.GetConstructionCost(load(scene_path))
	# 参照（identity 变换，模拟"干净变换"应有的世界尺寸）
	var reference: Node3D = load(scene_path).instantiate()
	var ref_spot: Vector3 = _cc.global_position + Vector3(0.0, 0.0, -60.0)
	_match.call("_setup_and_spawn_unit", reference, Transform3D(Basis.IDENTITY, ref_spot), _human, false)
	await get_tree().physics_frame
	var ref_m := _measure_unit(reference)
	reference.queue_free()
	await get_tree().process_frame
	# 找合法落点（围绕主基地扫描 24 方位 × 若干半径）
	var probe = load(scene_path).instantiate()
	var probe_r: float = float(probe.get("radius"))
	probe.free()
	var cc_r: float = float(_cc.get("radius"))
	var spot := Vector3.INF
	for ring in [1.0, 1.3, 1.7, 2.2]:
		var stand_off: float = (cc_r + probe_r + 0.6) * ring
		for k in range(24):
			var a := TAU * float(k) / 24.0
			var cand: Vector3 = _cc.global_position + Vector3(cos(a) * stand_off, 0.0, sin(a) * stand_off)
			var ev = _runtime.Evaluate(_human, load(scene_path), Transform3D(Basis.IDENTITY, cand), cost)
			if ev is Dictionary and bool(ev.get("accepted", false)):
				spot = cand
				break
		if spot != Vector3.INF:
			break
	if spot == Vector3.INF:
		print("[IVR2] %s(%s) 找不到合法落点，跳过" % [label, scene_path])
		_rows.append({"kind": label, "skipped": "no_legal_spot", "reference": ref_m})
		return
	# 真实链路：handler 建蓝图 → 挪到合法点 → 落地
	_handler.call("_cancel_structure_placement")
	_handler.call("_start_structure_placement", load(scene_path))
	await get_tree().process_frame
	var ghost: Node3D = _handler.get("_active_blueprint_node")
	if ghost == null:
		print("[IVR2] %s 蓝图未建立，跳过" % label)
		_rows.append({"kind": label, "skipped": "no_ghost", "reference": ref_m})
		return
	ghost.global_transform.origin = spot
	await get_tree().process_frame
	var ghost_m := _measure_unit(ghost)
	var handoff_scale: Array = _v3(ghost.global_transform.basis.get_scale())
	var validity = _handler.call("_calculate_blueprint_position_validity")
	var before := _count_own(_human, scene_path)
	_handler.call("_finish_structure_placement")
	for _f in range(90):
		await get_tree().physics_frame
		if _count_own(_human, scene_path) > before:
			break
	await get_tree().process_frame
	var spawned: Node3D = _find_last_own(_human, scene_path)
	var row := {
		"kind": label, "scene": scene_path, "spot": _v3(spot),
		"ghost_handoff_scale": handoff_scale,
		"ghost": ghost_m, "reference": ref_m,
		"validity": str(validity), "spawned_before": before,
		"spawned_after": _count_own(_human, scene_path),
	}
	if spawned != null:
		var built := _measure_unit(spawned)
		row["built"] = built
		row["ratio_built_vs_reference"] = snappedf(
			float(built["visual_outer_radius"]) / maxf(float(ref_m["visual_outer_radius"]), 0.0001), 0.001)
		row["ratio_ghost_vs_built"] = snappedf(
			float(ghost_m["visual_outer_radius"]) / maxf(float(built["visual_outer_radius"]), 0.0001), 0.001)
		row["collision_ratio_built_vs_reference"] = snappedf(
			float(built["collision_world_radius"]) / maxf(float(ref_m["collision_world_radius"]), 0.0001), 0.001)
		print("[IVR2] %s %s 落地: handoff_scale=%s root_local=%s visual_ws=%s coll_r=%s vis_out=%s | ghost vis_out=%s | 参照 vis_out=%s coll_r=%s | ghost/built=%.3f built/参照=%.3f coll比=%.3f" % [
			label, scene_path.get_file(), _fmt(handoff_scale), _fmt(built["root_local_scale"]),
			_f(built["visual_world_scale"]), _f(built["collision_world_radius"]),
			_f(built["visual_outer_radius"]), _f(ghost_m["visual_outer_radius"]),
			_f(ref_m["visual_outer_radius"]), _f(ref_m["collision_world_radius"]),
			row["ratio_ghost_vs_built"], row["ratio_built_vs_reference"],
			row["collision_ratio_built_vs_reference"]])
	else:
		print("[IVR2] %s %s 未落地（validity=%s, before=%d after=%d）" % [
			label, scene_path.get_file(), str(validity), before, _count_own(_human, scene_path)])
	_rows.append(row)


func _count_own(player: Node, scene_path: String) -> int:
	var n := 0
	for child in player.get_children():
		if child is Node3D and str(child.scene_file_path) == scene_path:
			n += 1
	return n


func _find_last_own(player: Node, scene_path: String) -> Node3D:
	var found: Node3D = null
	for child in player.get_children():
		if child is Node3D and str(child.scene_file_path) == scene_path:
			found = child
	return found


## 量一个单位/幽灵：root 缩放、Visual 世界缩放、碰撞世界半径、视觉世界外缘半径。
func _measure_unit(node: Node3D) -> Dictionary:
	var visual_ws := -1.0
	var geo: Node = node.get_node_or_null("Geometry")
	if geo == null:
		geo = node.get_node_or_null("DetachTransform/Geometry")
	if geo is Node3D:
		visual_ws = snappedf(absf((geo as Node3D).global_transform.basis.get_scale().x), 0.0001)
	var coll := 0.0
	for sub in node.find_children("*", "CollisionShape3D", true, false):
		var cs: CollisionShape3D = sub
		if cs.shape is CylinderShape3D:
			var s: Vector3 = cs.global_transform.basis.get_scale()
			coll = maxf(coll, (cs.shape as CylinderShape3D).radius * maxf(absf(s.x), absf(s.z)))
	var origin: Vector3 = node.global_position
	var outer := 0.0
	var search_root: Node = geo if geo != null else node
	for sub in search_root.find_children("*", "GeometryInstance3D", true, false):
		var gi: GeometryInstance3D = sub
		var aabb: AABB = gi.get_aabb()
		if aabb.size.length_squared() <= 0.0 and gi is MeshInstance3D:
			var mesh: Mesh = (gi as MeshInstance3D).mesh
			if mesh != null:
				aabb = mesh.get_aabb()
		var p := aabb.position
		var s2 := aabb.size
		for index in 8:
			var corner := Vector3(
				p.x + (s2.x if index & 1 else 0.0),
				p.y + (s2.y if index & 2 else 0.0),
				p.z + (s2.z if index & 4 else 0.0))
			var w: Vector3 = gi.global_transform * corner
			outer = maxf(outer, Vector2(w.x - origin.x, w.z - origin.z).length())
	var obstacle := node.get_node_or_null("MovementObstacle")
	var obstacle_radius := -1.0
	if obstacle != null and obstacle.get("radius") != null:
		obstacle_radius = float(obstacle.get("radius"))
	return {
		"node": str(node.name), "scene": str(node.scene_file_path),
		"root_local_scale": _v3(node.scale),
		"root_global_scale": _v3(node.global_transform.basis.get_scale()),
		"visual_world_scale": visual_ws,
		"collision_world_radius": snappedf(coll, 0.001),
		"obstacle_radius": obstacle_radius,
		"visual_outer_radius": snappedf(outer, 0.01),
	}


func _finish() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://build/indep_verify"))
	var file := FileAccess.open(REPORT_PATH, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify({
			"generated_at": Time.get_datetime_string_from_system(),
			"rows": _rows}, "  "))
		file.close()
		print("[IVR2] 报告已写 %s" % REPORT_PATH)
	get_tree().quit(0)


func _v3(v: Vector3) -> Array:
	return [snappedf(v.x, 0.0001), snappedf(v.y, 0.0001), snappedf(v.z, 0.0001)]


func _fmt(v) -> String:
	if v is Array:
		var parts := PackedStringArray()
		for x in v:
			parts.append(_f(x))
		return "(" + ",".join(parts) + ")"
	return str(v)


func _f(v) -> String:
	if v == null:
		return "n/a"
	return "%.3f" % float(v)