extends Node

## 对地炮塔瞄准冒烟测试：炮管必须对准敌人才开火（2026-09-06 战斗手感）。
## 敌坦克放在炮塔 +X 方向（初始炮管朝 +Z，需要转向 ~90°）；
## 断言：炮塔限速转向后开火（敌方掉血），且开火后炮管 +Z 指向敌人（误差 ≤ 15°）。

const MatchScene = preload("res://tests/manual/TestOneUnit.tscn")
const TurretScene = preload("res://source/match/units/AntiGroundTurret.tscn")
const TankScene = preload("res://source/match/units/Tank.tscn")
const Player = preload("res://source/match/players/Player.gd")

const AIM_ASSERT_THRESHOLD_DEG := 15.0
const FIRE_TIMEOUT_SECONDS := 15.0

var _failures := 0


func _ready():
	var match_instance = MatchScene.instantiate()
	add_child(match_instance)
	await get_tree().process_frame
	await get_tree().create_timer(0.5).timeout

	var human = match_instance.get_node("Players/Human")
	var turret = TurretScene.instantiate()
	turret.name = "AimingTurret"
	MatchSignals.setup_and_spawn_unit.emit(
		turret, Transform3D(Basis.IDENTITY, Vector3.ZERO), human, false
	)

	var enemy_player = Player.new()
	enemy_player.name = "AimingEnemy"
	enemy_player.color = Color.RED
	enemy_player.add_to_group("players")
	match_instance.get_node("Players").add_child(enemy_player)
	var enemy = TankScene.instantiate()
	enemy.name = "AimingTarget"
	enemy.position = Vector3(5, 0, 0)  # +X 方向：炮管需从 +Z 转向 +X
	enemy.add_to_group("units")
	enemy.add_to_group("revealed_units")
	enemy.hp = 200
	enemy_player.add_child(enemy)
	var hp_before: float = enemy.hp
	await get_tree().physics_frame

	var gateway = human.get_node("UnitCommandGateway")
	gateway.SetFirePolicy([enemy], "HoldFire", enemy_player)

	# 轮询等待炮塔开火（敌方掉血 = 瞄准门槛通过并发射）
	var elapsed := 0.0
	while enemy.hp >= hp_before and elapsed < FIRE_TIMEOUT_SECONDS:
		await get_tree().create_timer(0.2).timeout
		elapsed += 0.2
	_check(
		enemy.hp < hp_before,
		"炮塔应在 %.0fs 内对准并击中敌人（hp %s → %s）" % [FIRE_TIMEOUT_SECONDS, hp_before, enemy.hp]
	)

	# 开火后炮管（+Z 约定）应指向敌人方向
	var barrel_yaw := _barrel_yaw_degrees(turret)
	var to_enemy_yaw := atan2(5.0, 0.0)  # 目标方向 +X 的炮管 +Z yaw
	var error := absf(angle_difference(deg_to_rad(barrel_yaw), to_enemy_yaw))
	_check(
		rad_to_deg(error) <= AIM_ASSERT_THRESHOLD_DEG,
		"开火后炮管应指向敌人：炮管 yaw=%.1f° 目标 yaw=%.1f° 误差=%.1f°" % [
			barrel_yaw, rad_to_deg(to_enemy_yaw), rad_to_deg(error)
		]
	)

	print("Turret aiming smoke test completed: %d failure(s)" % _failures)
	match_instance.queue_free()
	await get_tree().process_frame
	SmokeTestExit.request(get_tree(), 0 if _failures == 0 else 1)


## 炮塔炮管节点（+Z 为炮管朝向）的全局 yaw。
func _barrel_yaw_degrees(turret) -> float:
	var mesh = turret.get_node("DetachTransform/Geometry/SM_Veh_Turret_Large_01")
	return rad_to_deg(atan2(mesh.global_transform.basis.z.x, mesh.global_transform.basis.z.z))


func _check(condition: bool, message: String):
	if condition:
		return
	_failures += 1
	print("FAIL: %s" % message)
	push_error("Turret aiming assertion failed: %s" % message)
