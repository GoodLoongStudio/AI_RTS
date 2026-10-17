extends Node

## 独立验证探针 #1（verifier 自写，不复用主线探针）：
##   ① 19 个单位场景的 UnitRoot scale / 全树累计 scale / 美术缩放落点
##   ② 与 tests/automated/_premigration/*（已核验 == git HEAD 内容，仅 CRLF 差异）的
##      世界尺寸 A/B：视觉外缘 / 碰撞世界半径 / 逻辑半径 / carve 环世界外缘
##
## 输出：完整 JSON 落盘 res://build/indep_verify/probe1_report.json，
## stdout 只打紧凑摘要（避免被工具输出截断吞掉中段）。
##
## 根脚本 set_script(null)（与主线 _ScaleMigrationAB.gd 同法）：裸环境下 Unit.gd 找不到
## "Match" 父链会报错；子节点脚本（MovementObstacle.gd 等）保留，故运行时 carve 重算真实发生。

const SCENES := [
	"CommandCenter", "VehicleFactory", "Barracks", "AircraftFactory", "OreRefinery",
	"AntiGroundTurret", "AntiAirTurret", "MachineGunTurret",
	"Tank", "HeavyTank", "APC", "TransportTruck", "Worker", "Drone", "Scout", "Infantry",
	"Helicopter", "Rocketeer", "Sniper",
]
## 计划文档《尺寸契约》的迁移基线世界半径。
const BASELINE := {
	"CommandCenter": 7.00, "VehicleFactory": 6.65, "Barracks": 6.25,
	"AircraftFactory": 8.00, "OreRefinery": 9.80,
	"Tank": 2.00, "HeavyTank": 2.25, "APC": 2.70, "TransportTruck": 2.80,
	"Worker": 2.00, "Drone": 2.00, "Scout": 2.00,
	"Infantry": 1.35, "Sniper": 1.35, "Rocketeer": 1.35,
}
const PRESENTATION := [
	"HealthBar", "HealthBarAnchor", "SelectionAnchor", "RallyPoint",
	"AirToTerrainMarker", "Highlight", "Selection", "Sparkling",
]
const REPORT_PATH := "res://build/indep_verify/probe1_report.json"
const EPS := 0.0001

var _violations := 0
var _nonone := 0
var _root_bad := 0
var _rows: Array = []


func _ready():
	var holder := Node3D.new()
	holder.name = "IVRHolder"
	add_child(holder)
	for scene_name in SCENES:
		var cur_path := "res://source/match/units/%s.tscn" % scene_name
		var pre_path := "res://tests/automated/_premigration/%s.tscn" % scene_name
		var cur = _measure(cur_path, holder)
		if cur == null:
			print("[IVR] %-17s 场景缺失 %s" % [scene_name, cur_path])
			continue
		var pre = _measure(pre_path, holder) if ResourceLoader.exists(pre_path) else null
		_report(scene_name, cur, pre)
	await get_tree().process_frame
	_write_report()
	print("[IVR-SUMMARY] scenes=%d root_scale_violations=%d gameplay_scale_violations=%d non_one_local_scale_nodes=%d"
		% [SCENES.size(), _root_bad, _violations, _nonone])
	get_tree().quit(0)


