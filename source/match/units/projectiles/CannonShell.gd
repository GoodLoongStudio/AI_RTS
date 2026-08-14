extends Node3D

var attack_id := ""
var projectile_runtime = null
var launch_transform := Transform3D.IDENTITY
var visible_snapshot := true

@onready var _particles = find_child("OriginParticles")
@onready var _timer = find_child("Timer")


## 使用发射快照初始化炮弹视觉，并把伤害延后到粒子飞行结束时结算。
func _ready():
	assert(not attack_id.is_empty(), "attack instance id was not provided")
	assert(projectile_runtime != null, "projectile runtime was not provided")
	_particles.visible = visible_snapshot
	_particles.global_transform = launch_transform
	_particles.emitting = true
	_timer.timeout.connect(_perform_impact)
	_timer.start(_particles.lifetime)


## 在最后有效瞄准点执行一次权威命中，随后释放视觉节点。
func _perform_impact():
	var impact_point: Vector3 = projectile_runtime.GetAimPoint(attack_id)
	if impact_point.is_finite():
		projectile_runtime.ResolveImpact(attack_id, impact_point)
	queue_free()
