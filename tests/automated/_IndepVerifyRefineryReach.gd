extends Node

## 独立验证探针 #5（verifier 自写）：矿场"报到点"是否落在矿场自己的 carve 洞里 ——
## 回答 lead 的"矿车停在离矿 6m 处不动"归因问题（与单位根缩放无关，见探针 #4 引擎实测）。
## 口径来自源码（只读）：OreRefinery.gd:496-497 clearance = obstacle.radius + worker_r + 0.6；
## MovementObstacle.gd:46-62 carve 环由 radius 反推；洞 = 环世界外缘 + navmesh.agent_radius。

const MAP_SCENE := "res://source/match/maps/PlainAndSimple.tscn"
const REFINERY := "res://source/match/units/OreRefinery.tscn"
const WORKER := "res://source/match/units/Worker.tscn"

var _match: Node = null
var _human: Node = null
var _refinery: Node3D = null
var _worker: Node3D = null


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
	var terrain_map = _match.navigation.get_navigation_map_rid_by_domain(
		Constants.Match.Navigation.Domain.TERRAIN)
	var deadline := Time.get_ticks_msec() + 25000
	var cc: Node3D = null
	while Time.get_ticks_msec() < deadline:
		await get_tree().physics_frame
		var players: Node = _match.get_node_or_null("Players")
		if players == null or players.get_child_count() < 1:
			continue
		for sub in players.get_child(0).get_children():
			if sub is Node3D and sub.get_script() != null \
					and "CommandCenter" in str(sub.get_script().resource_path):
				cc = sub
		if cc != null and NavigationServer3D.map_get_closest_point_owner(
				terrain_map, cc.global_position).is_valid():
			break
	_human = _match.get_node("Players").get_children()[0]
	if cc == null:
		print("[IVR5] 对局未就绪")
		get_tree().quit(0)
		return
	var spot: Vector3 = cc.global_position + Vector3(0.0, 0.0, 26.0)
	_refinery = load(REFINERY).instantiate()
	_match.call("_setup_and_spawn_unit", _refinery, Transform3D(Basis.IDENTITY, spot), _human, false)
	_worker = load(WORKER).instantiate()
	_match.call("_setup_and_spawn_unit", _worker,
		Transform3D(Basis.IDENTITY, spot + Vector3(9.0, 0.0, 0.0)), _human, false)
	print("[IVR5] 矿场中心=%s 工人半径=%s" % [
		_fmt(_v3(_refinery.global_position)), str(_worker.get("radius"))])
	await _rebake_and_wait("初次烘焙")
	_measure("当前配置")
	_simulate_premigration_refinery()
	await _rebake_and_wait("改配置后重烘")
	_measure("迁移前配置")
	get_tree().quit(0)


## 显式请求导航重烘并等到洞半径稳定（最多 12s）。
func _rebake_and_wait(tag: String) -> void:
	MatchSignals.schedule_navigation_rebake.emit(Constants.Match.Navigation.Domain.TERRAIN)
	var last := -1.0
	var stable := 0
	for _i in range(720):
		await get_tree().physics_frame
		if _i % 30 != 29:
			continue
		var now := _hole_radius()
		if absf(now - last) < 0.01 and now > 0.5:
			stable += 1
			if stable >= 2:
				print("[IVR5] %s：洞半径稳定在 %.2f" % [tag, now])
				return
		else:
			stable = 0
		last = now
	print("[IVR5] %s：等待超时，最后一次洞半径 %.2f" % [tag, last])


