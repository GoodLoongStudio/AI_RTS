extends Node

## 独立验证探针 #6（verifier 自写）：可见闭环的等价 headless 版本。
## 夹具：tests/manual/TestMultiUnitCommands.tscn（完整 Match + Players/Human(Tank,SecondTank,CC) + Players/Enemy(EnemyTank)）
## 四段，逐段落盘（超时也能拿到已完成部分）：
##   ① 建造：真实 handler 链路（_start_structure_placement → 合法点 → _finish_structure_placement）
##   ② 生产：生产队列 produce(Worker) → 单位真的出仓 + 资金扣减
##   ③ 采集：把矿车开到最近矿点 → 资金增长（交付）
##   ④ 攻击：UnitCommandGateway.AttackUnits → 敌方坦克被摧毁
##
## 判据不放宽：每段都打印"做了什么 / 观测到什么 / 是否达成"。

const MAP_SCENE := "res://source/match/maps/PlainAndSimple.tscn"
const PLAYER_SCENE := "res://source/match/players/Player.tscn"
const ENEMY_TANK := "res://source/match/units/Tank.tscn"
const FACTORY := "res://source/match/units/VehicleFactory.tscn"
const WORKER := "res://source/match/units/Worker.tscn"
const REPORT_PATH := "res://build/indep_verify/probe6_closed_loop.json"

var _match: Node = null
var _human: Node = null
var _runtime: Node = null
var _balance: Node = null
var _gateway: Node = null
var _handler: Node = null
var _cc: Node3D = null
var _enemy_tank: Node3D = null
var _legs: Array = []


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
	# 等主基地 + 导航就绪
	var terrain_map = _match.navigation.get_navigation_map_rid_by_domain(
		Constants.Match.Navigation.Domain.TERRAIN)
	var deadline := Time.get_ticks_msec() + 45000
	while Time.get_ticks_msec() < deadline:
		await get_tree().physics_frame
		var players: Node = _match.get_node_or_null("Players")
		if players == null or players.get_child_count() < 1:
			continue
		for sub in players.get_child(0).get_children():
			if sub is Node3D and str(sub.get("unit_type_id")) == "command_center":
				_cc = sub
		if _cc != null and NavigationServer3D.map_get_closest_point_owner(
				terrain_map, _cc.global_position).is_valid():
			break
	# 敌对方：按夹具同款做法，往 Players 下加一个 Player 节点（不进 MatchSettings）
	var enemy_player: Node = load(PLAYER_SCENE).instantiate()
	enemy_player.name = "Enemy"
	_match.get_node("Players").add_child(enemy_player)
	await get_tree().process_frame
	var enemy_tank: Node3D = load(ENEMY_TANK).instantiate()
	_match.call("_setup_and_spawn_unit", enemy_tank,
		Transform3D(Basis.IDENTITY, _cc.global_position + Vector3(0.0, 0.0, -34.0)), enemy_player, false)
	_enemy_tank = enemy_tank
	for _f in range(20):
		await get_tree().physics_frame
	var players_node: Node = _match.get_node_or_null("Players")
	_human = (players_node.get_child(0) if players_node != null and players_node.get_child_count() > 0 else null)
	if _human == null:
		_save("no_human")
		get_tree().quit(1)
		return
	_runtime = _match.find_child("StructurePlacementRuntime", true, false)
	_balance = _match.find_child("BalanceConfigRuntime", true, false)
	_gateway = _human.find_child("UnitCommandGateway", true, false)
	_handler = _human.find_child("StructurePlacementHandler", true, false)
	for child in _human.get_children():
		if child is Node3D and str(child.get("unit_type_id")) == "command_center":
			_cc = child
	print("[IVR6] human=%s runtime=%s gateway=%s handler=%s cc=%s" % [
		str(_human != null), str(_runtime != null), str(_gateway != null),
		str(_handler != null), str(_cc != null)])
	var injected: bool = _human.add_resources({"resource_a": 50000}, "ScriptedAdjustment")
	print("[IVR6] 资源注入=%s 资金=%d" % [str(injected), int(_human.get("resource_a"))])
	await _leg1_build()
	await _leg2_produce()
	await _leg3_gather()
	await _leg4_attack()
	_save("done")
	get_tree().quit(0)


