extends Node

## 炮塔 vs 建筑：几何的世界缩放到底怎么来的？（2026-09-30 第 5 轮）
## 打印真实建筑 root/几何的世界缩放，与蓝图 ghost 对比，判定补偿因子应为多少。

const ITEMS := {
	"CommandCenter": ["res://source/match/units/CommandCenter.tscn", "Geometry"],
	"AntiGroundTurret": ["res://source/match/units/AntiGroundTurret.tscn", "DetachTransform/Geometry"],
}
const MAP_SCENE := "res://source/match/maps/PlainAndSimple.tscn"


func _ready():
	var settings = load("res://source/data-model/MatchSettings.gd").new()
	var hs = load("res://source/data-model/PlayerSettings.gd").new()
	hs.controller = Constants.PlayerType.HUMAN
	hs.color = Constants.Player.COLORS[0]
	settings.players.append(hs)
	settings.visible_player = 0
	var m: Node = load("res://source/match/Match.tscn").instantiate()
	m.settings = settings
	m.map = load(MAP_SCENE).instantiate()
	add_child(m)
	get_tree().current_scene = m
	for _f in range(240):
		await get_tree().physics_frame
	var human: Node = m.get_node("Players").get_children()[0]
	for key in ITEMS:
		var prototype: PackedScene = load(ITEMS[key][0])
		var geo_path: String = ITEMS[key][1]
		# 蓝图场景（清单映射）
		var bp_path: String = "res://source/match/units/structure-geometries/" + String(key) + ".tscn"
		var real: Node3D = prototype.instantiate()
		m.call("_setup_and_spawn_unit", real, Transform3D(Basis.IDENTITY, Vector3(150.0, 0.0, 150.0)), human, false)
		for _f in range(5):
			await get_tree().physics_frame
		var geo: Node3D = real.get_node_or_null(geo_path)
		print("[SC] %s 真实: root local=%s global=%s | geo(%s) local=%s global=%s" % [
			key, str(real.scale), str(real.global_transform.basis.get_scale()), geo_path,
			str(geo.scale) if geo != null else "-",
			str(geo.global_transform.basis.get_scale()) if geo != null else "-"])
		var ghost: Node3D = load(bp_path).instantiate()
		add_child(ghost)
		await get_tree().physics_frame
		var ggeo: Node3D = ghost if ghost.name == "Geometry" else ghost.get_node_or_null("Geometry")
		print("[SC] %s 蓝图: root local=%s global=%s | 首层=%s" % [
			key, str(ghost.scale), str(ghost.global_transform.basis.get_scale()),
			str(ggeo.scale) if ggeo != null else "-"])
		var probe: Node3D = prototype.instantiate()
		print("[SC] %s 原型(未入树): root scale=%s | geo local=%s" % [
			key, str(probe.scale),
			str(probe.get_node_or_null(geo_path).scale) if probe.get_node_or_null(geo_path) != null else "-"])
		probe.free()
		ghost.queue_free()
		real.queue_free()
		await get_tree().process_frame
	get_tree().quit(0)
