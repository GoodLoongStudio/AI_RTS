extends Node

## 建筑卡单位 · 内部状态取证探针（本轮新增，只读产品代码）
##
## 目的：单位被建筑挡住时，**为什么永久卡住而不自愈**。
## 已知事实（本轮实测，`_RefineryJamProbe` gap=2/6/10/14 四档完全相同）：
##   交付=0 卡住次数=3（全部 drop_overlap）卡住秒数≈126~171
##   而引擎自己的 recovery_stats：stall_detections=0 repaths=0 escapes=0 pocket_escapes=0
##   同时 RVO 探针：建筑 avoidance=false ⇒ 建筑根本不参与避障，唯一屏障是 navmesh carve 洞。
## ⇒ 独立测量说"卡了 171 秒"，引擎说"没检测到停滞"。本探针把卡住单位的**真实内部状态**打出来，
##   判定是哪一道门槛让它进不了脱困：
##   ① `Movement._begin_recovery()` 要求 `_committed_target != null`；
##   ② `Movement.gd:592` 的到达锁存 `_movement_end_emitted`（只在距目标 ≤ max(radius,0.35) 时才解锁）；
##   ③ 每帧脱困预算 `_consume_recovery_budget()`。
## 注意：属性在 **Movement 子节点**上（`unit.find_child("Movement", …)`），不在单位根上。

const MAP_SCENE := "res://source/match/maps/PlainAndSimple.tscn"
const REFINERY := "res://source/match/units/OreRefinery.tscn"
const WORKER := "res://source/match/units/Worker.tscn"


func _ready():
	var settings = load("res://source/data-model/MatchSettings.gd").new()
	var hs = load("res://source/data-model/PlayerSettings.gd").new()
	hs.controller = Constants.PlayerType.HUMAN
	hs.color = Constants.Player.COLORS[0]
	settings.players.append(hs)
	settings.visible_player = 0
	var match_node = load("res://source/match/Match.tscn").instantiate()
	match_node.settings = settings
	match_node.map = load(MAP_SCENE).instantiate()
	add_child(match_node)
	get_tree().current_scene = match_node
	var terrain_map: RID = match_node.navigation.get_navigation_map_rid_by_domain(
		Constants.Match.Navigation.Domain.TERRAIN)
	var deadline := Time.get_ticks_msec() + 25000
	var cc: Node3D = null
	while Time.get_ticks_msec() < deadline:
		await get_tree().physics_frame
		var players: Node = match_node.get_node_or_null("Players")
		if players == null or players.get_child_count() < 1:
			continue
		for sub in players.get_child(0).get_children():
			if sub is Node3D and sub.get_script() != null \
					and "CommandCenter" in str(sub.get_script().resource_path):
				cc = sub
		if cc != null and NavigationServer3D.map_get_closest_point_owner(
				terrain_map, cc.global_position).is_valid():
			break
	if cc == null:
		print("[STALL2] 对局未就绪")
		get_tree().quit(0)
		return
	var human: Node = match_node.get_node("Players").get_children()[0]

	# 矿场落在基地外侧、贴住基地的避让带；工人放在两者之间并被命令穿过矿场。
	var refinery: Node3D = load(REFINERY).instantiate()
	match_node.call("_setup_and_spawn_unit", refinery,
		Transform3D(Basis.IDENTITY, cc.global_position + Vector3(0.0, 0.0, 11.0)), human, false)
	var worker: Node3D = load(WORKER).instantiate()
	match_node.call("_setup_and_spawn_unit", worker,
		Transform3D(Basis.IDENTITY, cc.global_position + Vector3(0.0, 0.0, 15.5)), human, false)
	for _i in 90:
		await get_tree().physics_frame
	if terrain_map.is_valid():
		NavigationServer3D.map_force_update(terrain_map)

	# 命令工人走到矿场**另一侧**（必须穿过矿场占位）。移动命令在 Movement 子节点上。
	var goal: Vector3 = refinery.global_position + Vector3(0.0, 0.0, 9.0)
	var worker_mvm := _mvm(worker)
	if worker_mvm == null:
		print("[STALL2] 工人没有 Movement 子节点，无法下命令")
		get_tree().quit(0)
		return
	worker_mvm.call("move", goal)
	print("[STALL2] 基地=%s 矿场=%s 工人=%s 目标=%s" % [
		str(cc.global_position), str(refinery.global_position),
		str(worker.global_position), str(goal)])

	for round_index in 10:
		for _i in 30:
			await get_tree().physics_frame
		_dump(worker, refinery, round_index)
	print("[STALL2] done")
	get_tree().quit(0)


func _mvm(unit: Node) -> Node:
	return unit.find_child("Movement", true, false)


func _dump(unit: Node, obstacle: Node, round_index: int) -> void:
	var mvm := _mvm(unit)
	if mvm == null:
		print("[STALL2] round=%d 找不到 Movement 子节点" % round_index)
		return
	var committed = mvm.get("_committed_target")
	var raw = mvm.get("_raw_target")
	var target = mvm.get("target_position")
	var dist_to_committed := -1.0
	if committed != null:
		dist_to_committed = Vector2(unit.global_position.x - committed.x,
			unit.global_position.z - committed.z).length()
	print("  round=%d pos=%s dist_obstacle=%.2f" % [
		round_index, str(unit.global_position),
		(unit.global_position - obstacle.global_position).length()])
	print("    committed=%s raw=%s target_position=%s dist_to_committed=%.2f radius=%s" % [
		str(committed), str(raw), str(target), dist_to_committed, str(unit.get("radius"))])
	print("    movement_end_emitted=%s recovery_mode='%s' rounds=%s velocity=%.2f" % [
		str(mvm.get("_movement_end_emitted")), str(mvm.get("_recovery_mode")),
		str(mvm.get("_recovery_rounds")),
		float(unit.get("velocity").length()) if unit.get("velocity") != null else -1.0])
	var action = unit.get("action")
	var action_name := "<null>"
	if action != null and action.get_script() != null:
		action_name = str(action.get_script().resource_path).get_file()
	print("    action=%s resource_a=%s" % [action_name, str(unit.get("resource_a"))])
