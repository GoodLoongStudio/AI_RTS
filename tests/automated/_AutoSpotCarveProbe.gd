extends Node

## 自动选址（资源模式）carve 净空验证（2026-09-30）。
## 断言：resource 模式返回的落点，必须让它要服务的那颗矿留在
## **矿场自己的 carve 洞之外**（洞 = footprint + navmesh.agent_radius），
## 否则工人只能站到洞边、永远采不到矿（AI 建矿场 = 白建）。

const MAP_SCENE := "res://source/match/maps/PlainAndSimple.tscn"
const REFINERY := "res://source/match/units/OreRefinery.tscn"
const ORE := "res://source/match/units/non-player/ResourceA.tscn"


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
	# 在离基地足够远处放一颗"要扩张过去服务"的矿
	var ore: Node3D = load(ORE).instantiate()
	ore.resource_a = 5000
	m.get_node("Map/Resources").add_child(ore)
	ore.global_position = Vector3(40.0, 0.0, 48.0)   # 基地旁 20m：既能被相邻建造服务，又留出 carve 净空
	for _f in range(10):
		await get_tree().physics_frame
	var handler: Node = human.get_node("StructurePlacementHandler")
	var runtime: Object = handler.get("_placement_runtime")
	var result: Dictionary = runtime.FindAutoSpot(human, load(REFINERY), "resource", Vector3.INF, 0.0)
	print("[AUTOSPOT-CARVE] found=", result.get("found"), " pos=", str(result.get("pos")))
	if bool(result.get("found")):
		var pos: Vector3 = result.get("pos")
		var d: float = Vector2(pos.x - ore.global_position.x, pos.z - ore.global_position.z).length()
		var footprint: float = float(load(REFINERY).instantiate().get("radius"))
		var agent: float = 0.0
		var region = m.get_node_or_null("Navigation/Terrain/NavigationRegion3D")
		if region != null and region.get("navigation_mesh") != null:
			agent = float(region.get("navigation_mesh").get("agent_radius"))
		var clearance: float = footprint + agent
		print("[AUTOSPOT-CARVE] 落点距矿 %.2fm | footprint=%.2f agent=%.2f 洞半径=%.2f ⇒ %s" % [
			d, footprint, agent, clearance,
			("✓ 矿在洞外，工人可采" if d >= clearance else "✗ 矿仍在自己洞里，采不到")])
	else:
		print("[AUTOSPOT-CARVE] ✗ 未找到落点（issues 见上层日志）")
	get_tree().quit(0)