func _report(scene_name: String, cur: Dictionary, pre) -> void:
	var carriers := PackedStringArray()
	for item in cur["scale_carriers"]:
		carriers.append("%s=%s[%s]" % [item["path"], _fmt(item["local_scale"]), item["kind"]])
	var bad: Array = []
	for item in cur["gameplay_nodes"]:
		if not _is_one(item["global_scale"]):
			bad.append(item)
			_violations += 1
	if not _is_one(cur["root_local_scale"]):
		_root_bad += 1
	if not _is_one(cur["root_global_scale"]):
		_root_bad += 1
	var world_cur: Dictionary = cur["world"]
	var world_pre = pre["world"] if pre != null else null
	var base = BASELINE.get(scene_name, null)
	var baseline_match = null
	if base != null:
		baseline_match = absf(float(world_cur["logical_radius"]) - float(base)) < 0.02
	_rows.append({
		"scene": scene_name, "root_local_scale": cur["root_local_scale"],
		"root_global_scale": cur["root_global_scale"],
		"gameplay_violations": bad, "chain_breaks": cur["chain_breaks"],
		"scale_carriers": cur["scale_carriers"],
		"inherited_scale_roots": cur["inherited_roots"],
		"gameplay_nodes": cur["gameplay_nodes"],
		"world_cur": world_cur, "world_pre": world_pre,
		"baseline_logical": base, "baseline_match": baseline_match,
	})
	print("[IVR] %-17s root_local=%s root_global=%s  玩法违规=%d 本地非1缩放节点=%d" % [
		scene_name, _fmt(cur["root_local_scale"]), _fmt(cur["root_global_scale"]),
		bad.size(), cur["scale_carriers"].size()])
	print("[IVR] %-17s   缩放落点: %s" % [scene_name, " | ".join(carriers) if carriers.size() > 0 else "(无)"])
	if cur["chain_breaks"].size() > 0:
		print("[IVR] %-17s   ⚠ 变换链断点: %s" % [scene_name, JSON.stringify(cur["chain_breaks"])])
	for item in bad:
		print("[IVR-VIOLATION] %s 玩法节点 %s(%s) 累计 scale = %s（要求 1）"
			% [scene_name, item["path"], item["class"], _fmt(item["global_scale"])])
	var c := world_cur
	var p: Variant = world_pre
	print("[IVR] %-17s   世界值 cur: visScale=%s visSize=%s coll_r=%s coll_h=%s move_r=%s obs_r=%s logic=%s carve=%s(%d verts,from_radius=%s)" % [
		scene_name, _f(c.get("visual_world_scale")), _fmt(c.get("visual_world_size")),
		_f(c.get("collision_world_radius")), _f(c.get("collision_world_height")),
		_f(c.get("movement_radius")), _f(c.get("obstacle_radius")), _f(c.get("logical_radius")),
		_f(c.get("carve_ring_world_outer")), int(c.get("carve_vertex_count")),
		str(c.get("carve_from_radius"))])
	if p != null:
		var delta := {
			"visScale": snappedf(float(p["visual_world_scale"]) - float(c["visual_world_scale"]), 0.001),
			"visSize": _sub(c["visual_world_size"], p["visual_world_size"]),
			"coll_r": snappedf(float(p["collision_world_radius"]) - float(c["collision_world_radius"]), 0.001),
			"coll_h": snappedf(float(p["collision_world_height"]) - float(c["collision_world_height"]), 0.001),
			"move_r": snappedf(float(p["movement_radius"]) - float(c["movement_radius"]), 0.001),
			"obs_r": snappedf(float(p["obstacle_radius"]) - float(c["obstacle_radius"]), 0.001),
			"carve": snappedf(float(p["carve_ring_world_outer"]) - float(c["carve_ring_world_outer"]), 0.001),
			"pre_root_scale": pre["root_global_scale"],
			"pre_naive_visual_scale": p.get("visual_naive_chain_scale"),
		}
		print("[IVR] %-17s   A/B pre: root=%s naive_vis=%s visScale=%s visSize=%s coll_r=%s coll_h=%s move_r=%s obs_r=%s carve=%s" % [
			scene_name, _fmt(pre["root_global_scale"]), _f(p.get("visual_naive_chain_scale")),
			_f(p.get("visual_world_scale")), _fmt(p.get("visual_world_size")),
			_f(p.get("collision_world_radius")), _f(p.get("collision_world_height")),
			_f(p.get("movement_radius")), _f(p.get("obstacle_radius")),
			_f(p.get("carve_ring_world_outer"))])
		print("[IVR] %-17s   Δ(pre-cur): %s" % [scene_name, JSON.stringify(delta)])
	if base != null:
		print("[IVR] %-17s   基线 %s vs 实测 logic=%s → %s" % [
			scene_name, str(base), _f(c.get("logical_radius")),
			("一致" if baseline_match else "**不一致**")])


