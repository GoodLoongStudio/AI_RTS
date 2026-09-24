extends Node

## 敌方（规则 AI）建筑死亡后残留的**实局**复现（2026-09-23 四轮）。
##
## 三轮的测试用"人类自己的炮塔"模拟敌方建筑，迷雾残影路径已证实修好
## （残影生成 → 死亡即清，0 残留）。用户仍报"敌方死亡的建筑还在"，说明要么
## 还有别的残留机制，要么真实对局里这条路径根本没走到。本测试不再模拟：
## 直接用**规则 AI 玩家真实建出来的建筑**当目标，覆盖两种时序：
##   A. 玩家看见 → 撤离（残影）→ 建筑被摧毁
##   B. 玩家从没看见过 → 建筑被摧毁
## 每次摧毁后全树扫描，并单独列出整个 Match 下所有"不属于任何玩家/地图"的
## 可见网格（孤儿节点），以及 UnitVisibilityHandler 上所有持有节点的容器。

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
	var ai_player = players.get_child(1)
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
	_check(human_cc != null, "人类应有指挥中心")
	_check(human_worker != null, "人类应有工人")
	if human_cc == null or human_worker == null:
		_finish()
		return
	var cc_pos: Vector3 = human_cc.global_position

	# 等规则 AI 自己再建一座建筑（真实"敌方电脑"资产）。超时则人工给 AI 放一座。
	var ai_extra: Node3D = null
	var wait_deadline := Time.get_ticks_msec() + 120000
	while Time.get_ticks_msec() < wait_deadline:
		await get_tree().physics_frame
		var structures := _structures_of(ai_player)
		if structures.size() >= 2:
			# 取一座不是开局指挥中心的
			for s in structures:
				if str((s as Node3D).get("unit_type_id")) != "command_center":
					ai_extra = s
					break
			if ai_extra == null:
				ai_extra = structures[structures.size() - 1]
			break
	if ai_extra == null:
		print("[INFO] 规则 AI 120s 内没有自建建筑，改为人工放置")
		ai_extra = await _place_for_player(runtime, ai_player, cost, a_match)
	_check(ai_extra != null and is_instance_valid(ai_extra), "应有一座敌方建筑作为目标")
	if ai_extra == null:
		_finish()
		return
	var target_pos: Vector3 = (ai_extra as Node3D).global_position
	print("[INFO] 敌方目标建筑 type=", (ai_extra as Node3D).get("unit_type_id"),
		" pos=", target_pos, " 距人类基地=", target_pos.distance_to(cc_pos))

	# 基线：玩家从未靠近 → 建筑不可见、无残影
	for _frame in range(VISIBILITY_SETTLE_FRAMES):
		await get_tree().physics_frame
	var unseen_meshes := _meshes_near(a_match, target_pos, 5.0)
	print("[INFO] 玩家未看见时该位置网格数 = ", unseen_meshes.size())
	_check(not (ai_extra as Node3D).visible, "玩家未看见时敌方建筑应不可见")
	_check(not _has_ghost(unseen_meshes), "玩家未看见时不应有残影")

	# ---- 时序 B：从没看见过就被摧毁（副官远程拆家）----
	var victim_b: Node3D = null
	for s in _structures_of(ai_player):
		if is_instance_valid(s) and (s as Node3D).global_position.distance_to(target_pos) < 1.0:
			victim_b = s
			break
	# 另找一座做 B，避免和 A 抢同一座
	var ai_structures := _structures_of(ai_player)
	var victim_a: Node3D = null
	for s in ai_structures:
		if is_instance_valid(s) and s != ai_extra:
			victim_a = s
			break
	_check(victim_a != null, "应有第二座敌方建筑用于时序 A")
	if victim_a == null:
		_finish()
		return
	var pos_a: Vector3 = (victim_a as Node3D).global_position
	var pos_b: Vector3 = target_pos
	print("[INFO] 时序 A 目标 pos=", pos_a, " 时序 B 目标 pos=", pos_b)

	# ---- 时序 A：看见 → 撤离（残影）→ 摧毁 ----
	human_worker.global_position = pos_a + Vector3(6, 0, 0)
	for _frame in range(VISIBILITY_SETTLE_FRAMES):
		await get_tree().physics_frame
	_check((victim_a as Node3D).visible, "工人前出后时序 A 目标应可见")
	human_worker.global_position = cc_pos + Vector3(6, 0, 0)
	for _frame in range(VISIBILITY_SETTLE_FRAMES):
		await get_tree().physics_frame
	var ghost_a := _meshes_near(a_match, pos_a, 5.0)
	print("[INFO] 时序 A 脱视野后网格数 = ", ghost_a.size())
	_check(_has_ghost(ghost_a), "时序 A 脱视野后应生成残影")
	(victim_a as Node3D).hp = 0
	for _frame in range(VISIBILITY_SETTLE_FRAMES):
		await get_tree().physics_frame
	_check(not is_instance_valid(victim_a), "时序 A 建筑应被销毁")
	var after_a := _meshes_near(a_match, pos_a, 5.0)
	print("[INFO] 时序 A 死亡后网格数 = ", after_a.size())
	for m in after_a:
		print("[INFO]   A-after: ", m)
	_check(after_a.is_empty(),
		"时序 A：建筑死亡后 5m 内不应有任何可见网格（含残影）；实际 %d 个" % after_a.size())

	# ---- 时序 B：从未看见就被摧毁 ----
	(victim_b as Node3D).hp = 0
	for _frame in range(VISIBILITY_SETTLE_FRAMES):
		await get_tree().physics_frame
	var after_b := _meshes_near(a_match, pos_b, 5.0)
	print("[INFO] 时序 B 死亡后网格数 = ", after_b.size())
	for m in after_b:
		print("[INFO]   B-after: ", m)
	_check(after_b.is_empty(),
		"时序 B：建筑死亡后 5m 内不应有任何可见网格；实际 %d 个" % after_b.size())

	# ---- 全局：整个 Match 下的迷雾残影与孤儿网格 ----
	var handler: Node = a_match.find_child("UnitVisibilityHandler", true, false)
	var mapping_size := 0
	var orphan_dummies := 0
	if handler != null:
		var mapping: Variant = handler.get("_structure_to_dummy_mapping")
		if mapping is Dictionary:
			var dict: Dictionary = mapping
			for key in dict:
				if is_instance_valid(dict[key]):
					mapping_size += 1
		for prop in handler.get_property_list():
			var pname := str(prop.get("name", ""))
			if pname.begins_with("_orphan") or pname.ends_with("_dummies"):
				var value = handler.get(pname)
				if value is Array:
					orphan_dummies += (value as Array).size()
	print("[INFO] UnitVisibilityHandler 残影映射=", mapping_size, " 孤儿残影数组=", orphan_dummies)
	_check(mapping_size == 0, "死亡后残影映射应为空（实际 %d）" % mapping_size)
	_check(orphan_dummies == 0, "不应再有任何孤儿残影数组（实际 %d）" % orphan_dummies)

	var ghosts := _all_ghosts(a_match)
	print("[INFO] 全 Match 残影网格数 = ", ghosts.size())
	for g in ghosts:
		print("[INFO]   ghost-left: ", g)
	_check(ghosts.is_empty(), "整个 Match 不应再有任何迷雾残影（实际 %d 个）" % ghosts.size())

	var orphans := _orphan_meshes(a_match)
	print("[INFO] 全 Match 孤儿可见网格数 = ", orphans.size())
	for o in orphans:
		print("[INFO]   orphan: ", o)
	_check(orphans.is_empty(), "整个 Match 不应有任何孤儿可见网格（实际 %d 个）" % orphans.size())

	_finish()


