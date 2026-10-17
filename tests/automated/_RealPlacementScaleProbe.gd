extends Node

## 真实放置链路的缩放验证（2026-09-30）。
## 走玩家同一条路：_start_structure_placement(原型) → 摆 ghost → _finish_structure_placement()，
## 然后量落地建筑的 root scale / Visual 世界缩放 / 碰撞世界半径。
## 背景：ghost 带 Visual 缩放（建筑 3.0），若 Place 把原始 transform 交给出生路径，
## 落地建筑会变成 root=3、视觉 9 倍、车厂碰撞半径 19.95m（应 6.65）。

const MAP_SCENE := "res://source/match/maps/PlainAndSimple.tscn"
const FACTORY := "res://source/match/units/VehicleFactory.tscn"


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
	var handler: Node = human.get_node("StructurePlacementHandler")
	var before: Array = human.get_children()
	handler.call("_start_structure_placement", load(FACTORY))
	await get_tree().physics_frame
	var ghost = handler.get("_active_blueprint_node")
	if ghost == null:
		print("[REALPLACE] ✗ 蓝图未创建")
		get_tree().quit(1)
		return
	print("[REALPLACE] ghost scale=", str(ghost.scale), "（应 = Visual 缩放 3）")
	var cc: Node3D = null
	for u in before:
		if str(u.get("unit_type_id")) == "command_center":
			cc = u
	ghost.global_position = cc.global_position + Vector3(17.0, 0.0, 0.0)
	await get_tree().physics_frame
	handler.call("_finish_structure_placement")
	for _f in range(6):
		await get_tree().physics_frame
	var built: Node3D = null
	for u in human.get_children():
		if not before.has(u) and str(u.get("unit_type_id")) == "vehicle_factory":
			built = u
	if built == null:
		print("[REALPLACE] ✗ 未生成车厂")
		get_tree().quit(1)
		return
	var geo: Node3D = built.get_node_or_null("Geometry")
	var col: Node3D = built.get_node_or_null("CollisionShape3D")
	var colRadius := 0.0
	if col != null and col is CollisionShape3D and (col as CollisionShape3D).shape is CylinderShape3D:
		colRadius = (col as CollisionShape3D).shape.radius * col.global_transform.basis.get_scale().x
	print("[REALPLACE] 落地建筑 root scale=", str(built.scale), "（应 1）")
	print("[REALPLACE] Visual 世界缩放=", str(geo.global_transform.basis.get_scale() if geo != null else "?") , "（应 3）")
	print("[REALPLACE] 碰撞世界半径=%.2f（应 6.65；修前实测 19.95）" % colRadius)
	print("[REALPLACE] 判定: ", "✓ 通过" if (is_equal_approx(built.scale.x, 1.0) and absf(colRadius - 6.65) < 0.1) else "✗ 仍不对")
	get_tree().quit(0)