func _write_report() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://build/indep_verify"))
	var file := FileAccess.open(REPORT_PATH, FileAccess.WRITE)
	if file == null:
		print("[IVR-ERROR] 无法写报告 %s" % REPORT_PATH)
		return
	file.store_string(JSON.stringify({
		"generated_at": Time.get_datetime_string_from_system(),
		"scenes": _rows,
		"root_scale_violations": _root_bad,
		"gameplay_scale_violations": _violations,
	}, "  "))
	file.close()
	print("[IVR] 报告已写 %s" % REPORT_PATH)


func _measure(path: String, holder: Node3D):
	if not ResourceLoader.exists(path):
		return null
	var packed: PackedScene = load(path)
	var root: Node = packed.instantiate()
	root.set_script(null)
	holder.add_child(root)
	root.position = Vector3.ZERO
	root.rotation = Vector3.ZERO
	var result := {
		"root_type": root.get_class(),
		"root_local_scale": _v3((root as Node3D).scale),
		"root_global_scale": _v3((root as Node3D).global_transform.basis.get_scale()),
		"scale_carriers": [], "inherited_roots": [], "gameplay_nodes": [], "chain_breaks": [],
	}
	_walk(root, root, "", Vector3.ONE, result)
	result["world"] = _world_values(root)
	root.queue_free()
	return result


func _walk(root: Node, node: Node, rel: String, parent_chain: Vector3, out: Dictionary) -> void:
	var chain := parent_chain
	if node is Node3D:
		var n3 := node as Node3D
		var global_scale: Vector3 = n3.global_transform.basis.get_scale()
		chain = Vector3(
			parent_chain.x * n3.scale.x, parent_chain.y * n3.scale.y, parent_chain.z * n3.scale.z)
		var kind := _classify(rel)
		var item := {
			"path": rel if rel != "" else ".", "class": node.get_class(), "kind": kind,
			"local_scale": _v3(n3.scale), "parent_chain_scale": _v3(parent_chain),
			"chain_scale": _v3(chain), "global_scale": _v3(global_scale),
		}
		if not _is_one(n3.scale):
			_nonone += 1
			out["scale_carriers"].append(item)
		if not _is_one(global_scale) and _is_one(parent_chain):
			out["inherited_roots"].append(item)
		if kind == "gameplay":
			out["gameplay_nodes"].append(item)
		if chain.distance_to(global_scale) > 0.001:
			out["chain_breaks"].append({
				"path": item["path"], "chain_scale": item["chain_scale"],
				"global_scale": item["global_scale"]})
	for child in node.get_children():
		var child_rel := str(child.name) if rel == "" else rel + "/" + str(child.name)
		if child is Node3D:
			_walk(root, child, child_rel, chain, out)
		else:
			# plain Node（如炮塔 DetachTransform）：Godot 的 Transform 链在此断开，
			# 子节点 global_transform 不含上层缩放。这里把链重置为 1 以便如实检出。
			_walk(root, child, child_rel, Vector3.ONE, out)


func _classify(rel: String) -> String:
	if rel == "":
		return "root"
	if rel == "Geometry" or rel.begins_with("Geometry/") \
			or rel.begins_with("DetachTransform/Geometry"):
		return "visual"
	var head := rel.split("/")[0]
	if PRESENTATION.has(head):
		return "presentation"
	return "gameplay"


