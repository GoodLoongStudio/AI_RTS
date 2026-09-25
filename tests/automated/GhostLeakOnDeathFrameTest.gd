extends Node

## 迷雾残影"死亡后泄漏"复现（2026-09-23 六轮）。
##
## 前五轮全部证实"死亡 → 残影被清"，但用户仍看到死亡敌方建筑。差异在**时序**：
## `queue_free()` 是帧末延迟释放，建筑在死亡当帧仍在 units 组里。若可见性
## 处理器那 0.2s 一拍正好落在**同帧、死亡信号之后**，它会看到：
##   - 建筑还挂着 visible=true（上一拍留下的陈旧状态，玩家单位已撤离）
##   - 但没有任何己方 revealer 照到它（should_be_visible=false）
## → 判定"建筑脱视野"→ **给一座已死的建筑新建残影**。而 `_on_unit_died`
## 已经跑完了（那时残影还没生成），于是这个残影永远没人清——玩家就在原地
## 看到一个和刚打掉的一模一样的建筑，且**永久残留**。
##
## 本测试确定性地复现这个交错：同帧内先杀死建筑，再手动推进一步可见性更新
## （等价于引擎把 Handler 的 _physics_process 排在该单位之后）。

const MatchSettings = preload("res://source/data-model/MatchSettings.gd")
const TurretScene = preload("res://source/match/units/AntiGroundTurret.tscn")

const VISIBILITY_SETTLE_FRAMES := 60

var _failures := 0


func _check(cond: bool, msg: String) -> void:
	if cond:
		print("[PASS] " + msg)
	else:
		_failures += 1
		print("[FAIL] " + msg)


