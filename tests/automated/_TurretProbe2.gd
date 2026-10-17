extends Node

## 炮塔视觉偏移定位探针（2026-09-30 第 2 轮）。
## 现象：尺寸审计里 AntiGroundTurret 的 Geometry 世界外缘 797m，而同类单位（Worker/Tank）正常。
## 本探针把 unit / DetachTransform / Geometry / PositionSynchronizer / 首个网格的
## global_position 逐帧打出来，并加一个 Worker 作对照。

const MAP_SCENE := "res://source/match/maps/PlainAndSimple.tscn"


func _ready():
	var settings = load("res://source/data-model/MatchSettings.gd").new()
	var human_settings = load("res://source/data-model/PlayerSettings.gd").new()
	human_settings.controller = Constants.PlayerType.HUMAN
	human_settings.color = Constants.Player.COLORS[0]
	settings.players.append(human_settings)
	settings.visible_player = 0
	var m: Node = load("res://source/match/Match.tscn").instantiate()
	m.settings = settings
	m.map = load(MAP_SCENE).instantiate()
	add_child(m)
	get_tree().current_scene = m
	for _f in range(240):
		await get_tree().physics_frame
	var human: Node = m.get_node("Players").get_children()[0]
	print("[TP] match ready, human=", human.name)

	await _probe(m, human, "res://source/match/units/AntiGroundTurret.tscn", "AntiGroundTurret", 0)
	await _probe(m, human, "res://source/match/units/Worker.tscn", "Worker", 20)
	get_tree().quit(0)


func _probe(match_node: Node, human: Node, path: String, label: String, offset_x: float) -> void:
	var unit: Node3D = load(path).instantiate()
	var at := Vector3(1000.0 + offset_x, 0.0, 1000.0)
	match_node.call("_setup_and_spawn_unit", unit, Transform3D(Basis.IDENTITY, at), human, false)
	for i in range(30):
		await get_tree().physics_frame
		if i == 0 or i == 5 or i == 29:
			_report(unit, label, i, at)
	unit.queue_free()
	for _f in range(5):
		await get_tree().physics_frame


func _report(unit: Node3D, label: String, frame: int, at: Vector3) -> void:
	var det := unit.get_node_or_null("DetachTransform")
	var geo := unit.get_node_or_null("DetachTransform/Geometry")
	var sync := unit.get_node_or_null("PositionSynchronizer")
	var mesh: Node3D = null
	if geo != null:
		for child in geo.get_children():
			if child is Node3D:
				mesh = child
				break
	print("[TP] %s f=%d 期望=%s" % [label, frame, str(at)])
	print("[TP]   unit=%s scale=%s" % [str(unit.global_position), str(unit.global_transform.basis.get_scale())])
	if det != null:
		print("[TP]   DetachTransform=%s" % str(det.global_position))
	if sync != null:
		print("[TP]   PositionSynchronizer=%s" % str(sync.global_position))
	if geo != null:
		print("[TP]   Geometry=%s scale=%s" % [
			str(geo.global_position), str(geo.global_transform.basis.get_scale())])
	else:
		print("[TP]   Geometry=<缺失>")
	if mesh != null:
		print("[TP]   mesh[%s]=%s" % [mesh.name, str(mesh.global_position)])
	# 与该单位原点的 XZ 距离
	if geo != null:
		var d := Vector2(geo.global_position.x - unit.global_position.x,
			geo.global_position.z - unit.global_position.z).length()
		print("[TP]   Geometry 距单位原点 XZ=%.2f" % d)
