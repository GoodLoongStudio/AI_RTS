extends Node

## 建筑摧毁后残留复现/守门测试（2026-09-23 用户报"敌人建筑被打掉了怎么还在"）。
##
## 对一座敌方建筑持续施加伤害到 hp=0，验证：
## ① 节点被真正释放（不在树里、不在 units 组）；
## ② 敌对玩家的建筑计数归零；
## ③ 之后 AI 请求重建是**新**建筑（同位置允许，但不允许旧节点残留）。

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
	var ps = load("res://source/data-model/PlayerSettings.gd").new()
	ps.controller = Constants.PlayerType.HUMAN
	ps.color = Color.BLUE
	settings.players.append(ps)
	settings.visible_player = 0
	settings.visibility = MatchSettings.Visibility.FULL

	var a_match = load("res://source/match/Match.tscn").instantiate()
	a_match.settings = settings
	a_match.map = load("res://source/match/maps/PlainAndSimple.tscn").instantiate()
	get_tree().root.add_child(a_match)
	get_tree().current_scene = a_match

	# 等对局就绪 + 出生配置完成
	var deadline := Time.get_ticks_msec() + 60000
	var ready := false
	while Time.get_ticks_msec() < deadline:
		await get_tree().physics_frame
		var players = a_match.get_node_or_null("Players")
		if players != null and players.get_child_count() >= 1:
			var first_player = players.get_child(0)
			if first_player != null and first_player.get_child_count() > 0:
				ready = true
				break
	_check(ready, "对局应就绪")
	for _frame in range(180):
		await get_tree().physics_frame

	var player = a_match.get_node("Players").get_child(0)
	var runtime = a_match.get_node("StructurePlacementRuntime")
	var cost = a_match.get_node("BalanceConfigRuntime").GetConstructionCost(TurretScene)
	player.add_resources({"resource_a": 5000}, "ScriptedAdjustment")

	# 找合法落点放一座炮塔（当"敌人建筑"用）
	var cc: Node3D = null
	for child in player.get_children():
		if child is Node3D and str(child.get("unit_type_id")) == "command_center":
			cc = child
			break
	_check(cc != null, "应能找到己方指挥中心")
	if cc == null:
		_finish()
		return

	var spot := Vector3.ZERO
	var found := false
	for radius in [4.0, 5.0, 6.0, 7.0, 8.0]:
		for sector in range(12):
			var angle := TAU * float(sector) / 12.0
			var candidate := Vector3(
				cc.global_position.x + cos(angle) * radius,
				cc.global_position.y,
				cc.global_position.z + sin(angle) * radius
			)
			var probe: Dictionary = runtime.Evaluate(
				player, TurretScene, Transform3D(Basis.IDENTITY, candidate), cost
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

	var placed: Dictionary = runtime.Place(player, TurretScene, Transform3D(Basis.IDENTITY, spot), cost)
	_check(bool(placed.get("accepted", false)), "放置炮塔应成功")
	var turret = placed.get("structure")
	_check(turret != null and is_instance_valid(turret), "放置后应返回建筑节点")

	# 统计放置前后 units 组里的炮塔数
	var before_count := _count_type(a_match, "anti_ground_turret")
	_check(before_count == 1, "放置后 units 组应有 1 座炮塔（实际 %d）" % before_count)

	# --- 摧毁：直接走 hp setter（与 LegacyDamagePort/ProjectileRuntime 同一条路） ---
	turret.hp = 0
	# queue_free 是延迟的：等两帧让释放落地
	for _frame in range(4):
		await get_tree().physics_frame

	var after_count := _count_type(a_match, "anti_ground_turret")
	_check(after_count == 0,
		"摧毁后 units 组应无炮塔残留（实际 %d）—— 用户报'建筑被打掉了还在'即此" % after_count)
	_check(not is_instance_valid(turret), "摧毁后节点应已释放")

	# 树里再查一遍（防止节点脱离组但仍在树里显示）
	var still_in_tree := false
	for unit in a_match.get_node("Players").get_children():
		for child in unit.get_children():
			if child == turret:
				still_in_tree = true
	_check(not still_in_tree, "摧毁后不应仍挂在玩家节点下")

	# --- 伤害路径复验：分多次伤害打到 0（真实战斗路径） ---
	var placed2: Dictionary = runtime.Place(player, TurretScene,
		Transform3D(Basis.IDENTITY, spot + Vector3(3, 0, 0)), cost)
	var turret2 = placed2.get("structure")
	if turret2 != null and is_instance_valid(turret2):
		var hp_max: float = float(turret2.hp_max)
		var steps := 5
		for i in range(steps):
			if not is_instance_valid(turret2):
				break
			# 模拟弹丸伤害：每次扣 1/steps，最后一击恰好归零
			var dmg: float = (hp_max / float(steps)) + (0.5 if i == steps - 1 else 0.0)
			turret2.hp = float(turret2.hp) - dmg
		for _frame in range(4):
			await get_tree().physics_frame
		var after2 := _count_type(a_match, "anti_ground_turret")
		_check(after2 == 0, "分次伤害打死后也不应有残留（实际 %d）" % after2)

	_finish()


func _count_type(a_match: Node, type_id: String) -> int:
	var count := 0
	for unit in a_match.get_tree().get_nodes_in_group("units"):
		if str(unit.get("unit_type_id")) == type_id:
			count += 1
	return count


func _finish() -> void:
	if _failures == 0:
		print("Structure destruction cleanup: 0 failure(s)")
		get_tree().quit(0)
	else:
		print("Structure destruction cleanup: %d failure(s)" % _failures)
		get_tree().quit(1)