func _ready():
	await get_tree().process_frame
	await get_tree().process_frame

	var settings = MatchSettings.new()
	var human = load("res://source/data-model/PlayerSettings.gd").new()
	human.controller = Constants.PlayerType.HUMAN
	human.color = Color.BLUE
	settings.players.append(human)
	var ai = load("res://source/data-model/PlayerSettings.gd").new()
	ai.controller = Constants.PlayerType.SIMPLE_CLAIRVOYANT_AI
	ai.color = Color.RED
	settings.players.append(ai)
	settings.visible_player = 0
	settings.visibility = MatchSettings.Visibility.PER_PLAYER

	var a_match = load("res://source/match/Match.tscn").instantiate()
	a_match.settings = settings
	a_match.map = load("res://source/match/maps/PlainAndSimple.tscn").instantiate()
	get_tree().root.add_child(a_match)
	get_tree().current_scene = a_match

	var deadline := Time.get_ticks_msec() + 90000
	var ready := false
	while Time.get_ticks_msec() < deadline:
		await get_tree().physics_frame
		var players: Node = a_match.get_node_or_null("Players")
		if players != null and players.get_child_count() >= 2:
			var ok := true
			for p in players.get_children():
				if p.get_child_count() == 0:
					ok = false
			if ok:
				ready = true
				break
	_check(ready, "对局应就绪")
	if not ready:
		_finish()
		return
	for _frame in range(240):
		await get_tree().physics_frame

	var players: Node = a_match.get_node("Players")
	var human_player = players.get_child(0)
	var runtime = a_match.get_node("StructurePlacementRuntime")
	var cost = a_match.get_node("BalanceConfigRuntime").GetConstructionCost(TurretScene)
	human_player.add_resources({"resource_a": 5000}, "ScriptedAdjustment")

	var human_cc: Node3D = null
	var human_worker: Node3D = null
	for child in human_player.get_children():
		if child is Node3D and str(child.get("unit_type_id")) == "command_center" and human_cc == null:
			human_cc = child
		if child is Node3D and str(child.get("unit_type_id")) == "worker" and human_worker == null:
			human_worker = child
	if human_cc == null or human_worker == null:
		_check(false, "人类应有指挥中心与工人")
		_finish()
		return
	var cc_pos: Vector3 = human_cc.global_position
	var cc_sight: float = float(human_cc.get("sight_range"))

	# 远离基地的落点：工人撤回后没有任何己方 revealer 照到它
	var spot := Vector3.ZERO
	var found := false
	for distance in [cc_sight + 30.0, cc_sight + 45.0, cc_sight + 60.0]:
		for sector in range(16):
			var angle := TAU * float(sector) / 16.0
			var candidate := Vector3(
				cc_pos.x + cos(angle) * distance, cc_pos.y, cc_pos.z + sin(angle) * distance
			)
			human_worker.global_position = candidate + Vector3(6, 0, 0)
			for _frame in range(6):
				await get_tree().physics_frame
			var probe: Dictionary = runtime.Evaluate(
				human_player, TurretScene, Transform3D(Basis.IDENTITY, candidate), cost
			)
			if bool(probe.get("accepted", false)):
				spot = candidate
				found = true
				break
		if found:
			break
	_check(found, "应能在远离基地处找到合法落点")
	if not found:
		_finish()
		return

	var placed: Dictionary = runtime.Place(human_player, TurretScene,
		Transform3D(Basis.IDENTITY, spot), cost)
	var turret = placed.get("structure")
	_check(turret != null and is_instance_valid(turret), "放置炮塔应成功")
	if turret == null:
		_finish()
		return
	var death_pos: Vector3 = (turret as Node3D).global_position
	if (turret as Node).is_in_group("revealed_units"):
		(turret as Node).remove_from_group("revealed_units")

	var handler: Node = a_match.find_child("UnitVisibilityHandler", true, false)
	_check(handler != null, "应有 UnitVisibilityHandler")
	if handler == null:
		_finish()
		return

	# 工人在场 → 建筑可见（陈旧 visible=true 的由来）
	for _frame in range(VISIBILITY_SETTLE_FRAMES):
		await get_tree().physics_frame
	var group_now: Array = get_tree().get_nodes_in_group("units")
	print("[DBG] settle 后: group_size=", group_now.size(),
		" turret_in_group_scan=", group_now.has(turret),
		" cache_dirty=", handler.get("_cache_dirty"),
		" cache_size=", (handler.get("_cached_units") as Array).size(),
		" elapsed=", handler.get("_update_elapsed"))
	_check((turret as Node3D).visible, "工人前出时建筑应可见")
	var before := _ghost_count(handler)
	_check(before == 0, "可见时不应有残影（实际 %d）" % before)

	# 工人撤离：把 Handler 的计时器清零，**阻止自然拍**在这一帧跑掉——
	# 这样建筑的 visible 停留在"陈旧 true"（上一拍的结果），正是泄漏需要的状态。
	human_worker.global_position = cc_pos + Vector3(6, 0, 0)
	handler.set("_update_elapsed", 0.0)

	print("[DBG] 撤离后、等一帧前: ghosts=", _ghost_count(handler),
		" turret.visible=", (turret as Node3D).visible)
	# ---- 关键交错：同帧内先死亡、再推进可见性更新 ----
	# 等下一个物理帧边界（自然拍已被清零计时器挡掉）
	await get_tree().physics_frame
	print("[DBG] 等一帧后: ghosts=", _ghost_count(handler),
		" turret.visible=", (turret as Node3D).visible)
	_check((turret as Node3D).visible, "死亡前建筑应仍是陈旧可见状态（复现前提）")
	(turret as Node3D).hp = 0  # 死亡：unit_died 已发、queue_free 已排（帧末才真释放）
	print("[DBG] 死亡后、手动拍前: ghosts=", _ghost_count(handler),
		" queued=", (turret as Node3D).is_queued_for_deletion())
	# 手动推进 Handler 的可见性一拍（引擎里它可能就排在该单位之后）
	handler.set("_update_elapsed", 1.0)
	var cached: Variant = handler.get("_cached_units")
	var names: Array = []
	for c in (cached as Array):
		names.append(str((c as Node).name))
	print("[DBG] cache size=", (cached as Array).size(),
		" turret.name=", (turret as Node).name,
		" turret_in_cache=", (cached as Array).has(turret),
		" physics_processing=", handler.is_physics_processing(),
		" tree_paused=", get_tree().paused,
		" handler_process_mode=", handler.process_mode,
		" elapsed_before=", handler.get("_update_elapsed"))
	await get_tree().physics_frame
	print("[DBG] elapsed_after_one_frame=", handler.get("_update_elapsed"),
		" cache_size_now=", (handler.get("_cached_units") as Array).size())
	handler._physics_process(0.21)
	print("[DBG] 手动拍后: turret-keyed ghosts=", _ghost_count_for(handler, turret))
	await get_tree().physics_frame
	await get_tree().physics_frame

	_check(not is_instance_valid(turret), "建筑应已释放")

	var leaked := _ghost_count_for(handler, turret)
	var ghost_paths := _ghost_paths_for(handler, turret)
	print("[INFO] 死亡建筑键控残影数 = ", leaked)
	for p in ghost_paths:
		print("[INFO]   leaked ghost: ", p)

	_check(leaked == 0,
		"死亡当帧不应给已死建筑生成残影（泄漏 %d 个：%s）—— 用户报的'死亡建筑还在'" % [
			leaked, "; ".join(ghost_paths)])

	# 泄漏的残影必须是可见网格且留在场景里（否则用户看不到）
	var meshes := _meshes_near(a_match, death_pos, 5.0)
	var ghost_meshes := 0
	for m in meshes:
		if str(m).find("UnitVisibilityHandler") >= 0:
			ghost_meshes += 1
	print("[INFO] 死亡位置附近的残影网格数 = ", ghost_meshes)
	_check(ghost_meshes == 0, "死亡位置不应有残影网格（实际 %d）" % ghost_meshes)

	_finish()


