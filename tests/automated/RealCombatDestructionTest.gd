extends Node

## 实战摧毁链路复现/守门测试（2026-09-23 用户报"敌人建筑被打掉了怎么还在"）。
##
## 前面的两个测试证明了：① hp 归零的死亡路径会正确释放节点；② 迷雾残影在
## 重新看到位置后会被清除。本测试走**真实战斗链路**：玩家坦克强攻敌方指挥
## 中心，等弹丸伤害把它打到 0 hp，然后验证：
## ① 建筑节点被释放（不在 units 组、不在玩家节点下）；
## ② 没有残影/幽灵留在 UnitVisibilityHandler；
## ③ 敌方玩家名下不再有该建筑。

const MatchSettings = preload("res://source/data-model/MatchSettings.gd")
const TankScene = preload("res://source/match/units/Tank.tscn")

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

	# 找 AI 的指挥中心
	var ai_cc: Node3D = null
	for child in ai_player.get_children():
		if child is Node3D and str(child.get("unit_type_id")) == "command_center":
			ai_cc = child
			break
	_check(ai_cc != null, "AI 玩家应有指挥中心")
	if ai_cc == null:
		_finish()
		return
	var cc_pos: Vector3 = ai_cc.global_position
	var cc_hp_max: float = float(ai_cc.hp_max)
	print("[INFO] AI CC hp_max=", cc_hp_max, " pos=", cc_pos)

	# 在 AI 基地旁生成 4 辆玩家坦克（走 Match 唯一出场入口）
	var spawned: Array[Node3D] = []
	for i in range(4):
		var tank: Node3D = TankScene.instantiate()
		var offset := Vector3(10.0 + i * 2.0, 0.0, 6.0)
		a_match.call("_setup_and_spawn_unit", tank,
			Transform3D(Basis.IDENTITY, cc_pos + offset), human_player, false)
		spawned.append(tank)
	for _frame in range(60):
		await get_tree().physics_frame
	_check(spawned.size() == 4, "应生成 4 辆坦克")
	var alive_tanks := 0
	for tank in spawned:
		if is_instance_valid(tank):
			alive_tanks += 1
	_check(alive_tanks == 4, "4 辆坦克都应存活（实际 %d）" % alive_tanks)

	# 强攻指挥中心（真实战斗链路：projectile → warhead → hp setter → 死亡）
	var gateway = human_player.get_node_or_null("UnitCommandGateway")
	_check(gateway != null, "应有命令网关")
	if gateway != null:
		var result: Dictionary = gateway.ForceAttackUnits(spawned, ai_cc, human_player)
		print("[INFO] ForceAttackUnits → ", result.get("status", "?"))

	# 等它掉血（确认伤害链路通）
	var damaged := false
	var deadline2 := Time.get_ticks_msec() + 30000
	while Time.get_ticks_msec() < deadline2:
		await get_tree().physics_frame
		if not is_instance_valid(ai_cc):
			break
		if float(ai_cc.hp) < cc_hp_max:
			damaged = true
			break
	_check(damaged or not is_instance_valid(ai_cc), "敌方建筑应受到伤害")

	# 等它死亡（最多 120s；坦克 21 伤害/发 × 4 辆 vs CC 几百 HP）
	var died := false
	var deadline3 := Time.get_ticks_msec() + 120000
	while Time.get_ticks_msec() < deadline3:
		await get_tree().physics_frame
		if not is_instance_valid(ai_cc):
			died = true
			break
	_check(died, "敌方指挥中心应被摧毁")

	# 摧毁后再等几帧让 queue_free 落地
	for _frame in range(30):
		await get_tree().physics_frame

	# ① 节点释放 + 不在 units 组
	var in_group := false
	for unit in a_match.get_tree().get_nodes_in_group("units"):
		if unit == ai_cc:
			in_group = true
	_check(not in_group, "摧毁后建筑不应在 units 组")
	var under_player := false
	for child in ai_player.get_children():
		if child == ai_cc:
			under_player = true
	_check(not under_player, "摧毁后建筑不应挂在 AI 玩家节点下")

	# ② 残影检查：该位置不应留下任何残影（死亡即清，2026-09-23 修复）
	var handler = a_match.find_child("UnitVisibilityHandler", true, false)
	if handler != null:
		var mapping: Dictionary = handler.get("_structure_to_dummy_mapping")
		var ghost_near := 0
		for key in mapping.keys():
			var dummy2 = mapping[key]
			if is_instance_valid(dummy2) and dummy2 is Node3D:
				if (dummy2 as Node3D).global_position.distance_to(cc_pos) < 5.0:
					ghost_near += 1
		print("[INFO] 该位置附近的残影数 = ", ghost_near)
		_check(ghost_near == 0,
			"被摧毁建筑位置不应残留迷雾残影（实际 %d 个）—— 用户报'建筑被打掉了还在'即此" % ghost_near)
	else:
		_check(false, "应能找到 UnitVisibilityHandler")

	# ③ 被摧毁的那座 CC 不应再在 AI 名下（AI 扩张出的新 CC 是正常行为，不在此列）
	var destroyed_still_there := false
	for child in ai_player.get_children():
		if child is Node3D and child == ai_cc:
			destroyed_still_there = true
	_check(not destroyed_still_there,
		"被摧毁的指挥中心不应再在 AI 玩家名下（AI 新建造的其他基地属正常扩张）")

	_finish()


func _finish() -> void:
	if _failures == 0:
		print("Real combat destruction: 0 failure(s)")
		get_tree().quit(0)
	else:
		print("Real combat destruction: %d failure(s)" % _failures)
		get_tree().quit(1)
