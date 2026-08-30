extends Node3D

var attack_id := ""
var projectile_runtime = null
var launch_transform := Transform3D.IDENTITY
var visible_snapshot := true

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
	await get_tree().physics_frame
	await get_tree().physics_frame
	var aim_point: Vector3 = projectile_runtime.GetAimPoint(attack_id)
	var distance := launch_transform.origin.distance_to(aim_point) if aim_point.is_finite() else 6.0
	var flight_seconds := clampf(distance / 10.0, 0.22, 1.1)
	_animation_player.speed_scale = 0.75 / flight_seconds
	_animation_player.play("animate")


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
