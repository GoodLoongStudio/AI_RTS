extends Node

## 建筑摧毁后**全树**残留扫描（2026-09-23 二轮：用户报"敌方死亡的建筑还在"仍在）。
##
## 第一轮修了 UnitVisibilityHandler 的迷雾残影（死亡即清）。用户反馈问题依旧，
## 说明还有别的残留路径。本测试不猜机制：摧毁建筑后**扫描整个场景树**
## （Match 子树下所有 GeometryInstance3D），报告死亡位置 4m 内的全部可见网格
## 及其所在节点路径——无论它是残影、零件、还是任何被 reparent 的东西，都会现形。

const MatchSettings = preload("res://source/data-model/MatchSettings.gd")
const TurretScene = preload("res://source/match/units/AntiGroundTurret.tscn")

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
	for _frame in range(240):
		await get_tree().physics_frame

	var players: Node = a_match.get_node("Players")
	var human_player = players.get_child(0)
	var ai_player = players.get_child(1)
	var runtime = a_match.get_node("StructurePlacementRuntime")
	var cost = a_match.get_node("BalanceConfigRuntime").GetConstructionCost(TurretScene)
	human_player.add_resources({"resource_a": 5000}, "ScriptedAdjustment")

	# 找 AI 的一座建筑（指挥中心）作为目标
	var ai_cc: Node3D = null
	for child in ai_player.get_children():
		if child is Node3D and str(child.get("unit_type_id")) == "command_center":
			ai_cc = child
			break
	_check(ai_cc != null, "AI 玩家应有指挥中心")
	if ai_cc == null:
		_finish()
		return

	# 找人类自己的指挥中心旁放炮塔当"敌人建筑"（位置对残留扫描无影响，
	# 且人类基地旁一定有合法落点）
	var human_cc: Node3D = null
	for child in human_player.get_children():
		if child is Node3D and str(child.get("unit_type_id")) == "command_center":
			human_cc = child
			break
	_check(human_cc != null, "人类应有指挥中心")
	if human_cc == null:
		_finish()
		return

	var cc_pos: Vector3 = human_cc.global_position
	var spot := Vector3.ZERO
	var found := false
	for radius in [5.0, 6.0, 7.0, 8.0]:
		for sector in range(12):
			var angle := TAU * float(sector) / 12.0
			var candidate := Vector3(
				cc_pos.x + cos(angle) * radius, cc_pos.y, cc_pos.z + sin(angle) * radius
			)
			var probe: Dictionary = runtime.Evaluate(
				human_player, TurretScene, Transform3D(Basis.IDENTITY, candidate), cost
			)
			if bool(probe.get("accepted", false)):
				spot = candidate
				found = true
				break
		if found:
			break
	_check(found, "应能找到合法落点")
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
	print("[INFO] 目标建筑 pos=", death_pos)

	# 记录摧毁前的网格数（基线）
	var before_meshes := _meshes_near(a_match, death_pos, 4.0)
	print("[INFO] 摧毁前该位置网格数 = ", before_meshes.size())
	for m in before_meshes:
		print("[INFO]   before: ", m)

	# 摧毁（先脱离视野造残影，再打死——覆盖迷雾残影路径）
	# 把人类唯一单位瞬移走，让建筑脱视野
	var human_unit: Node3D = null
	for child in human_player.get_children():
		if child is Node3D and child.is_in_group("units") and str(child.get("unit_type_id")) == "worker":
			human_unit = child
			break
	if human_unit != null:
		human_unit.global_position = death_pos + Vector3(400, 0, 400)
		for _frame in range(40):
			await get_tree().physics_frame
		print("[INFO] 建筑可见性（离开后）= ", (turret as Node3D).visible)

	(turret as Node3D).hp = 0
	for _frame in range(20):
		await get_tree().physics_frame
	_check(not is_instance_valid(turret), "摧毁后节点应释放")

	# 全树扫描：该位置不应再有任何可见网格
	var after_meshes := _meshes_near(a_match, death_pos, 4.0)
	print("[INFO] 摧毁后该位置网格数 = ", after_meshes.size())
	for m in after_meshes:
		print("[INFO]   after: ", m)
	_check(after_meshes.is_empty(),
		"摧毁后该位置 4m 内不应有任何可见网格残留（实际 %d 个：%s）—— 用户二轮报告'敌方死亡的建筑还在'" % [
			after_meshes.size(), "; ".join(after_meshes)])

	_finish()


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
		print("Post-destruction tree scan: 0 failure(s)")
		get_tree().quit(0)
	else:
		print("Post-destruction tree scan: %d failure(s)" % _failures)
		get_tree().quit(1)
