class_name ProjectileVisuals
extends RefCounted

## 联机客户端的**弹道表现回放**（2026-09-11）。
##
## ## 为什么需要
##
## 投射物/曳光只由**权威端**的 `ProjectileRuntime` 创建（`LaunchEntity` / `LaunchGround`
## 在真实开火时实例化）。客户端是傀儡、不跑攻击 Action → 客户端**一个弹道节点都没有**。
## 实测（不开 AI + 强制攻击，同一次开枪）：
##   开火次数 服务器 0→7 / 客户端 0→7（信号同步生效）；
##   **弹道视觉节点峰值 服务器 1 / 客户端 0** ← 客户端什么也看不到。
## 也就是说：上一轮补的"开火信号"只带来了 Fire 动画与开火音效，**弹道视觉没补**。
##
## ## 这条路径为什么安全
##
## 客户端实例化的是**同一个投射物场景**，但把 `projectile_runtime` 换成一个
## **空实现桩**（`PresentationRuntime`）：只提供瞄准点，`ResolveImpact` 不做任何事。
## 因此它**只走视觉**（弹体飞行 / 火花 / 拖尾 / 落点爆炸表现），**绝不参与伤害结算**。
##
## 瞄准点用客户端已有的复制数据近似：单位当前朝向（服务器按目标朝向复制 yaw）+ 射程。
## 目标是"**看得出来打出去了**"，不是精确复刻弹道 —— 精确弹道属于权威端。

const RifleRoundScene := "res://source/match/units/projectiles/RifleRound.tscn"
const CannonShellScene := "res://source/match/units/projectiles/CannonShell.tscn"
const RocketScene := "res://source/match/units/projectiles/Rocket.tscn"

## 单位场景 → 弹道场景。与 `CombatSfx.FIRE_SOUND_BY_SCENE` 同款模式：
## 权威映射在 `config/godot/*.assets.v1.json` 的 `weaponAssets`，这里只是**表现层镜像**
## （发射音效已经在用同样的镜像方式，不引入新的真相源）。
const PROJECTILE_BY_UNIT_SCENE := {
	"res://source/match/units/Infantry.tscn": RifleRoundScene,
	"res://source/match/units/Tank.tscn": CannonShellScene,
	"res://source/match/units/AntiGroundTurret.tscn": CannonShellScene,
	"res://source/match/units/AntiAirTurret.tscn": RocketScene,
	"res://source/match/units/Helicopter.tscn": RocketScene,
	"res://source/match/units/Drone.tscn": RocketScene,
}


## 客户端专用的"投射物运行时"桩：给场景提供瞄准点，命中**不做任何结算**。
class PresentationRuntime extends RefCounted:
	var aim := Vector3.ZERO

	func GetAimPoint(_attack_id: String) -> Vector3:
		return aim

	func ResolveImpact(_attack_id: String, _point: Vector3) -> void:
		pass


static func scene_path_for(unit) -> String:
	return str(PROJECTILE_BY_UNIT_SCENE.get(str(unit.scene_file_path), ""))


## 炮口变换：与权威端 `ProjectileRuntime.GetLaunchTransform` 同口径
## （有 `ProjectileOrigin` 子节点就用它，否则用单位自身变换）。
static func muzzle_transform(unit) -> Transform3D:
	var origin = unit.find_child("ProjectileOrigin", true, false)
	if origin is Node3D:
		return (origin as Node3D).global_transform
	return unit.global_transform


## 在客户端回放一次发射。**只影响画面**；非傀儡端直接返回（权威端有自己的真实弹道）。
##
## `authoritative_aim` 由权威端在开火广播里带来（`Unit._fired_aim_payload`）。
## 有它就用它当弹道终点 —— 与权威端同一落点；没有才退回"炮口朝向前方 attack_range 米"
## 的近似（该近似在敌人比射程近时会明显打过头，即用户报的"子弹落点不对"）。
static func present(unit, authoritative_aim: Vector3 = Vector3.INF) -> void:
	if unit == null or not is_instance_valid(unit) or not unit.is_inside_tree():
		return
	if not NetSession.is_client_puppet():
		return
	var scene_path := scene_path_for(unit)
	if scene_path.is_empty():
		return
	var packed = load(scene_path)
	if packed == null:
		return
	var match_node = unit.find_parent("Match")
	if match_node == null:
		return
	var container = match_node.get_node_or_null("Projectiles")
	if container == null:
		return

	var muzzle := muzzle_transform(unit)
	var forward: Vector3 = (-muzzle.basis.z)
	forward.y = 0.0
	if forward.length() < 0.01:
		forward = Vector3(0.0, 0.0, -1.0)
	forward = forward.normalized()
	var reach := float(unit.get("attack_range")) if "attack_range" in unit else 0.0
	if reach <= 0.5:
		reach = 8.0

	var runtime := PresentationRuntime.new()
	if authoritative_aim.is_finite():
		# 权威落点：与服务器同一条弹道的终点（+0.3 与 CannonShell 的视觉抬升同口径）。
		runtime.aim = authoritative_aim + Vector3(0.0, 0.3, 0.0)
	else:
		runtime.aim = muzzle.origin + forward * reach + Vector3(0.0, 0.3, 0.0)
	var projectile = packed.instantiate()
	# 场景 `_ready` 会对这两个字段做非空断言；`attack_id` 只作本地标识。
	projectile.set("attack_id", "present-%d-%d" % [
		Engine.get_physics_frames(), randi() & 0xFFFF])
	projectile.set("projectile_runtime", runtime)
	projectile.set("launch_transform", muzzle)
	projectile.set("visible_snapshot", true)
	container.add_child(projectile)
