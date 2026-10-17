extends Node

## 独立验证探针 #4（verifier 自写）：local-avoidance 归因 —— 单位根缩放 2→1 是否改变了
## 避让的有效几何？
##
## 两段：
##  Q1（引擎行为实测）：NavigationAgent3D 的避让参数（radius/neighbor_distance/...）
##      是否被节点的 global scale 缩放？直接读 NavigationServer3D 侧的实际值。
##  Q2（夹具 A/B，三种模式，同一进程同一夹具）：
##      baseline       ：原样跑官方夹具 tests/automated/LocalAvoidanceSmokeTest.tscn
##      premig         ：把 3 辆 Tank 还原成迁移前形态（root scale=2、被折叠过的子节点
##                       缩放减半、CylinderShape 半径/高度减半 ⇒ 每个子节点的**世界**
##                       几何与现在完全一致，而每个子节点的 **global scale 回到迁移前**
##                       的 ×2）。Movement 节点保持 local scale=1 ⇒ global scale=2（迁移前）。
##  （注：Mobile 单位的 Movement 是 NavigationAgent3D＝Node，没有 transform，
##    所以"把 Movement.scale 设回 2"在引擎里根本不成立；premig 只还原根/子节点缩放。）
##
## 模式从 res://build/indep_verify/avoid_mode.txt 读（本人写文件，不改 source/tests）。

const FIXTURE := "res://tests/automated/LocalAvoidanceSmokeTest.tscn"
const MODE_PATH := "res://build/indep_verify/avoid_mode.txt"
const OUT_DIR := "res://build/indep_verify"

var _mode := "baseline"
var _applied := false


func _ready():
	_mode = _read_mode()
	print("[IVR4] mode=%s" % _mode)
	await _engine_probe()
	if _mode == "engine_only":
		print("[IVR4] engine_only 模式结束")
		get_tree().quit(0)
		return
	var fixture: Node = load(FIXTURE).instantiate()
	add_child(fixture)
	# fixture 的 _ready 同步执行到第一个 await —— 此时 Match 与预置 Tank 已在树里。
	_apply_intervention(fixture)
	print("[IVR4] 夹具已启动（mode=%s），等待其自身断言输出" % _mode)


## Q1：节点 global scale 是否进入 NavigationServer 的 agent 参数。
## 关键前提先实测：NavigationAgent3D 到底继承 Node 还是 Node3D（决定"根缩放"能否作用于它）。
func _engine_probe() -> void:
	var probe_agent: Node = NavigationAgent3D.new()
	var probe_obstacle: Node = NavigationObstacle3D.new()
	print("[IVR4-Q1] NavigationAgent3D is Node3D=%s class=%s | NavigationObstacle3D is Node3D=%s" % [
		str(probe_agent is Node3D), probe_agent.get_class(), str(probe_obstacle is Node3D)])
	probe_agent.free()
	probe_obstacle.free()
	var map: RID = get_viewport().world_3d.navigation_map
	for parent_scale in [1.0, 2.0, 4.0]:
		var holder := Node3D.new()
		holder.scale = Vector3(parent_scale, parent_scale, parent_scale)
		var agent := NavigationAgent3D.new()
		agent.radius = 2.0
		agent.neighbor_distance = 3.0
		agent.max_speed = 5.0
		agent.height = 1.0
		agent.path_desired_distance = 0.5
		agent.target_desired_distance = 0.5
		agent.max_neighbors = 8
		agent.time_horizon_agents = 4.5
		agent.avoidance_enabled = true
		holder.add_child(agent)
		add_child(holder)
		agent.set_navigation_map(map)
		agent.set_velocity(Vector3(1, 0, 0))
		await get_tree().physics_frame
		await get_tree().physics_frame
		var rid: RID = agent.get_rid()
		var server_props := ["radius", "neighbor_distance", "max_speed", "height",
			"max_neighbors", "time_horizon_agents", "time_horizon_obstacles", "position"]
		var parts := PackedStringArray()
		for prop in server_props:
			if not NavigationServer3D.has_method("agent_get_" + prop):
				parts.append("%s=(无 server getter)" % prop)
				continue
			parts.append("%s=%s" % [prop, str(NavigationServer3D.call("agent_get_" + prop, rid))])
		var side := PackedStringArray()
		for prop in ["path_desired_distance", "target_desired_distance"]:
			side.append("%s(node)=%s" % [prop, str(agent.get(prop))])
		print("[IVR4-Q1] 父链 scale=%.1f（agent 无 transform）→ 服务器侧 %s | %s" % [
			parent_scale, " ".join(parts), " ".join(side)])
		holder.queue_free()
		await get_tree().process_frame


## Q2：把夹具里所有"带 Movement 的单位"还原成迁移前形态（见文件头说明）。
func _apply_intervention(root: Node) -> void:
	var units: Array = []
	_collect_units(root, units)
	print("[IVR4] 找到单位 %d 个: %s" % [units.size(), str(units.map(func(u): return str(u.name)))])
	if _mode == "cc_carve_old":
		_restore_old_structure_carve(root)
		_report_structures(root)
		for unit in units:
			_report_unit(unit, "cc_carve_old")
		return
	if _mode == "baseline":
		_report_structures(root)
		for unit in units:
			_report_unit(unit, "baseline")
		return
	for unit in units:
		_reconstruct_premigration(unit)
	for unit in units:
		_report_unit(unit, _mode)
	_delayed_reachability(root, units)


