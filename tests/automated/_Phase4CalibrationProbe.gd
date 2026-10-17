extends Node

## 阶段4 玩法数值标定探针（2026-10-01 世界尺度审计）。
## ① 20m/40m 直线移动计时 → 实际 m/s（对照 Movement.speed 运行时值）；
## ② "刚好开火"中心距：强制攻击从远处开火，记录第一发命中的双方中心距，
##    对照权威口径 reach_range_against = attack_range + 双方半径；
## ③ "刚好可见"中心距：观察者 sight vs 敌单位，对照 sight_range_against + FoW 边缘补偿 2.0m。
## 注意：本机成长存档有 combat_mobility×2（速度 ×1.06），运行时速度含此加成——
## 标定对照的是 Movement.speed 属性（= 平衡值 × 成长），不是平衡 JSON 原值。

const MAP_SCENE := "res://source/match/maps/PlainAndSimple.tscn"

var _match: Node
var _human: Node


func _ready():
	var settings = load("res://source/data-model/MatchSettings.gd").new()
	var hs = load("res://source/data-model/PlayerSettings.gd").new()
	hs.controller = Constants.PlayerType.HUMAN
	hs.color = Constants.Player.COLORS[0]
	settings.players.append(hs)
	settings.visible_player = 0
	var enemy_settings = load("res://source/data-model/MatchSettings.gd").new()
	_match = load("res://source/match/Match.tscn").instantiate()
	_match.settings = settings
	_match.map = load(MAP_SCENE).instantiate()
	add_child(_match)
	get_tree().current_scene = _match
	for _f in range(200):
		await get_tree().physics_frame
	_human = _match.get_node("Players").get_children()[0]

	await _movement_timing()
	await _just_fire_distance()
	await _just_visible_distance()
	get_tree().quit(0)


func _spawn(scene_name: String, pos: Vector3, player: Node) -> Node3D:
	var inst = load("res://source/match/units/%s.tscn" % scene_name).instantiate()
	MatchSignals.setup_and_spawn_unit.emit(inst, Transform3D(Basis.IDENTITY, pos), player)
	for _f in range(3):
		await get_tree().physics_frame
	return inst


## ① 20m/40m 直线移动计时
func _movement_timing() -> void:
	print("[MOVE] 单位|Mv.speed属性|20m耗时|20m实际m/s|40m耗时|40m实际m/s")
	for case in [["Tank", Vector3(20, 0, 20)], ["Infantry", Vector3(30, 0, 20)], ["Drone", Vector3(40, 0, 20)]]:
		var unit: Node3D = await _spawn(case[0], case[1], _human)
		var movement: Node = unit.find_child("Movement")
		var stated: float = float(movement.get("speed"))
		var row := [case[0], "%.2f" % stated]
		for leg in [20.0, 40.0]:
			var start: Vector3 = unit.global_position
			var target := start + Vector3(leg, 0, 0)
			var elapsed := 0.0
			var finished_flag := [false]  # lambda 按引用捕获数组，按值捕获标量写不进外层
			var on_finished := func(): finished_flag[0] = true
			movement.movement_finished.connect(on_finished)
			movement.move(target)
			while elapsed < 45.0 and not finished_flag[0]:
				await get_tree().physics_frame
				elapsed += get_physics_process_delta_time()
			if movement.movement_finished.is_connected(on_finished):
				movement.movement_finished.disconnect(on_finished)
			var remain: float = Vector2(
				target.x - unit.global_position.x,
				target.z - unit.global_position.z).length()
			row.append("%.2fs%s" % [elapsed, "" if finished_flag[0] else "(超时)"])
			row.append("%.2f(残差%.2f)" % [(leg / elapsed if elapsed > 0.01 else -1.0), remain])
		print("[MOVE] " + "|".join(row))
		unit.queue_free()


## ② 刚好开火：坦克（r 2.0，atk 7.5）强制攻击敌坦克（r 2.0）。
## 期望第一发命中中心距 ≤ 7.5+2+2 = 11.5m（多弹道飞行期间目标不动）。
func _just_fire_distance() -> void:
	var attacker: Node3D = await _spawn("Tank", Vector3(20, 0, 60), _human)
	var gateway = _human.get_node("UnitCommandGateway")
	var distances := [14.0, 12.5, 11.5, 10.5]
	print("[FIRE] 起始中心距|第一发命中时中心距|期望上限11.50|命中耗时")
	for d0 in distances:
		var target: Node3D = await _spawn("Tank", attacker.global_position + Vector3(d0, 0, 0), _human)
		if target == null or not is_instance_valid(target):
			continue
		target.add_to_group("adversary_units")
		gateway.SetFirePolicy([target], "HoldFire", target.get_parent())
		var hp0: float = float(target.get("hp"))
		var result: Dictionary = gateway.ForceAttackUnits([attacker], target, _human)
		var accepted: bool = str(result.get("status", "")) == "Accepted"
		var elapsed := 0.0
		var hit_distance := -1.0
		while elapsed < 12.0:
			await get_tree().physics_frame
			elapsed += get_physics_process_delta_time()
			if not is_instance_valid(target):
				break
			if float(target.get("hp")) < hp0 - 0.01:
				hit_distance = Vector2(
					attacker.global_position.x - target.global_position.x,
					attacker.global_position.z - target.global_position.z).length()
				break
		print("[FIRE] %.1f|%s|%s|%.2fs" % [
			d0, ("%.2f" % hit_distance) if hit_distance > 0 else "未命中",
			"OK" if accepted else "拒绝", elapsed])
		if is_instance_valid(target):
			target.queue_free()
		await get_tree().create_timer(0.3).timeout


## ③ 刚好可见：观察者坦克（sight 13）看敌坦克。
## 期望可见边界中心距 = 13 + 2 + 2（表面到表面）+ 2.0（FoW 模糊边缘补偿）= 19.0m。
func _just_visible_distance() -> void:
	var observer: Node3D = await _spawn("Tank", Vector3(20, 0, 30), _human)
	observer.add_to_group("revealed_units")
	await get_tree().physics_frame
	print("[SEE] 中心距|可见?(1/0)|期望边界≈19.0m")
	for d in [16.0, 18.0, 19.0, 20.0, 21.0]:
		var enemy: Node3D = await _spawn("Tank", observer.global_position + Vector3(d, 0, 0), _human)
		enemy.add_to_group("adversary_units")
		# headless dummy 渲染器不出迷雾纹理 ⇒ 直接调用权威判定函数隔离测量。
		var handler: Node = _match.get_node_or_null("UnitVisibilityHandler")
		if handler != null:
			handler._recalculate_unit_visibility(enemy)
		var visible: bool = enemy.visible
		if d == 20.0:
			print("[SEE-DBG] handler.visible=%s disabled=%s observer.sight=%s observer在revealed组=%s cached含观察者=%s sight_against=%.2f" % [
				str(handler.visible), str(handler._is_disabled()),
				str(observer.get("sight_range")),
				str(observer.is_in_group("revealed_units")),
				str(observer in handler._cached_units),
				observer.sight_range_against(enemy) if observer.has_method("sight_range_against") else -1.0])
		print("[SEE] %.1f|%d|%s" % [d, 1 if visible else 0,
			"OK" if (visible if d <= 19.0 else not visible) else "越界"])
		enemy.queue_free()
		await get_tree().physics_frame
	observer.queue_free()