func _ghost_count(handler: Node) -> int:
	var mapping: Variant = handler.get("_structure_to_dummy_mapping")
	if not mapping is Dictionary:
		return 0
	var dict: Dictionary = mapping
	var count := 0
	for key in dict:
		if is_instance_valid(dict[key]):
			count += 1
	return count


## 只数"键就是这坐建筑"的残影（其他建筑的合法残影不算泄漏）。
func _ghost_count_for(handler: Node, unit) -> int:
	var mapping: Variant = handler.get("_structure_to_dummy_mapping")
	if not mapping is Dictionary:
		return 0
	var dict: Dictionary = mapping
	if not dict.has(unit):
		return 0
	return 1 if is_instance_valid(dict[unit]) else 0


func _ghost_paths_for(handler: Node, unit) -> Array:
	var out: Array = []
	var mapping: Variant = handler.get("_structure_to_dummy_mapping")
	if not mapping is Dictionary:
		return out
	var dict: Dictionary = mapping
	if dict.has(unit) and is_instance_valid(dict[unit]):
		out.append(str((dict[unit] as Node).get_path()))
	return out


## 扫描 Match 子树下所有 GeometryInstance3D，返回距 pos 多近距离内的可见网格描述。
func _meshes_near(a_match: Node, pos: Vector3, within: float) -> Array:
	var out: Array = []
	var stack: Array[Node] = [a_match]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		for child in node.get_children():
			stack.append(child)
		if node is GeometryInstance3D:
			var geo := node as GeometryInstance3D
			if not geo.visible:
				continue
			var node_pos: Vector3 = geo.global_position
			if Vector2(node_pos.x, node_pos.z).distance_to(Vector2(pos.x, pos.z)) <= within:
				out.append("%s @ %s (path=%s)" % [node.name,
					str(Vector2(node_pos.x, node_pos.z).round()), node.get_path()])
	return out


func _finish() -> void:
	if _failures == 0:
		print("Ghost leak on death frame: 0 failure(s)")
		get_tree().quit(0)
	else:
		print("Ghost leak on death frame: %d failure(s)" % _failures)
		get_tree().quit(1)
