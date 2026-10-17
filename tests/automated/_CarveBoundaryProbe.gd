extends Node

## 阶段 4 判定实验 v2：carve 用 radius 还是 vertices？
## v1 教训：手动 bake_navigation_mesh(false) 会把运行时导航面弄没（后续全 off-mesh），
## 所以 v2 只改属性 + map_force_update + 等待帧，不手动 rebake。
## 基线单位：主基地（radius=7.0 世界 footprint，global_scale=1，verts=8）
## 预测：radius 口径 → 9.8m；vertices 口径 → vertices世界外缘 + 2.8

var _match: Node
var _map_rid: RID
var _agent := 2.8
var _cc: Node3D
var _ob: Node


func _ready():
	var settings = load("res://source/data-model/MatchSettings.gd").new()
	var human = load("res://source/data-model/PlayerSettings.gd").new()
	human.controller = Constants.PlayerType.HUMAN
	human.color = Constants.Player.COLORS[0]
	settings.players.append(human)
	settings.visible_player = 0
	_match = load("res://source/match/Match.tscn").instantiate()
	_match.settings = settings
	_match.map = load("res://source/match/maps/PlainAndSimple.tscn").instantiate()
	add_child(_match)
	get_tree().current_scene = _match
	for _f in range(300):
		await get_tree().physics_frame

	var region = _match.get_node_or_null("Navigation/Terrain/NavigationRegion3D")
	if region != null:
		_map_rid = region.get_navigation_map()
		if region.get("navigation_mesh") != null:
			_agent = float(region.get("navigation_mesh").get("agent_radius"))
	var human_node: Node = _match.get_node("Players").get_children()[0]
	for u in human_node.get_children():
		if u.name.begins_with("Unit_") and u.get("radius") != null and float(u.get("radius")) > 5.0:
			_cc = u
			break
	for sub in _cc.find_children("*", "NavigationObstacle3D", true, false):
		_ob = sub
		break
	print("[CARVE] agent=%.3f cc=%s pos=%s ob=%s" % [_agent, _cc.name, str(_cc.global_position), _ob.name])
	_dump("基线")
	await _measure_all("基线")

	# 对照 A：关掉 affect_navigation_mesh（洞应消失 = 洞确实由这个障碍挖的）
	_ob.set("affect_navigation_mesh", false)
	await _settle()
	_dump("affect=false")
	await _measure_all("affect=false")
	_ob.set("affect_navigation_mesh", true)
	await _settle()
	_dump("affect=true 恢复")
	await _measure_all("affect=true 恢复")

	# 对照 B：只把 radius 从 7.0 改到 1.0，vertices 不动
	_ob.set("radius", 1.0)
	await _settle()
	_dump("radius=1.0")
	await _measure_all("radius=1.0")
	_ob.set("radius", 7.0)
	await _settle()

	# 对照 C：vertices 清空
	_ob.set("vertices", PackedVector3Array())
	await _settle()
	_dump("verts=0")
	await _measure_all("verts=0")
	get_tree().quit(0)


func _settle() -> void:
	if _map_rid.is_valid():
		NavigationServer3D.map_force_update(_map_rid)
	for _f in range(150):
		await get_tree().physics_frame


func _dump(tag: String) -> void:
	var verts: PackedVector3Array = _ob.get("vertices")
	var outer := 0.0
	var lines: Array = []
	var xf: Transform3D = _ob.global_transform
	for v in verts:
		var w: Vector3 = xf * v
		var r := Vector2(w.x - _cc.global_position.x, w.z - _cc.global_position.z).length()
		outer = maxf(outer, r)
		lines.append("(%.2f,%.2f)" % [w.x - _cc.global_position.x, w.z - _cc.global_position.z])
	print("[CARVE] %s: radius=%.2f gscale=%.2f verts=%d verts世界外缘=%.2f affect=%s" % [
		tag, float(_ob.get("radius")), xf.basis.get_scale().x, verts.size(), outer,
		str(_ob.get("affect_navigation_mesh"))])
	if verts.size() > 0:
		print("[CARVE]   verts世界坐标(相对圆心): " + ", ".join(lines).substr(0, 300))


func _measure_all(tag: String) -> void:
	var dirs := {"+X": Vector3(1, 0, 0), "-X": Vector3(-1, 0, 0), "+Z": Vector3(0, 0, 1), "-Z": Vector3(0, 0, -1)}
	var out: Array = []
	for key in dirs:
		var d := _boundary(dirs[key])
		out.append("%s=%.1f" % [key, d])
	print("[CARVE]   %s 洞边界: %s" % [tag, ", ".join(out)])


func _boundary(dir: Vector3) -> float:
	var c: Vector3 = _cc.global_position
	var d := 1.0
	while d <= 45.0:
		var p: Vector3 = c + dir * d
		var closest: Vector3 = NavigationServer3D.map_get_closest_point(_map_rid, p)
		if Vector2(closest.x - p.x, closest.z - p.z).length() < 0.35:
			return d
		d += 0.5
	return -1.0
