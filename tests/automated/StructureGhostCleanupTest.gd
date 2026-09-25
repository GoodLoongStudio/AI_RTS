extends Node

## 敌人建筑被摧毁后残影残留复现/守门测试（2026-09-23 用户报"敌人建筑被打掉了怎么还在"）。
##
## 背景（`UnitVisibilityHandler` 的迷雾残影机制）：建筑脱离玩家视野时，系统会
## `duplicate()` 一份 Geometry 作为"最后已知位置"残影挂在 handler 下；建筑死亡时
## 残影变成 orphaned dummy，**只有该位置重新进入玩家视野才被清除**。若清除逻辑
## 有漏（例如遍历中 erase 跳元素），玩家就会看到"已经被打掉的建筑还在"。
##
## 本测试走完整生命周期：
## ① 敌方建筑在视野内 → 可见；
## ② 玩家单位离开 → 建筑不可见 → 残影创建；
## ③ 摧毁该建筑（此时不可见）；
## ④ 玩家单位回去重新看到该位置 → 残影**必须**被清除（用户报的 bug 即这一步失效）。

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

	# 等对局就绪
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

	# 找AI玩家的一座建筑（指挥中心）
	var ai_cc: Node3D = null
	for child in ai_player.get_children():
		if child is Node3D and str(child.get("unit_type_id")) == "command_center":
			ai_cc = child
			break
	_check(ai_cc != null, "AI 玩家应有指挥中心")
	if ai_cc == null:
		_finish()
		return

	# ① 把人类的一个单位（工人）瞬移到 AI 基地旁，让建筑进入视野
	var human_unit: Node3D = null
	for child in human_player.get_children():
		if child is Node3D and child.is_in_group("units") and str(child.get("unit_type_id")) == "worker":
			human_unit = child
			break
	_check(human_unit != null, "人类应有工人")
	if human_unit == null:
		_finish()
		return
	human_unit.global_position = ai_cc.global_position + Vector3(4, 0, 0)
	for _frame in range(40):
		await get_tree().physics_frame
	_check(ai_cc.visible, "有己方单位在旁时敌方建筑应可见")

	# ② 把人类单位瞬移到地图另一端 → 建筑脱离视野 → 残影创建
	human_unit.global_position = ai_cc.global_position + Vector3(400, 0, 400)
	for _frame in range(40):
		await get_tree().physics_frame
	_check(not ai_cc.visible, "己方单位离开后敌方建筑应不可见")
	var ghost_before := _ghost_near(a_match, ai_cc.global_position, 3.0)
	print("[INFO] 该建筑残影数（离开视野后） = ", ghost_before)
	_check(ghost_before >= 1, "建筑脱离视野后应创建残影")

	# ③ 摧毁该建筑（此刻不可见，残影存在）
	_last_pos = ai_cc.global_position
	ai_cc.hp = 0
	for _frame in range(10):
		await get_tree().physics_frame
	_check(not is_instance_valid(ai_cc), "摧毁后真实建筑节点应释放")

	# ④ 残影必须**立即**被清除（2026-09-23 修"敌人建筑被打掉了怎么还在"）：
	# 旧实现等"重新照到位置"才删，玩家刚打掉的建筑在屏幕上留着一模一样的残影。
	# 只数**这座建筑位置附近**的残影——其他活建筑的迷雾残影是正常机制，必须保留。
	var dummy_after_death := _ghost_near(a_match, _last_pos, 3.0)
	print("[INFO] 被毁建筑位置的残影数 = ", dummy_after_death)
	_check(dummy_after_death == 0,
		"建筑被摧毁后其残影必须立即清除，不等重新照到（实际剩 %d 个）—— 用户报'建筑被打掉了还在'即此" % dummy_after_death)

	# ⑤ 再让人类单元回到该位置（确保没有"复活"的残影、也不崩）
	human_unit.global_position = _last_pos + Vector3(4, 0, 0)
	for _frame in range(60):
		await get_tree().physics_frame
	var dummy_final := _ghost_near(a_match, _last_pos, 3.0)
	_check(dummy_final == 0, "重新照到位置后也不应有该建筑残影（实际 %d）" % dummy_final)

	_finish()


var _last_pos: Vector3 = Vector3.ZERO


func _dummy_count(_a_match: Node) -> int:
	return 0


## 距指定位置多远处的残影数量（只数"这一个建筑"的残影，不数其他活建筑的）。
## 同时查 mapping（活建筑残影）与 _orphaned_dummies（已毁建筑的残留残影，
## 2026-09-23 修复前它就在这里常驻）——两个容器都查才能抓住"打掉了还在"。
func _ghost_near(a_match: Node, pos: Vector3, within: float) -> int:
	var handler = a_match.find_child("UnitVisibilityHandler", true, false)
	if handler == null:
		return -1
	var count := 0
	var mapping: Dictionary = handler.get("_structure_to_dummy_mapping")
	for key in mapping.keys():
		var dummy = mapping[key]
		if is_instance_valid(dummy) and dummy is Node3D:
			if (dummy as Node3D).global_position.distance_to(pos) <= within:
				count += 1
	var orphans: Variant = handler.get("_orphaned_dummies")
	if orphans is Array:
		for dummy in (orphans as Array):
			if is_instance_valid(dummy) and dummy is Node3D:
				if (dummy as Node3D).global_position.distance_to(pos) <= within:
					count += 1
	return count


func _finish() -> void:
	if _failures == 0:
		print("Structure ghost cleanup: 0 failure(s)")
		get_tree().quit(0)
	else:
		print("Structure ghost cleanup: %d failure(s)" % _failures)
		get_tree().quit(1)