func _collect_units(node: Node, out: Array) -> void:
	if node is Node3D and node.has_node("Movement"):
		out.append(node)
	for child in node.get_children():
		_collect_units(child, out)


## 迁移前形态（忠实还原：**世界几何逐项不变**，只有节点级 scale 回到迁移前的值）
##   root.scale = 2
##   带缩放的子节点（Geometry/HealthBar/Anchor 等，local != 1）local /= 2 ⇒ 世界缩放不变
##   CollisionShape3D：local 保持 1（世界 = 2），CylinderShape 的 radius/height /= 2 ⇒ 世界半径不变
##   带 radius 载荷的表现节点（Selection/Highlight/Targetability）radius /= 2 ⇒ 世界半径不变
## NavigationAgent3D(Movement) 是 Node：无 transform，根缩放本来就作用不到它。
func _reconstruct_premigration(unit: Node3D) -> void:
	unit.scale = Vector3(2.0, 2.0, 2.0)
	for child in unit.get_children():
		if not (child is Node3D):
			continue
		var c := child as Node3D
		if not c.scale.is_equal_approx(Vector3.ONE):
			c.scale = c.scale * 0.5
		if c is CollisionShape3D and (c as CollisionShape3D).shape is CylinderShape3D:
			var cs := c as CollisionShape3D
			var cyl: CylinderShape3D = (cs.shape as CylinderShape3D).duplicate()
			cyl.radius *= 0.5
			cyl.height *= 0.5
			cs.shape = cyl
		if c.get("radius") != null and str(c.name) in ["Selection", "Highlight", "Targetability"]:
			c.set("radius", float(c.get("radius")) * 0.5)
	var movement: Node = unit.get_node_or_null("Movement")
	if movement != null and not (movement is Node3D):
		print("[IVR4] Movement 节点 %s 类型=%s（无 transform，根缩放不作用于它）" % [
			str(movement.name), movement.get_class()])


## 迁移前的结构 carve 环：CC/矿场 1.4m 本地 × root scale 3 = 4.2m 世界；其余 1.1 × 3 = 3.3m。
## 现在 root scale=1、vertices 由 radius 反推 ⇒ CC 洞外缘 7.0m。这里把环改回旧的世界外缘。
func _restore_old_structure_carve(root: Node) -> void:
	var count := 0
	for node in _all_nodes(root):
		if not (node is Node3D) or node.get("radius") == null:
			continue
		if node.get("vertices") == null:
			continue
		if str(node.name) != "MovementObstacle":
			continue
		# 只还原**指挥中心**的旧 carve 环（迁移前 = 1.4m 本地 × root scale 3 = 4.2m 世界）；
		# 矿点等其它障碍保持原样，避免把无关变量混进 A/B。
		if not _structure_scene_is(node, "CommandCenter"):
			continue
		var old_outer := 4.2
		var points := PackedVector3Array()
		for index in 16:
			var angle := TAU * float(index) / 16.0
			points.append(Vector3(cos(angle) * old_outer, 0.0, sin(angle) * old_outer))
		node.set("carve_vertices_from_radius", false)
		node.set("vertices", points)
		count += 1
		print("[IVR4] 旧 carve 环已恢复: %s 外缘=%.2f（parent=%s）" % [
			str(node.get_path()), old_outer, str(node.get_parent().name)])
	print("[IVR4] 结构 carve 环改回迁移前形态：%d 个" % count)


func _structure_scene_is(obstacle: Node, keyword: String) -> bool:
	var parent := obstacle.get_parent()
	while parent != null:
		if keyword in str(parent.name) or keyword in str(parent.scene_file_path):
			return true
		parent = parent.get_parent()
	return false