## 从矿场中心沿 8 个方向步进 0.25m，找"最近导航面点水平偏移 > 0.25m"的最外半径 = 洞半径。
func _measure(tag: String) -> void:
	var terrain_map = _match.navigation.get_navigation_map_rid_by_domain(
		Constants.Match.Navigation.Domain.TERRAIN)
	var center: Vector3 = _refinery.global_position
	var obstacle: Node = _refinery.get_node_or_null("MovementObstacle")
	var verts: PackedVector3Array = obstacle.get("vertices")
	var ws: float = absf((obstacle as Node3D).global_transform.basis.get_scale().x)
	var ring := 0.0
	for v in verts:
		ring = maxf(ring, Vector2(v.x, v.z).length() * ws)
	var radius_prop := float(obstacle.get("radius"))
	var worker_radius := float(_worker.get("radius"))
	var stand := radius_prop + worker_radius + 0.6
	var per_dir := PackedStringArray()
	var hole := 999.0
	# 只取 0..5 号方向：6/7 号朝向指挥中心，测到的是**指挥中心**的洞（会把读数带偏）。
	for k in range(6):
		var a := TAU * float(k) / 8.0
		var dir := Vector3(cos(a), 0.0, sin(a))
		var last_bad := 0.0
		var d := 0.0
		while d <= 16.0:
			var p: Vector3 = center + dir * d
			var closest: Vector3 = NavigationServer3D.map_get_closest_point(terrain_map, p)
			if Vector2(closest.x - p.x, closest.z - p.z).length() > 0.25:
				last_bad = d
			d += 0.25
		hole = minf(hole, last_bad)
		per_dir.append("%d:%.1f" % [k, last_bad])
	var worst := hole
	print("[IVR5] %-14s radius=%.2f 环外缘=%.2f from_radius=%s 报到点下界=%.2f 洞半径=%.2f (%s)" % [
		tag, radius_prop, ring, str(obstacle.get("carve_vertices_from_radius")), stand, worst,
		" ".join(per_dir)])
	print("[IVR5] %-14s 报到点(%.2f) %s" % [tag, stand,
		("**在洞内 ⇒ 工人永远到不了**" if stand < worst else "在洞外（可达）")])


## 只算洞半径（0..5 方向的最小值），供稳定性轮询用。
func _hole_radius() -> float:
	var terrain_map = _match.navigation.get_navigation_map_rid_by_domain(
		Constants.Match.Navigation.Domain.TERRAIN)
	var center: Vector3 = _refinery.global_position
	var hole := 999.0
	for k in range(6):
		var a := TAU * float(k) / 8.0
		var dir := Vector3(cos(a), 0.0, sin(a))
		var last_bad := 0.0
		var d := 0.0
		while d <= 16.0:
			var p: Vector3 = center + dir * d
			var closest: Vector3 = NavigationServer3D.map_get_closest_point(terrain_map, p)
			if Vector2(closest.x - p.x, closest.z - p.z).length() > 0.25:
				last_bad = d
			d += 0.25
		hole = minf(hole, last_bad)
	return hole


func _simulate_premigration_refinery() -> void:
	var obstacle: Node = _refinery.get_node_or_null("MovementObstacle")
	if obstacle == null:
		return
	obstacle.set("radius", 6.0)
	var points := PackedVector3Array()
	for index in 16:
		var angle := TAU * float(index) / 16.0
		points.append(Vector3(cos(angle) * 4.2, 0.0, sin(angle) * 4.2))
	obstacle.set("carve_vertices_from_radius", false)
	obstacle.set("vertices", points)
	for sub in _refinery.find_children("*", "CollisionShape3D", true, false):
		var cs: CollisionShape3D = sub
		if cs.shape is CylinderShape3D:
			var cyl: CylinderShape3D = (cs.shape as CylinderShape3D).duplicate()
			cyl.radius = 6.0
			cyl.height = 1.6
			cs.shape = cyl
	print("[IVR5] 该矿场实例已改回迁移前 carve/collision（radius 9.8→6.0、环 9.8→4.2、碰撞 9.8→6.0）")


func _v3(v: Vector3) -> Array:
	return [snappedf(v.x, 0.01), snappedf(v.y, 0.01), snappedf(v.z, 0.01)]


func _fmt(v) -> String:
	if v is Array:
		var parts := PackedStringArray()
		for x in v:
			parts.append(str(x))
		return "(" + ",".join(parts) + ")"
	return str(v)