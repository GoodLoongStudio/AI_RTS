extends Node

## 交战/索敌几何口径探针（2026-09-29）。
##
## 背景：2026-09-27 单位尺寸统一把碰撞半径放大 3~3.5 倍（单位 0.6~0.9 → 2.0~2.3，
## 建筑 footprint 2.0 → 6.0~9.8），而 balance 里的 `rangeMeters` / `sightRangeMeters`
## 没有跟着放大（坦克射程 7.5、视野 8.0）。本仓所有射程/视野判据原先都拿**圆心距**去比
## 这些**表面到表面**的数值 → 判据成了恒假命题：
##   · 单位中心最近只能抵达敌方建筑 `footprint + 导航 agent 半径`（主基地 9.8 米），
##     而坦克射程只有 7.5 米 → 电脑玩家与副官"攻建筑"整条永远不开火（只能打掉 2 米
##     半径的炮塔和兵）；同理"看不见"敌方大型单位/建筑 → 自主索敌空转、副官观测 enemy 恒空。
## 修复口径的唯一实现是 `Unit.center_distance_limit_for()`（判据 = 基准值 + 双方半径）。
## 本探针用**真实场景半径 + 当前 balance 数值**把"每个作战单位都能打到/看见它能抵达的
## 每种敌方建筑"固化为断言，并打印旧圆心距口径的失效面（一旦有人把判据改回圆心距，
## `_legacy_unreachable` 会重新变成大数）。

## 场景名 → balance unitTypeId（写死是为了让"场景与目录脱钩"立刻暴露成断言失败）。
const ATTACKER_TYPES := {
	"Tank": "tank", "HeavyTank": "heavy_tank", "Infantry": "soldier", "Sniper": "sniper",
	"Rocketeer": "rocketeer", "APC": "apc", "Helicopter": "helicopter",
}
const TARGET_STRUCTURE_SCENES := {
	"CommandCenter": "command_center", "Barracks": "barracks",
	"VehicleFactory": "vehicle_factory", "AircraftFactory": "aircraft_factory",
	"OreRefinery": "ore_refinery", "AntiGroundTurret": "anti_ground_turret",
	"AntiAirTurret": "anti_air_turret", "MachineGunTurret": "machine_gun_turret",
}
const TARGET_UNIT_SCENES := {"Tank": "tank", "Infantry": "soldier", "Worker": "worker"}
## 单位中心能抵达的最近位置 = 目标 footprint + 导航 agent 半径侵蚀（Match.tscn 实测 2.8）。
const NAV_AGENT_RADIUS_M := 2.8
const BALANCE_PATH := "res://config/balance/demo.balance.v1.json"

var _failures := 0
var _legacy_unreachable := 0
var _pairs_checked := 0
var _balance := {}


func _ready():
	await get_tree().process_frame
	if not _load_balance():
		print("Reach geometry probe completed: 1 failure(s)")
		SmokeTestExit.request(get_tree(), 1)
		return
	for scene_name in ATTACKER_TYPES:
		await _check_attacker(scene_name)
	print("[reach] 组合数=%d，旧圆心距口径下打不到的组合=%d（= 修复前的失效面）" % [
		_pairs_checked, _legacy_unreachable])
	print("Reach geometry probe completed: %d failure(s)" % _failures)
	SmokeTestExit.request(get_tree(), 0 if _failures == 0 else 1)


func _load_balance() -> bool:
	var file := FileAccess.open(BALANCE_PATH, FileAccess.READ)
	if file == null:
		_fail("平衡配置读不到：%s" % BALANCE_PATH)
		return false
	var parsed = JSON.parse_string(file.get_as_text())
	if not parsed is Dictionary:
		_fail("平衡配置解析失败：%s" % BALANCE_PATH)
		return false
	_balance = parsed
	return true