func _all_nodes(root: Node) -> Array:
	var out: Array = []
	var stack: Array = [root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		out.append(node)
		for child in node.get_children():
			stack.append(child)
	return out


## 结构刻痕与单位起点的几何关系：单位是否已经站在结构 carve 洞（不可走）里。
func _report_structures(root: Node) -> void:
	var obstacles: Array = []
	for node in _all_nodes(root):
		if node is Node3D and node.get("radius") != null and node.get("vertices") != null \
				and str(node.name) == "MovementObstacle":
			var verts: PackedVector3Array = node.get("vertices")
			var ws: float = absf((node as Node3D).global_transform.basis.get_scale().x)
			var outer := 0.0
			for v in verts:
				outer = maxf(outer, Vector2(v.x, v.z).length() * ws)
			obstacles.append({
				"node": str(node.get_path()),
				"parent": str(node.get_parent().name),
				"center": _v3((node as Node3D).global_position),
				"radius_prop": float(node.get("radius")),
				"carve_outer": snappedf(outer, 0.001),
				"carve_from_radius": str(node.get("carve_vertices_from_radius")),
			})
	for item in obstacles:
		print("[IVR4] 结构 carve: %s 中心=%s radius=%.2f 环外缘=%.3f from_radius=%s" % [
			item["parent"], _fmt(item["center"]), item["radius_prop"],
			item["carve_outer"], item["carve_from_radius"]])


func _report_unit(unit: Node3D, tag: String) -> void:
	var movement: Node = unit.get_node_or_null("Movement")
	var movement_scale := "n/a"
	if movement is Node3D:
		movement_scale = str((movement as Node3D).global_transform.basis.get_scale())
	var coll := 0.0
	for sub in unit.find_children("*", "CollisionShape3D", true, false):
		if (sub as CollisionShape3D).shape is CylinderShape3D:
			var cs: CollisionShape3D = sub
			var s: Vector3 = cs.global_transform.basis.get_scale()
			coll = maxf(coll, (cs.shape as CylinderShape3D).radius * maxf(absf(s.x), absf(s.z)))
	var visual_ws := -1.0
	var geo: Node = unit.get_node_or_null("Geometry")
	if geo is Node3D:
		visual_ws = absf((geo as Node3D).global_transform.basis.get_scale().x)
	var nearest := ""
	var best := INF
	for node in _all_nodes(unit.get_tree().current_scene if unit.get_tree().current_scene != null else unit):
		if node is Node3D and str(node.name) == "MovementObstacle" and node.get("vertices") != null:
			var verts: PackedVector3Array = node.get("vertices")
			var ws: float = absf((node as Node3D).global_transform.basis.get_scale().x)
			var outer := 0.0
			for v in verts:
				outer = maxf(outer, Vector2(v.x, v.z).length() * ws)
			var d := Vector2(unit.global_position.x - (node as Node3D).global_position.x,
				unit.global_position.z - (node as Node3D).global_position.z).length()
			if d < best:
				best = d
				nearest = "%s d=%.2f 洞外缘=%.2f" % [str(node.get_parent().name), d, outer]
	print("[IVR4] %-14s %-12s root_scale=%s movement_global=%s coll_world_r=%.3f visual_ws=%.3f | 最近结构: %s" % [
		tag, str(unit.name), str(unit.scale), movement_scale, coll, visual_ws, nearest])


## 延迟到导航图烘焙完成后再量可达性（否则 clamp 读数是未烘焙的垃圾值）。
func _delayed_reachability(root: Node, units: Array) -> void:
	await get_tree().create_timer(4.0).timeout
	await _report_reachability(root, units)


func _report_reachability(root: Node, units: Array) -> void:
	var match_node: Node = root.find_child("Match", true, false)
	if match_node == null or match_node.get("navigation") == null:
		print("[IVR4] 找不到 Match.navigation，跳过可达性测量")
		return
	var map = match_node.navigation.get_navigation_map_rid_by_domain(
		Constants.Match.Navigation.Domain.TERRAIN)
	if not map.is_valid():
		print("[IVR4] terrain 导航图 RID 无效")
		return
	for unit in units:
		var movement: Node = unit.get_node_or_null("Movement")
		var want := "n/a"
		if movement != null and movement.get("target_desired_distance") != null:
			want = str(movement.get("target_desired_distance"))
		var start: Vector3 = unit.global_position
		var clamped: Vector3 = NavigationServer3D.map_get_closest_point(map, start)
		print("[IVR4] %s 自身位置 clamp 偏移=%.3f（start远点=%s → %s, target_desired_distance=%s）" % [
			str(unit.name), start.distance_to(clamped), _fmt(_v3(start)), _fmt(_v3(clamped)), want])
		for other in units:
			if other == unit:
				continue
			var goal: Vector3 = other.global_position
			var goal_clamped: Vector3 = NavigationServer3D.map_get_closest_point(map, goal)
			var path: PackedVector3Array = NavigationServer3D.map_get_path(map, start, goal, true)
			var tail: Vector3 = path[path.size() - 1] if path.size() > 0 else Vector3.INF
			print("[IVR4] %s → %s：目标 clamp 偏移=%.3f 路径点数=%d 端点距目标=%.3f（目标=%s）" % [
				str(unit.name), str(other.name), goal.distance_to(goal_clamped), path.size(),
				(tail.distance_to(goal) if path.size() > 0 else -1.0), _fmt(_v3(goal))])


func _v3(v: Vector3) -> Array:
	return [snappedf(v.x, 0.01), snappedf(v.y, 0.01), snappedf(v.z, 0.01)]


func _fmt(v) -> String:
	if v is Array:
		var parts := PackedStringArray()
		for x in v:
			parts.append(str(x))
		return "(" + ",".join(parts) + ")"
	return str(v)


func _read_mode() -> String:
	if not FileAccess.file_exists(MODE_PATH):
		return "baseline"
	var file := FileAccess.open(MODE_PATH, FileAccess.READ)
	if file == null:
		return "baseline"
	var text := file.get_as_text().strip_edges()
	file.close()
	return text if text != "" else "baseline"