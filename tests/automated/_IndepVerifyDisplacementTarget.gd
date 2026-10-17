extends Node

## 取证：被建筑覆盖的友军"驱逐后停在 2.27m"到底是**规划短了**还是**执行没走到**。
##
## 复现 `StructurePlacementSmokeTest` 的几何：坦克放在主基地边缘，炮塔**直接压在坦克身上**，
## `Place()` 会算驱逐落点并下 `request_legacy_move`。测试断言结束时坦克距建筑中心 2.27m，
## 而 hull-to-hull 需要 >3.43m。
##
## 要区分两种完全不同的修法：
##   A. 规划目标本身就近（`_raw_target` 距建筑 ≈2.3m）⇒ 改 `PlanDisplacements` 的几何口径；
##   B. 规划目标够远但没走到（`_raw_target` ≈4m，实际停在 2.3m）⇒ 改执行/到位/被阻挡处理。
## 本探针把每一帧的 `_raw_target` / `_committed_target` / 实际位置都打出来。

const MatchScene = preload("res://tests/manual/TestOneUnit.tscn")
const TurretScene = preload("res://source/match/units/AntiGroundTurret.tscn")
const CCScene = preload("res://source/match/units/CommandCenter.tscn")

var _match: Node = null


func _ready():
	get_tree().create_timer(120.0).timeout.connect(func():
		print("[DISP] 看门狗超时")
		get_tree().quit(1))
	_match = MatchScene.instantiate()
	add_child(_match)
	await get_tree().process_frame
	await get_tree().physics_frame
	var human = _match.get_node("Players/Human")
	var runtime = _match.get_node("StructurePlacementRuntime")
	var tank = _find_tank(human)
	if tank == null:
		print("[DISP] 夹具里没有坦克")
		get_tree().quit(0)
		return
	var cc: Node3D = human.get_node_or_null("CommandCenter") as Node3D
	if cc == null:
		cc = CCScene.instantiate()
		_match.call("_setup_and_spawn_unit", cc,
			Transform3D(Basis.IDENTITY, Vector3(40.0, 0.0, 28.0)), human, false)
		if cc.has_method("mark_as_constructed"):
			cc.mark_as_constructed()
		for _i in 30:
			await get_tree().physics_frame
	var turret_probe = TurretScene.instantiate()
	var turret_r: float = float(turret_probe.get("radius"))
	turret_probe.free()
	var cc_r: float = float(cc.get("radius"))
	var stand_off: float = cc_r + turret_r + 0.6
	tank.global_position = cc.global_position + Vector3(stand_off, 0.0, 0.0)
	print("[DISP] CC=%s r=%.2f 炮塔r=%.2f 坦克起点=%s（距CC %.2f）" % [
		str(cc.global_position), cc_r, turret_r, str(tank.global_position), stand_off])
	var cost = _match.get_node("BalanceConfigRuntime").GetConstructionCost(TurretScene)
	human.add_resources({"resource_a": 3000}, "ScriptedAdjustment")
	var placed = runtime.Place(human, TurretScene,
		Transform3D(Basis.IDENTITY, tank.global_position), cost)
	var structure = placed.get("structure")
	if structure == null:
		print("[DISP] Place 未返回建筑，无法测")
		get_tree().quit(0)
		return
	print("[DISP] accepted=%s displaced_ids=%s 建筑=%s" % [
		str(placed.get("accepted")), str(placed.get("displaced_unit_ids")),
		str(structure.global_position)])
	var mvm = tank.find_child("Movement", true, false)
	if mvm == null:
		print("[DISP] 坦克没有 Movement 子节点")
		get_tree().quit(0)
		return
	var last_raw = null
	for frame in range(180):
		await get_tree().physics_frame
		var raw = mvm.get("_raw_target")
		var committed = mvm.get("_committed_target")
		if raw != null:
			last_raw = raw
		if frame % 20 == 0 or frame == 179:
			print("  f=%3d pos=%s d_struct=%.2f raw=%s d_raw=%.2f committed=%s action=%s" % [
				frame, str(tank.global_position),
				_planar(tank.global_position, structure.global_position),
				str(raw),
				_planar(tank.global_position, raw) if raw != null else -1.0,
				str(committed), _action_name(tank)])
			if frame <= 20:
				# `arrive_radius = max(radius, 0.35)` 用的是 **Movement 自己的 radius**，
				# 而 `_begin_narrow_pass` 会临时改写它（Movement.gd:2305-2306）。
				# 这里同时打印单位半径与移动半径：两者一旦不等，"到达"判据就被撑大，
				# 单位会在离目标还有 arrive_radius 的地方直接判到达。
				var path = mvm.get("_logic_path")
				var path_size := -1
				if path != null:
					path_size = path.size()
				print("      unit.radius=%s movement.radius=%s ⇒ arrive_radius=%.2f | target_desired_distance=%s path_size=%s end_emitted=%s" % [
					str(tank.get("radius")), str(mvm.get("radius")),
					maxf(float(mvm.get("radius")), 0.35),
					str(mvm.get("target_desired_distance")),
					str(path_size),
					str(mvm.get("_movement_end_emitted"))])
	print("[DISP] 最终：距建筑 %.2fm，Movement 目标距建筑 %.2fm" % [
		_planar(tank.global_position, structure.global_position),
		_planar(last_raw, structure.global_position) if last_raw != null else -1.0])
	# 移动层自己就有终态事件环形缓冲（`_terminal_events`）：直接读它，
	# 不需要往产品代码里塞 print。它会告诉我们这一趟到底是以什么理由结束的。
	var events = mvm.get("_terminal_events")
	if events is Array:
		for ev in events:
			if not (ev is Dictionary):
				continue
			var ev_target: Vector3 = ev.get("resolved_target", Vector3.INF)
			var ev_pos: Vector3 = ev.get("pos", Vector3.INF)
			print("  [TERM] reason=%s tick=%s 终态目标距建筑=%.2f 停下时距建筑=%.2f 距终态目标=%.2f" % [
				str(ev.get("reason")), str(ev.get("server_tick")),
				_planar(ev_target, structure.global_position),
				_planar(ev_pos, structure.global_position),
				_planar(ev_pos, ev_target)])
	else:
		print("  [TERM] 没有 _terminal_events 可读")
	get_tree().quit(0)


func _planar(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()


func _action_name(unit: Node) -> String:
	var action = unit.get("action")
	if action == null:
		return "<null>"
	if action.get_script() == null:
		return "<anon>"
	return str(action.get_script().resource_path).get_file()


func _find_tank(human: Node) -> Node3D:
	for child in human.get_children():
		if child is Node3D and str(child.get("unit_type_id")) == "tank":
			return child
		if child is Node3D and child.get_script() != null \
				and "Tank" in str(child.get_script().resource_path):
			return child
	return null
