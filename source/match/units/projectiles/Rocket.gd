extends Node3D

var attack_id := ""
var projectile_runtime = null
var launch_transform := Transform3D.IDENTITY
var visible_snapshot := true
var tracks_target := false
var _aim_point := Vector3.INF

## 火箭飞行速度（米/秒）。与炮弹同理：**必须与射击距离无关**
## （用户 2026-09-12 报"不同射击距离炮弹的飞行速度不一样，这是不允许的"）。
## 本场景动画原本固定 1.5s（`length = 1.5`）→ 距离越远速度越快。
## 这里按 "实际距离 / 固定速度" 反推时长，再用 `speed_scale` 压缩/拉伸动画。
## 取 5.33 m/s 正好等于原先"对空炮塔 8m 射程 / 1.5s"：对空手感完全不变，
## 直升机火箭（5m）与更近距离则按同一速度自然变快。
## 场景可用 metadata `flight_speed_mps` 覆盖。
## 【2026-10-12 用户要求】除重坦外所有弹种弹速 ×2 ⇒ 5.33 → 10.66（兜底值与场景 meta 同值）。
const FLIGHT_SPEED_MPS := 10.66
## 时长下限：贴脸发射时避免 speed_scale 爆掉。
const MIN_FLIGHT_SECONDS := 0.2

@onready var _visuals = find_child("Visuals")
@onready var _path = find_child("Path3D")
@onready var _animation_player = find_child("AnimationPlayer")
@onready var _rocket = find_child("MeshInstance3D")
@onready var _particles = find_child("GPUParticles3D")


## 使用独立攻击快照建立导弹路径；发射者后续退出不会影响本节点。
func _ready():
	assert(not attack_id.is_empty(), "attack instance id was not provided")
	assert(projectile_runtime != null, "projectile runtime was not provided")
	# 投射物根节点和可见 Path3D 都以同一个世界炮口为起点；曲线点随后按
	# Path3D 局部坐标写入，避免任何依赖 Projectiles 容器原点的隐式偏移。
	global_position = launch_transform.origin
	_visuals.visible = visible_snapshot
	_rocket.hide()
	_particles.hide()
	tracks_target = bool(get("tracks_target"))
	_animation_player.animation_finished.connect(func(_animation): queue_free())
	_setup_path()
	_apply_constant_flight_speed()
	await get_tree().physics_frame
	await get_tree().physics_frame
	_animation_player.play("animate")


## 把动画时长改成"实际发射距离 / 固定速度"，消灭"距离越远飞得越快"。
func _apply_constant_flight_speed():
	var animation: Animation = _animation_player.get_animation("animate")
	if animation == null or animation.length <= 0.0:
		return
	var aim_point: Vector3 = projectile_runtime.GetAimPoint(attack_id) if tracks_target else _aim_point
	if not aim_point.is_finite():
		return
	var speed := float(get_meta("flight_speed_mps", FLIGHT_SPEED_MPS))
	if not is_finite(speed) or speed <= 0.0:
		return
	var duration := maxf(
		launch_transform.origin.distance_to(aim_point) / speed, MIN_FLIGHT_SECONDS
	)
	_animation_player.speed_scale = animation.length / duration


## 在目标有效时刷新瞄准点；目标失效后运行时返回最后已知位置。
func _physics_process(_delta):
	if not tracks_target:
		return
	var aim_point: Vector3 = projectile_runtime.GetAimPoint(attack_id)
	if aim_point.is_finite() and _path.curve.point_count >= 2:
		_path.curve.set_point_position(1, _path.to_local(aim_point))


## 使用发射世界坐标和当前瞄准点初始化视觉曲线。
func _setup_path():
	var aim_point: Vector3 = projectile_runtime.GetAimPoint(attack_id)
	_aim_point = aim_point
	# Curve3D 点是 Path3D 的局部坐标；发射快照保存的是世界坐标。
	# 直接把世界坐标塞进曲线会在 Projectiles 容器有变换时整体偏移。
	_path.curve.add_point(_path.to_local(launch_transform.origin))
	_path.curve.add_point(_path.to_local(aim_point))


## 动画抵达末端时仅结算一次实际爆点伤害，并迸发与坦克炮弹同款的火光黑烟。
const EXPLOSION_SCENE := preload(
	"res://source/match/units/projectiles/ShellExplosion.tscn"
)


func _perform_hit():
	if _path.curve.point_count < 2:
		return
	var impact_point: Vector3 = _path.to_global(_path.curve.get_point_position(1))
	# 同 CannonShell：判定半径要在结算前取，结算后这条攻击已从权威表里摘除。
	var blast_radius := float(projectile_runtime.GetWarheadRadius(attack_id))
	projectile_runtime.ResolveImpact(attack_id, impact_point)
	_spawn_explosion(impact_point, blast_radius)


## 落点一次性爆炸：与 CannonShell._spawn_explosion 同款（橙红火光 + 黑烟升腾）。
## 判定半径同样写进 meta，由 ShellExplosion 自适应放大（键名与算法见 ShellExplosion.gd）。
func _spawn_explosion(impact_point: Vector3, blast_radius: float):
	var explosion = EXPLOSION_SCENE.instantiate()
	var parent := get_parent()
	if parent == null:
		return
	explosion.set_meta("blast_radius_m", blast_radius)
	parent.add_child(explosion)
	explosion.global_position = impact_point + Vector3(0.0, 1.2, 0.0)
