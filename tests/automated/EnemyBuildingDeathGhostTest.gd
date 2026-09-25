extends Node

## 敌方建筑"死亡后还在"的精确复现（2026-09-23 三轮）。
##
## 用户两轮报告"敌方死亡的建筑还在"。前两轮的测试都没真正走到那条路径：
## - StructureGhostCleanupTest 只查了映射表，没查渲染出的网格；
## - PostDestructionScanTest 放的是**人类自己的**炮塔，且它一直被人类基地
##   reveal 着（日志实证"建筑可见性（离开后）= true"），迷雾残影从未生成，
##   测试空跑通过。
##
## 迷雾残影（dummy）只在"曾经看见 → 脱视野"时生成。用户看到的正是副官部队
## 打掉远处敌方建筑后，原地留着一个一模一样的建筑。本测试严格复现该时序：
##   工人前出 → 在远离基地处放建筑（合法且当时可见）→ 摘掉 revealed_units
##   （变成"敌方建筑"）→ 工人撤回基地 → 残影生成（断言）→ 建筑死亡
##   → 全树扫描该位置必须零可见网格。

const MatchSettings = preload("res://source/data-model/MatchSettings.gd")
const TurretScene = preload("res://source/match/units/AntiGroundTurret.tscn")

## 建筑离开所有己方 revealer 视野后，等迷雾刷新（0.2s  cadence）需要的帧数。
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
	_check(human_cc != null, "人类应有指挥中心")
	_check(human_worker != null, "人类应有工人")
	if human_cc == null or human_worker == null:
		_finish()
		return

	var cc_pos: Vector3 = human_cc.global_position
	var cc_sight: float = float(human_cc.get("sight_range"))
	print("[INFO] 人类基地 sight=", cc_sight)

	# 落点要满足：离基地 > cc_sight（工人撤回后没有任何己方 revealer 照到它），
	# 同时工人前出后又能照到（放置合法性要求 FullyVisible）。
	var spot := Vector3.ZERO
	var found := false
	for distance in [cc_sight + 30.0, cc_sight + 45.0, cc_sight + 60.0]:
		for sector in range(16):
			var angle := TAU * float(sector) / 16.0
			var candidate := Vector3(
				cc_pos.x + cos(angle) * distance, cc_pos.y, cc_pos.z + sin(angle) * distance
			)
			# 工人前出去照这个点
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
	print("[INFO] 目标建筑 pos=", spot, " 距基地=", spot.distance_to(cc_pos))

	var placed: Dictionary = runtime.Place(human_player, TurretScene,
		Transform3D(Basis.IDENTITY, spot), cost)
	var turret = placed.get("structure")
	_check(turret != null and is_instance_valid(turret), "放置炮塔应成功")
	if turret == null:
		_finish()
		return
	var death_pos: Vector3 = (turret as Node3D).global_position

	# 变成"敌方建筑"：移出 revealed_units，迷雾系统即按敌方资产对待它
	if (turret as Node).is_in_group("revealed_units"):
		(turret as Node).remove_from_group("revealed_units")

	# 基线：工人就在旁边 → 建筑可见、无残影
	for _frame in range(VISIBILITY_SETTLE_FRAMES):
		await get_tree().physics_frame
	var baseline := _meshes_near(a_match, death_pos, 4.0)
	print("[INFO] 工人前出时该位置网格数 = ", baseline.size())
	_check((turret as Node3D).visible, "工人前出时建筑应可见")
	_check(baseline.size() > 0, "可见时该位置应有建筑网格")
	_check(not _has_ghost(baseline), "可见时不应有残影")

	# 工人撤回基地 → 建筑脱视野 → 迷雾残影生成（用户看到的"那个建筑"）
	human_worker.global_position = cc_pos + Vector3(6, 0, 0)
	for _frame in range(VISIBILITY_SETTLE_FRAMES):
		await get_tree().physics_frame
	print("[INFO] 工人撤回后建筑可见性 = ", (turret as Node3D).visible)
	_check(not (turret as Node3D).visible, "工人撤回后建筑应不可见")

	var ghost_meshes := _meshes_near(a_match, death_pos, 4.0)
	print("[INFO] 脱视野后该位置网格数 = ", ghost_meshes.size())
	for m in ghost_meshes:
		print("[INFO]   ghost: ", m)
	_check(ghost_meshes.size() > 0,
		"脱视野后应生成迷雾残影（复现用户看到'建筑还在'的载体）")
	_check(_has_ghost(ghost_meshes), "残影应挂在 UnitVisibilityHandler 下")

	# 建筑死亡（残影存在的情况下）——用户报的就是这一刻之后残影没被清掉
	(turret as Node3D).hp = 0
	for _frame in range(VISIBILITY_SETTLE_FRAMES):
		await get_tree().physics_frame
	_check(not is_instance_valid(turret), "摧毁后建筑节点应释放")

	var after_meshes := _meshes_near(a_match, death_pos, 4.0)
	print("[INFO] 死亡后该位置网格数 = ", after_meshes.size())
	for m in after_meshes:
		print("[INFO]   after: ", m)
	_check(after_meshes.is_empty(),
		"建筑死亡后该位置 4m 内不应有任何可见网格（含迷雾残影）；实际 %d 个：%s" % [
			after_meshes.size(), "; ".join(after_meshes)])

	# 反向路径也要守住：残影存在时玩家重新照到该位置 → 残影消失、建筑现身。
	var placed2: Dictionary = runtime.Place(human_player, TurretScene,
		Transform3D(Basis.IDENTITY, spot), cost)
	var turret2 = placed2.get("structure")
	if turret2 != null and is_instance_valid(turret2):
		if (turret2 as Node).is_in_group("revealed_units"):
			(turret2 as Node).remove_from_group("revealed_units")
		human_worker.global_position = spot + Vector3(6, 0, 0)
		for _frame in range(VISIBILITY_SETTLE_FRAMES):
			await get_tree().physics_frame
		_check((turret2 as Node3D).visible, "工人回到附近后第二座建筑应可见")
		var visible_meshes := _meshes_near(a_match, death_pos, 4.0)
		_check(not _has_ghost(visible_meshes), "建筑可见时不应残留残影")
	else:
		_check(false, "第二座炮塔应放置成功（反向路径复测需要）")

	_finish()


func _has_ghost(meshes: Array) -> bool:
	for m in meshes:
		if str(m).find("UnitVisibilityHandler") >= 0:
			return true
	return false


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
		print("Enemy building death ghost: 0 failure(s)")
		get_tree().quit(0)
	else:
		print("Enemy building death ghost: %d failure(s)" % _failures)
		get_tree().quit(1)
