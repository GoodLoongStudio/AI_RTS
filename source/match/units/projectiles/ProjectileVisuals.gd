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
	# 同 CombatSfx.FIRE_SOUND_BY_SCENE：新单位漏登记 → 客户端**看不到任何弹道/开火表现**
	# （权威端照常发射，只是傀儡端没有可回放的弹道视觉）。
	"res://source/match/units/HeavyTank.tscn": CannonShellScene,
	"res://source/match/units/APC.tscn": RifleRoundScene,
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


## 漏登记报错去重（每个场景只报一次），见 scene_path_for()。
static var _missing_projectile_reported := {}


static func scene_path_for(unit) -> String:
	var scene := str(unit.scene_file_path)
	var path := str(PROJECTILE_BY_UNIT_SCENE.get(scene, ""))
	# 同 CombatSfx.fire_key_for：漏登记过去是静默的（客户端"看不到弹道"），
	# 这里补一条明确报错，每个场景只报一次。
	if path.is_empty() and not _missing_projectile_reported.has(scene):
		_missing_projectile_reported[scene] = true
		push_error("[VFX] 单位未登记弹道表现（ProjectileVisuals.PROJECTILE_BY_UNIT_SCENE）: %s" % scene)
	return path


## 炮口变换：与权威端 `ProjectileRuntime.GetLaunchTransform` 同口径
## （有 `ProjectileOrigin` 子节点就用它，否则用单位自身变换）。
static func muzzle_transform(unit) -> Transform3D:
	var alternating = _alternating_muzzle(unit)
	if alternating is Node3D:
		return (alternating as Node3D).global_transform
	var origin = unit.find_child("ProjectileOrigin", true, false)
	if origin is Node3D:
		return (origin as Node3D).global_transform
	return unit.global_transform


## 多炮管单位的**交替炮口**：按 `MuzzleL` / `MuzzleR` 逐发轮换
## （2026-09-12 用户要求"两根炮管交替发射，不要从中间出来"）。
## 计数放在**单位自身的 meta** 上（键 `muzzle_next_left`）：
## 两端各自独立计数，但客户端是逐发回放权威端的开火事件，
## 所以顺序天然同相 —— 第 1 发两端都走左、第 2 发都走右。
## 没有这两个挂点的单位返回 null，退回原来的 `ProjectileOrigin` 口径。
static func _alternating_muzzle(unit):
	var left = unit.find_child("MuzzleL", true, false)
	var right = unit.find_child("MuzzleR", true, false)
	if not (left is Node3D) or not (right is Node3D):
		return null
	var next_left := true
	if unit.has_meta("muzzle_next_left"):
		next_left = bool(unit.get_meta("muzzle_next_left"))
	unit.set_meta("muzzle_next_left", not next_left)
	return left if next_left else right


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
	# 轴向约定必须与单位类型一致（2026-09-12 用户报"炮管朝着目标、炮弹却往反方向飞"）：
	# 机动单位（坦克/步兵/飞机）车体正前方是 **-Z**；
	# 而炮塔类建筑的炮管正前方是 **+Z**（见 AttackingWhileInRange._turret_aim_error_degrees
	# 与炮塔瞄准旋转）。原先这里统一取 -Z，炮塔在没有权威落点时就会朝反方向打。
	var forward: Vector3
	if unit.has_method("presentation_aim_node") and unit.presentation_aim_node() != null:
		forward = muzzle.basis.z
	else:
		forward = -muzzle.basis.z
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