func _stats_for(type_id: String) -> Dictionary:
	for entry in _balance.get("unitTypes", []):
		if str(entry.get("id", "")) != type_id:
			continue
		var best_range := 0.0
		for weapon_id in entry.get("weaponIds", []):
			for weapon in _balance.get("weapons", []):
				if str(weapon.get("id", "")) == str(weapon_id):
					best_range = maxf(best_range, float(weapon.get("rangeMeters", 0.0)))
		return {
			"range": best_range,
			"sight": float(entry.get("sightRangeMeters", 0.0)),
		}
	return {}


func _footprint_for(type_id: String) -> float:
	for entry in _balance.get("constructions", []):
		if str(entry.get("unitTypeId", "")) == type_id:
			return float(entry.get("footprintRadiusMeters", 0.0))
	return -1.0


func _check_attacker(scene_name: String) -> void:
	var type_id: String = ATTACKER_TYPES[scene_name]
	var stats := _stats_for(type_id)
	if stats.is_empty():
		_fail("%s(%s) 在平衡目录里查不到" % [scene_name, type_id])
		return
	var attacker: Node3D = await _instantiate("res://source/match/units/%s.tscn" % scene_name)
	# 场景本身不写 attack_range/sight_range（对局里由 ConfigureUnit 从目录注入），
	# 探针按当前目录数值注入，保证"真实半径 × 当前射程"这一对是唯一被测口径。
	attacker.attack_range = stats["range"]
	attacker.sight_range = stats["sight"]
	if stats["range"] <= 0.0:
		print("[reach] %s 无武器，跳过" % scene_name)
		return
	for target_scene in TARGET_STRUCTURE_SCENES:
		await _check_pair(attacker, scene_name, target_scene,
			TARGET_STRUCTURE_SCENES[target_scene], true)
	for target_scene in TARGET_UNIT_SCENES:
		await _check_pair(attacker, scene_name, target_scene,
			TARGET_UNIT_SCENES[target_scene], false)


func _check_pair(attacker: Node3D, attacker_name: String, target_scene: String,
		target_type: String, is_structure: bool) -> void:
	var target: Node3D = await _instantiate("res://source/match/units/%s.tscn" % target_scene)
	var target_r: float = target.body_radius()
	if is_structure:
		var footprint := _footprint_for(target_type)
		# 建筑碰撞半径必须等于目录 footprint，否则"尺寸统一"又漏了一处。
		if footprint > 0.0 and absf(footprint - target_r) > 0.051:
			_fail("%s 场景半径 %.2f 与目录 footprint %.2f 不一致" % [
				target_scene, target_r, footprint])
	var approach: float = target_r + NAV_AGENT_RADIUS_M
	var reach: float = attacker.reach_range_against(target)
	var sight: float = attacker.sight_range_against(target)
	var legacy_ok: bool = float(attacker.attack_range) >= approach
	_legacy_unreachable += 0 if legacy_ok else 1
	_pairs_checked += 1
	print("[reach] %s(r=%.2f rng=%.2f sight=%.2f) -> %s(r=%.2f) 可达=%.2f 射程判据=%s 视野判据=%s 旧口径可打=%s" % [
		attacker_name, attacker.body_radius(), float(attacker.attack_range),
		float(attacker.sight_range), target_scene, target_r, approach,
		str(approach <= reach), str(approach <= sight), str(legacy_ok)])
	if approach > reach:
		_fail("%s 打不到 %s：可达圆心距 %.2f > 有效射程 %.2f" % [
			attacker_name, target_scene, approach, reach])
	if approach > sight:
		_fail("%s 看不见 %s：可达圆心距 %.2f > 有效视野 %.2f" % [
			attacker_name, target_scene, approach, sight])
	target.queue_free()
	await get_tree().process_frame


func _instantiate(path: String) -> Node3D:
	var node: Node3D = (load(path) as PackedScene).instantiate()
	add_child(node)
	await get_tree().process_frame
	return node


func _fail(message: String) -> void:
	_failures += 1
	push_error("Reach geometry assertion failed: %s" % message)