func _structures_of(player: Node) -> Array:
	var out: Array = []
	for child in player.get_children():
		if child is Node3D and child.is_in_group("units") and child.has_method("is_under_construction"):
			out.append(child)
	return out


## 给指定玩家放一座炮塔：先把它的一个单位传到目标点附近满足可见性，放完再送回。
func _place_for_player(runtime: Node, player: Node, cost, a_match: Node) -> Node3D:
	var anchor: Node3D = null
	for child in player.get_children():
		if child is Node3D and child.is_in_group("units"):
			anchor = child
			break
	if anchor == null:
		return null
	var anchor_pos: Vector3 = anchor.global_position
	var spot := Vector3.ZERO
	var found := false
	for radius in [8.0, 10.0, 12.0, 14.0, 16.0]:
		for sector in range(16):
			var angle := TAU * float(sector) / 16.0
			var candidate := Vector3(
				anchor_pos.x + cos(angle) * radius, anchor_pos.y, anchor_pos.z + sin(angle) * radius
			)
			anchor.global_position = candidate + Vector3(5, 0, 0)
			var probe: Dictionary = runtime.Evaluate(
				player, TurretScene, Transform3D(Basis.IDENTITY, candidate), cost
			)
			if bool(probe.get("accepted", false)):
				spot = candidate
				found = true
				break
		if found:
			break
	if not found:
		anchor.global_position = anchor_pos
		return null
	anchor.global_position = spot + Vector3(5, 0, 0)
	var placed: Dictionary = runtime.Place(player, TurretScene,
		Transform3D(Basis.IDENTITY, spot), cost)
	anchor.global_position = anchor_pos
	var structure = placed.get("structure")
	return structure as Node3D


func _has_ghost(meshes: Array) -> bool:
	for m in meshes:
		if str(m).find("UnitVisibilityHandler") >= 0:
			return true
	return false


## 整个 Match 下所有挂在 UnitVisibilityHandler 上的可见网格（迷雾残影）。
func _all_ghosts(a_match: Node) -> Array:
	var out: Array = []
	var stack: Array[Node] = [a_match]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		for child in node.get_children():
			stack.append(child)
		if node is GeometryInstance3D and (node as GeometryInstance3D).visible:
			var path := str(node.get_path())
			if path.find("UnitVisibilityHandler") >= 0:
				out.append("%s (path=%s)" % [node.name, path])
	return out


## 整个 Match 下既不在 Players 也不在 Map 的可见网格（任何来路的孤儿）。
func _orphan_meshes(a_match: Node) -> Array:
	var out: Array = []
	var stack: Array[Node] = [a_match]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		for child in node.get_children():
			stack.append(child)
		if node is GeometryInstance3D and (node as GeometryInstance3D).visible:
			var path := str(node.get_path())
			if path.find("/Players/") >= 0 or path.find("/Map") >= 0:
				continue
			out.append("%s (path=%s)" % [node.name, path])
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
		print("Live enemy building death: 0 failure(s)")
		get_tree().quit(0)
	else:
		print("Live enemy building death: %d failure(s)" % _failures)
		get_tree().quit(1)
