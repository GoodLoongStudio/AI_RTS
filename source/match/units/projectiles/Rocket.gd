extends Node3D

var attack_id := ""
var projectile_runtime = null
var launch_transform := Transform3D.IDENTITY
var visible_snapshot := true

## 火箭飞行速度（米/秒）。与炮弹同理：**必须与射击距离无关**
## （用户 2026-09-12 报"不同射击距离炮弹的飞行速度不一样，这是不允许的"）。
## 本场景动画原本固定 1.5s（`length = 1.5`）→ 距离越远速度越快。
## 这里按 "实际距离 / 固定速度" 反推时长，再用 `speed_scale` 压缩/拉伸动画。
## 取 5.33 m/s 正好等于原先"对空炮塔 8m 射程 / 1.5s"：对空手感完全不变，
## 直升机火箭（5m）与更近距离则按同一速度自然变快。
## 场景可用 metadata `flight_speed_mps` 覆盖。
const FLIGHT_SPEED_MPS := 5.33
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
	_visuals.visible = visible_snapshot
	_rocket.hide()
	_particles.hide()
	_animation_player.animation_finished.connect(func(_animation): queue_free())
	_setup_path()
	_apply_constant_flight_speed()
	await get_tree().physics_frame
	await get_tree().physics_frame
	_animation_player.play("animate")


## 把动画时长改成"实际发射距离 / 固定速度"，消灭"距离越远飞得越快"。
func _apply_constant_flight_speed():
	var animation := _animation_player.get_animation("animate")
	if animation == null or animation.length <= 0.0:
		return
	var aim_point: Vector3 = projectile_runtime.GetAimPoint(attack_id)
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
	var aim_point: Vector3 = projectile_runtime.GetAimPoint(attack_id)
	if aim_point.is_finite() and _path.curve.point_count >= 2:
		_path.curve.set_point_position(1, aim_point)


## 使用发射世界坐标和当前瞄准点初始化视觉曲线。
func _setup_path():
	var aim_point: Vector3 = projectile_runtime.GetAimPoint(attack_id)
	_path.curve.add_point(launch_transform.origin)
	_path.curve.add_point(aim_point)


## 动画抵达末端时仅结算一次实际爆点伤害。
func _perform_hit():
	if _path.curve.point_count < 2:
		return
	projectile_runtime.ResolveImpact(attack_id, _path.curve.get_point_position(1))