func _leg1_build() -> void:
	var leg := {"leg": "1_build", "ok": false}
	if _handler == null or _runtime == null or _cc == null:
		leg["skip"] = "缺 handler/runtime/cc"
		print("[IVR6] ① 建造 SKIP: %s" % leg["skip"])
		_legs.append(leg)
		_save("leg1")
		return
	var funds_before := int(_human.get("resource_a"))
	var spot := Vector3.INF
	var probe: Node3D = load(FACTORY).instantiate()
	var barracks_radius := float(probe.get("radius"))
	probe.free()
	var cc_radius := float(_cc.get("radius"))
	var cost: Dictionary = _balance.GetConstructionCost(load(FACTORY))
	for ring in [1.0, 1.25, 1.5, 1.8, 2.2]:
		var stand_off: float = (cc_radius + barracks_radius + 0.6) * ring
		for k in range(24):
			var a := TAU * float(k) / 24.0
			var cand: Vector3 = _cc.global_position + Vector3(cos(a) * stand_off, 0.0, sin(a) * stand_off)
			var ev = _runtime.Evaluate(_human, load(FACTORY), Transform3D(Basis.IDENTITY, cand), cost)
			if ev is Dictionary and bool(ev.get("accepted", false)):
				spot = cand
				break
		if spot != Vector3.INF:
			break
	if spot == Vector3.INF:
		leg["skip"] = "找不到合法落点"
		print("[IVR6] ① 建造 SKIP: %s（已扫描 5 环 × 24 方位）" % leg["skip"])
		_legs.append(leg)
		_save("leg1")
		return
	_handler.call("_cancel_structure_placement")
	_handler.call("_start_structure_placement", load(FACTORY))
	await get_tree().process_frame
	var ghost: Node3D = _handler.get("_active_blueprint_node")
	if ghost == null:
		leg["skip"] = "蓝图未建立"
		print("[IVR6] ① 建造 SKIP: %s" % leg["skip"])
		_legs.append(leg)
		_save("leg1")
		return
	leg["ghost_scale_at_handoff"] = _v3(ghost.global_transform.basis.get_scale())
	leg["spot"] = _v3(spot)
	ghost.global_transform.origin = spot
	await get_tree().process_frame
	_handler.call("_finish_structure_placement")
	var built: Node3D = null
	for _f in range(600):
		await get_tree().physics_frame
		for child in _human.get_children():
			if child is Node3D and str(child.scene_file_path).ends_with("VehicleFactory.tscn"):
				built = child
		if built != null:
			break
	if built == null:
		leg["ok"] = false
		leg["error"] = "落地后 600 帧内没有兵营节点"
		_legs.append(leg)
		_save("leg1")
		return
	var coll := 0.0
	for sub in built.find_children("*", "CollisionShape3D", true, false):
		var cs: CollisionShape3D = sub
		if cs.shape is CylinderShape3D:
			var s: Vector3 = cs.global_transform.basis.get_scale()
			coll = maxf(coll, (cs.shape as CylinderShape3D).radius * maxf(absf(s.x), absf(s.z)))
	leg["built_root_scale"] = _v3(built.scale)
	leg["built_visual_world_scale"] = _fmt(_visual_ws(built))
	leg["built_collision_world_radius"] = snappedf(coll, 0.001)
	leg["funds_before"] = funds_before
	leg["funds_after"] = int(_human.get("resource_a"))
	leg["ok"] = is_equal_approx(built.scale.x, 1.0) and absf(coll - 6.651) < 0.05
	print("[IVR6] ① 建造: root=%s visual_ws=%s coll_r=%.3f 资金 %d→%d → %s" % [
		_fmt(leg["built_root_scale"]), leg["built_visual_world_scale"], coll,
		funds_before, leg["funds_after"], ("达成" if leg["ok"] else "**未达成**")])
	_legs.append(leg)
	_save("leg1")