func _world_values(root: Node) -> Dictionary:
	var origin: Vector3 = (root as Node3D).global_position
	var visual := AABB()
	var has_visual := false
	for geo_path in ["Geometry", "DetachTransform/Geometry"]:
		var geo: Node = root.get_node_or_null(geo_path)
		if geo == null:
			continue
		for sub in geo.find_children("*", "GeometryInstance3D", true, false):
			var gi: GeometryInstance3D = sub
			var aabb: AABB = gi.get_aabb()
			if aabb.size.length_squared() <= 0.0 and gi is MeshInstance3D:
				var mesh: Mesh = (gi as MeshInstance3D).mesh
				if mesh != null:
					aabb = mesh.get_aabb()
			var world: AABB = gi.global_transform * aabb
			visual = world if not has_visual else visual.merge(world)
			has_visual = true
	var collision_radius := 0.0
	var collision_height := 0.0
	var collision_shapes := 0
	for sub in root.find_children("*", "CollisionShape3D", true, false):
		var cs: CollisionShape3D = sub
		if not (cs.shape is CylinderShape3D):
			continue
		collision_shapes += 1
		var cyl: CylinderShape3D = cs.shape
		var s: Vector3 = cs.global_transform.basis.get_scale()
		collision_radius = maxf(collision_radius, cyl.radius * maxf(absf(s.x), absf(s.z)))
		collision_height = maxf(collision_height, cyl.height * absf(s.y))
	var movement_radius := -1.0
	var movement := root.get_node_or_null("Movement")
	if movement != null and movement.get("radius") != null:
		movement_radius = float(movement.get("radius"))
	var obstacle_radius := -1.0
	var obstacle := root.get_node_or_null("MovementObstacle")
	if obstacle != null and obstacle.get("radius") != null:
		obstacle_radius = float(obstacle.get("radius"))
	var carve_outer := -1.0
	var carve_count := 0
	var carve_from_radius = null
	if obstacle != null and obstacle.get("vertices") != null:
		var verts: PackedVector3Array = obstacle.get("vertices")
		carve_count = verts.size()
		var ws: float = absf((obstacle as Node3D).global_transform.basis.get_scale().x)
		var outer := 0.0
		for v in verts:
			outer = maxf(outer, Vector2(v.x, v.z).length() * ws)
		carve_outer = snappedf(outer, 0.001)
		if obstacle.get("carve_vertices_from_radius") != null:
			carve_from_radius = bool(obstacle.get("carve_vertices_from_radius"))
	var visual_ws := -1.0
	var visual_naive := -1.0
	for geo_path in ["Geometry", "DetachTransform/Geometry"]:
		var geo_node: Node3D = root.get_node_or_null(geo_path)
		if geo_node == null:
			continue
		visual_ws = snappedf(absf(geo_node.global_transform.basis.get_scale().x), 0.0001)
		var naive := 1.0
		var walker: Node = root
		for segment in str(geo_path).split("/"):
			if walker == null:
				break
			var next_node: Node = walker.get_node_or_null(NodePath(segment))
			if next_node == null:
				walker = null
				break
			if next_node is Node3D:
				naive *= (next_node as Node3D).scale.x
			walker = next_node
		visual_naive = snappedf(naive, 0.0001)
		break
	var logical := maxf(movement_radius, obstacle_radius)
	return {
		"visual_world_scale": visual_ws,
		"visual_naive_chain_scale": visual_naive,
		"visual_world_size": [
			snappedf(visual.size.x, 0.01), snappedf(visual.size.y, 0.01),
			snappedf(visual.size.z, 0.01)],
		"visual_world_center_offset": [
			snappedf(visual.get_center().x - origin.x, 0.01),
			snappedf(visual.get_center().y - origin.y, 0.01),
			snappedf(visual.get_center().z - origin.z, 0.01)],
		"collision_world_radius": snappedf(collision_radius, 0.001),
		"collision_world_height": snappedf(collision_height, 0.001),
		"collision_shape_count": collision_shapes,
		"movement_radius": movement_radius,
		"obstacle_radius": obstacle_radius,
		"logical_radius": logical,
		"carve_ring_world_outer": carve_outer,
		"carve_vertex_count": carve_count,
		"carve_from_radius": carve_from_radius,
	}


func _is_one(v) -> bool:
	var x := 1.0
	var y := 1.0
	var z := 1.0
	if v is Array:
		x = float(v[0])
		y = float(v[1])
		z = float(v[2])
	elif v is Vector3:
		x = v.x
		y = v.y
		z = v.z
	else:
		return false
	return absf(x - 1.0) <= EPS and absf(y - 1.0) <= EPS and absf(z - 1.0) <= EPS


func _v3(v: Vector3) -> Array:
	return [snappedf(v.x, 0.0001), snappedf(v.y, 0.0001), snappedf(v.z, 0.0001)]


func _fmt(v) -> String:
	if v == null:
		return "n/a"
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


func _sub(a: Array, b: Array) -> Array:
	return [snappedf(float(b[0]) - float(a[0]), 0.01), snappedf(float(b[1]) - float(a[1]), 0.01),
		snappedf(float(b[2]) - float(a[2]), 0.01)]