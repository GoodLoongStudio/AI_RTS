extends Node3D

var attack_id := ""
var projectile_runtime = null
var launch_transform := Transform3D.IDENTITY
var visible_snapshot := true

const FLIGHT_SECONDS := 0.5
const ARC_HEIGHT := 0.45

var _elapsed := 0.0
var _impacted := false

@onready var _trail: GPUParticles3D = $Trail


## 使用发射快照初始化可见弹体，沿瞄准点飞行后再结算伤害。
func _ready():
	assert(not attack_id.is_empty(), "attack instance id was not provided")
	assert(projectile_runtime != null, "projectile runtime was not provided")
	visible = visible_snapshot
	global_position = launch_transform.origin
	if _trail != null:
		_trail.emitting = true


func _process(delta: float):
	if _impacted:
		return
	_elapsed += delta
	var aim_point: Vector3 = projectile_runtime.GetAimPoint(attack_id)
	if not aim_point.is_finite():
		return

	var origin: Vector3 = launch_transform.origin
	var ratio := clampf(_elapsed / FLIGHT_SECONDS, 0.0, 1.0)
	var position := origin.lerp(aim_point, ratio)
	position.y += sin(ratio * PI) * ARC_HEIGHT
	global_position = position
	var travel := aim_point - origin
	if travel.length_squared() > 0.0001:
		look_at(global_position + travel, Vector3.UP)

	if ratio >= 1.0:
		_perform_impact()


## 在最后有效瞄准点执行一次权威命中，随后释放视觉节点。
func _perform_impact():
	if _impacted:
		return
	_impacted = true
	var impact_point: Vector3 = projectile_runtime.GetAimPoint(attack_id)
	if impact_point.is_finite():
		projectile_runtime.ResolveImpact(attack_id, impact_point)
	queue_free()