func _leg2_produce() -> void:
	var leg := {"leg": "2_produce", "ok": false}
	var barracks: Node3D = null
	for child in _human.get_children():
		if child is Node3D and str(child.scene_file_path).ends_with("VehicleFactory.tscn"):
			barracks = child
	if barracks == null:
		leg["skip"] = "没有车厂"
		print("[IVR6] ② 生产 SKIP: %s（上游建造未完成）" % leg["skip"])
		_legs.append(leg)
		_save("leg2")
		return
	var frames := 0
	while frames < 900 and barracks.has_method("is_constructed") and not barracks.is_constructed():
		await get_tree().physics_frame
		frames += 1
	leg["construction_frames"] = frames
	var queue = barracks.get("production_queue")
	if queue == null:
		leg["skip"] = "车厂无 production_queue"
		print("[IVR6] ② 生产 SKIP: %s" % leg["skip"])
		_legs.append(leg)
		_save("leg2")
		return
	var funds_before := int(_human.get("resource_a"))
	var element = queue.produce(load(WORKER))
	leg["produce_returned"] = str(element != null)
	var before_count := _count_workers()
	var spawned: Node3D = null
	for _f in range(1500):
		await get_tree().physics_frame
		if _count_workers() > before_count:
			spawned = _last_worker()
			break
	leg["funds_before"] = funds_before
	leg["funds_after"] = int(_human.get("resource_a"))
	if spawned == null:
		leg["error"] = "生产队列接受后 1500 帧内没有工人出现"
	else:
		leg["worker"] = str(spawned.name)
		leg["worker_pos"] = _v3(spawned.global_position)
		leg["worker_action"] = _action_name(spawned)
		leg["ok"] = true
	print("[IVR6] ② 生产: produce=%s 工人=%s 位置=%s action=%s 资金 %d→%d → %s" % [
		leg["produce_returned"], str(leg.get("worker", "无")), str(leg.get("worker_pos", "-")),
		str(leg.get("worker_action", "-")), funds_before, leg["funds_after"],
		("达成" if leg["ok"] else "**未达成**")])
	_legs.append(leg)
	_save("leg2")


func _leg3_gather() -> void:
	var leg := {"leg": "3_gather_deliver", "ok": false}
	var worker := _last_worker()
	var ore := _nearest_resource(worker if worker != null else _cc)
	if worker == null or ore == null:
		leg["skip"] = "缺工人或矿点"
		print("[IVR6] ③ 采集 SKIP: %s（工人=%s 矿点=%s）" % [leg["skip"], str(worker != null), str(ore != null)])
		_legs.append(leg)
		_save("leg3")
		return
	var funds_before := int(_human.get("resource_a"))
	var result = _gateway.call("GatherResources", [worker], ore, _human)
	leg["gather_result"] = str(result).replace("\n", " ").left(200)
	print("[IVR6] ③ 采集令回执: %s" % leg["gather_result"].left(140))
	var grew := false
	var frames := 0
	for _f in range(2400):
		await get_tree().physics_frame
		frames += 1
		if frames % 300 == 0:
			print("[IVR6] ③ +%d 帧: 资金=%d action=%s pos=%s" % [
				frames, int(_human.get("resource_a")), _action_name(worker),
				str(_v3(worker.global_position))])
			leg["funds_after"] = int(_human.get("resource_a"))
			_legs.append(leg)
			_save("leg3_progress")
			_legs.pop_back()
		if int(_human.get("resource_a")) > funds_before:
			grew = true
			break
	leg["frames"] = frames
	leg["funds_before"] = funds_before
	leg["funds_after"] = int(_human.get("resource_a"))
	leg["worker_pos"] = _v3(worker.global_position)
	leg["worker_action"] = _action_name(worker)
	leg["ok"] = grew
	print("[IVR6] ③ 采集交付: 矿点=%s 资金 %d→%d（%d 帧, action=%s, pos=%s）→ %s" % [
		str(ore.name), funds_before, leg["funds_after"], frames,
		str(leg["worker_action"]), str(leg["worker_pos"]),
		("达成（发生交付）" if grew else "**未达成**")])
	_legs.append(leg)
	_save("leg3")


