extends Node3D

var attack_id := ""
var projectile_runtime = null
var launch_transform := Transform3D.IDENTITY
var visible_snapshot := true

const SPEED_METERS_PER_SECOND := 14.0
const MIN_FLIGHT_SECONDS := 0.18
const MAX_FLIGHT_SECONDS := 0.85

var _elapsed := 0.0
var _flight_seconds := 0.45
var _impacted := false

@onready var _trail: GPUParticles3D = $Trail


## 使用发射快照初始化可见弹体，沿瞄准点飞行后再结算伤害。
func _ready():
	assert(not attack_id.is_empty(), "attack instance id was not provided")
	assert(projectile_runtime != null, "projectile runtime was not provided")
	visible = visible_snapshot
	global_position = launch_transform.origin
	_flight_seconds = _duration_to(projectile_runtime.GetAimPoint(attack_id))
	if _trail != null:
		_trail.emitting = true
	AudioDirector.play("cannon_fire")


func _process(delta: float):
	if _impacted:
		return
	_elapsed += delta
	var aim_point: Vector3 = projectile_runtime.GetAimPoint(attack_id)
	if not aim_point.is_finite():
		return

	var origin: Vector3 = launch_transform.origin
	var ratio := clampf(_elapsed / _flight_seconds, 0.0, 1.0)
	var travel := aim_point - origin
	var arc_height := clampf(travel.length() * 0.06, 0.2, 0.7)
	var position := origin.lerp(aim_point, ratio)
	position.y += sin(ratio * PI) * arc_height
	global_position = position
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
	AudioDirector.play("impact")
	queue_free()


func _duration_to(aim_point: Vector3) -> float:
	if not aim_point.is_finite():
		return 0.45
	var distance := launch_transform.origin.distance_to(aim_point)
	return clampf(distance / SPEED_METERS_PER_SECOND, MIN_FLIGHT_SECONDS, MAX_FLIGHT_SECONDS)
