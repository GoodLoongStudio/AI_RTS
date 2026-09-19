extends Node3D

var attack_id := ""
var projectile_runtime = null
var launch_transform := Transform3D.IDENTITY
var visible_snapshot := true

## 弹体飞行速度（米/秒）。**必须与射击距离无关**：用户 2026-09-12 报
## "不同射击距离炮弹的飞行速度不一样" —— 根因是原先按**固定飞行时长**建模
## （`flight_seconds` = 0.65），速度 = 距离 / 时长 → 距离越远飞得越快。
## 现在改成固定速度：飞行时长 = 实际距离 / 速度，任何射击距离上速度都一致。
## 不同武器想要不同速度，由场景 metadata `flight_speed_mps` 覆盖
## （炮弹 12 m/s ≈ 原先 7.5m 处的手感；步枪曳光 45 m/s）。
const FLIGHT_SPEED_MPS := 12.0
## 兜底飞行时长：只在取不到有效瞄准点（拿不到距离）时才用，正常路径不会走到。
const FLIGHT_SECONDS := 0.5
## 飞行时长下限：贴脸射击距离≈0 时避免出现 0/负时长。
const MIN_FLIGHT_SECONDS := 1.0 / 120.0
const ARC_HEIGHT := 0.45
const EXPLOSION_SCENE := preload(
	"res://source/match/units/projectiles/ShellExplosion.tscn"
)

var _elapsed := 0.0
var _impacted := false
# 飞行参数可由场景 metadata 覆盖（RifleRound 用快而平的曳光弹，炮弹用慢而高的抛物线）。
var _flight_seconds := FLIGHT_SECONDS
var _arc_height := ARC_HEIGHT
var _show_impact_explosion := true

@onready var _trail: GPUParticles3D = $Trail


## 使用发射快照初始化可见弹体，沿瞄准点飞行后再结算伤害。
func _ready():
	assert(not attack_id.is_empty(), "attack instance id was not provided")
	assert(projectile_runtime != null, "projectile runtime was not provided")
	visible = visible_snapshot
	global_position = launch_transform.origin
	# 固定速度模型：飞行时长由**真实发射距离**反推，保证同一武器在任何射击距离上速度一致。
	var speed := float(get_meta("flight_speed_mps", FLIGHT_SPEED_MPS))
	var launch_aim: Vector3 = projectile_runtime.GetAimPoint(attack_id)
	if is_finite(speed) and speed > 0.0 and launch_aim.is_finite():
		_flight_seconds = maxf(
			launch_transform.origin.distance_to(launch_aim) / speed, MIN_FLIGHT_SECONDS
		)
	else:
		# 取不到瞄准点时退回旧的固定时长口径（正常路径不会走到）。
		_flight_seconds = float(get_meta("flight_seconds", FLIGHT_SECONDS))
	_arc_height = float(get_meta("arc_height", ARC_HEIGHT))
	# 步枪等轻武器命中不炸出火光，只有炮弹类落点爆炸。
	_show_impact_explosion = bool(get_meta("impact_explosion", true))
	if _trail != null:
		_trail.emitting = true
	_lock_flight_orientation(launch_aim)


## 弹体朝向**只在发射瞬间确定**，飞行途中不再重算。
##
## 用户 2026-09-15 报"子弹射出会旋转"：原实现在 `_process` 里每帧
## `look_at(global_position + (当前瞄准点 - 发射点), UP)`，而权威端
## `ProjectileRuntime.GetAimPoint` 对**活着的目标**会持续返回目标当前位置（追瞄是玩法设计，
## 落点/伤害口径不动）——于是瞄准点一移动，弹体每帧都被重新定向，看起来就是边飞边转。
## 探针实测（`tools/probe_projectile_orientation.gd`）：目标横移时弹体偏航 -10°→-35°，单帧最大 6.96°；修后 0.000°。
## 现在朝向在发射时锁死：弹体只平移不旋转，与"炮弹沿发射方向飞"的直觉一致。
func _lock_flight_orientation(launch_aim: Vector3) -> void:
	var travel := launch_aim - launch_transform.origin
	if not travel.is_finite() or travel.length_squared() <= 0.0001:
		# 拿不到有效瞄准点：沿用炮口朝向，绝不留给引擎一个随机 basis。
		global_transform.basis = launch_transform.basis.orthonormalized()
		return
	# 近乎垂直的射击会让 look_at 的 UP 参考退化（cross ≈ 0 → basis 乱转），换一个参考轴。
	var direction := travel.normalized()
	var up := Vector3.UP if absf(direction.dot(Vector3.UP)) < 0.999 else Vector3.FORWARD
	look_at(global_position + travel, up)


func _process(delta: float):
	if _impacted:
		return
	_elapsed += delta
	var aim_point: Vector3 = projectile_runtime.GetAimPoint(attack_id)
	if not aim_point.is_finite():
		return

	var origin: Vector3 = launch_transform.origin
	var ratio := clampf(_elapsed / _flight_seconds, 0.0, 1.0)
	# 视觉终点抬到目标躯干高度，避免末端下坠的炮弹看起来砸进地里。
	var visual_aim := aim_point + Vector3(0.0, 0.3, 0.0)
	var position := origin.lerp(visual_aim, ratio)
	# 直线弹道 + 平方递增的轻微下坠（arc_height 此时表示末端下坠幅度，非抛物线高度）
	position.y -= _arc_height * ratio * ratio
	global_position = position
	# ⚠ 这里**不能**再 `look_at(当前瞄准点)`：朝向已在 `_ready` 锁定（见 `_lock_flight_orientation`）。
	# 弹体飞行途中只平移、不旋转 —— 否则追移动目标时弹体会持续转向（用户实测报障）。

	if ratio >= 1.0:
		_perform_impact()


## 在最后有效瞄准点执行一次权威命中，在落点迸发火光与黑烟，随后释放视觉节点。
func _perform_impact():
	if _impacted:
		return
	_impacted = true
	var impact_point: Vector3 = projectile_runtime.GetAimPoint(attack_id)
	if impact_point.is_finite():
		projectile_runtime.ResolveImpact(attack_id, impact_point)
		if _show_impact_explosion:
			_spawn_explosion(impact_point)
	queue_free()


## 落点一次性爆炸：橙红火光 + 黑烟升腾（挂到 Projectiles 容器避免随弹体销毁）。
func _spawn_explosion(impact_point: Vector3):
	var explosion = EXPLOSION_SCENE.instantiate()
	var parent := get_parent()
	if parent == null:
		return
	parent.add_child(explosion)
	explosion.global_position = impact_point + Vector3(0.0, 0.2, 0.0)