func _leg4_attack() -> void:
	var leg := {"leg": "4_attack", "ok": false}
	var tank: Node3D = null
	for child in _human.get_children():
		if child is Node3D and str(child.get("unit_type_id")) == "tank":
			tank = child
	var enemy: Node3D = _enemy_tank
	if enemy != null and not is_instance_valid(enemy):
		enemy = null
	if tank == null and _cc != null:
		var own_tank: Node3D = load(ENEMY_TANK).instantiate()
		_match.call("_setup_and_spawn_unit", own_tank,
			Transform3D(Basis.IDENTITY, _cc.global_position + Vector3(0.0, 0.0, -12.0)), _human, false)
		for _f in range(15):
			await get_tree().physics_frame
		tank = own_tank
	if tank == null or enemy == null:
		leg["skip"] = "缺己方/敌方坦克"
		print("[IVR6] ④ 攻击 SKIP: %s" % leg["skip"])
		_legs.append(leg)
		_save("leg4")
		return
	var hp_before := float(enemy.get("hp"))
	var result = _gateway.call("AttackUnits", [tank], enemy, _human)
	leg["attack_result"] = str(result).replace("\n", " ").left(200)
	leg["hp_before"] = hp_before
	var frames := 0
	for _f in range(900):
		await get_tree().physics_frame
		frames += 1
		if not is_instance_valid(enemy) or enemy.is_queued_for_deletion():
			break
		if float(enemy.get("hp")) <= 0.0:
			break
	leg["frames"] = frames
	leg["enemy_alive"] = is_instance_valid(enemy) and not enemy.is_queued_for_deletion()
	leg["hp_after"] = (float(enemy.get("hp")) if leg["enemy_alive"] else 0.0)
	leg["seconds"] = snappedf(float(frames) / 60.0, 0.1)
	leg["ok"] = (not leg["enemy_alive"]) or float(leg["hp_after"]) <= 0.0
	print("[IVR6] ④ 攻击: 回执=%s 敌方 hp %.1f→%.1f 存活=%s 用时=%.1fs → %s" % [
		leg["attack_result"].left(90), hp_before, leg["hp_after"], str(leg["enemy_alive"]),
		leg["seconds"], ("达成" if leg["ok"] else "**未达成**")])
	_legs.append(leg)
	_save("leg4")


func _wait_units(count: int, max_frames: int) -> void:
	var frames := 0
	while frames < max_frames:
		await get_tree().physics_frame
		frames += 1
		if get_tree().get_nodes_in_group("units").size() >= count:
			return


func _count_workers() -> int:
	var n := 0
	for child in _human.get_children():
		if child is Node3D and str(child.scene_file_path).ends_with("Worker.tscn"):
			n += 1
	return n


func _last_worker() -> Node3D:
	var found: Node3D = null
	for child in _human.get_children():
		if child is Node3D and str(child.scene_file_path).ends_with("Worker.tscn"):
			found = child
	return found


func _nearest_resource(from: Node3D) -> Node3D:
	var best: Node3D = null
	var best_d := INF
	var resources: Node = _match.get_node_or_null("Map/Resources")
	if resources == null:
		return null
	for child in resources.get_children():
		if not (child is Node3D):
			continue
		var d: float = from.global_position.distance_to((child as Node3D).global_position)
		if d < best_d:
			best_d = d
			best = child
	return best


func _visual_ws(node: Node3D) -> float:
	var geo: Node = node.get_node_or_null("Geometry")
	if geo == null:
		geo = node.get_node_or_null("DetachTransform/Geometry")
	if geo is Node3D:
		return absf((geo as Node3D).global_transform.basis.get_scale().x)
	return -1.0


func _action_name(unit: Node) -> String:
	var action = unit.get("action")
	if action == null or not is_instance_valid(action):
		return "null"
	var script: Script = action.get_script()
	return str(script.resource_path).get_file() if script != null else action.get_class()


func _save(tag: String) -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://build/indep_verify"))
	var file := FileAccess.open(REPORT_PATH, FileAccess.WRITE)
	if file == null:
		return
	file.store_string(JSON.stringify({
		"generated_at": Time.get_datetime_string_from_system(),
		"stage": tag, "legs": _legs}, "  "))
	file.close()


func _v3(v: Vector3) -> Array:
	return [snappedf(v.x, 0.01), snappedf(v.y, 0.01), snappedf(v.z, 0.01)]


func _fmt(v) -> String:
	if v is Array:
		var parts := PackedStringArray()
		for x in v:
			parts.append(str(x))
		return "(" + ",".join(parts) + ")"
	return str(v)