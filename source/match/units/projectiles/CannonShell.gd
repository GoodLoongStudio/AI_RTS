extends Node3D

var attack_id := ""
var projectile_runtime = null
var launch_transform := Transform3D.IDENTITY
var visible_snapshot := true

const FLIGHT_SECONDS := 0.5
const ARC_HEIGHT := 0.45
const EXPLOSION_SCENE := preload(
	"res://source/match/units/projectiles/ShellExplosion.tscn"
)

var _elapsed := 0.0
var _impacted := false
# 飞行参数可由场景 metadata 覆盖（RifleRound 用快而平的曳光弹，炮弹用慢而高的抛物线）。
var _flight_seconds := FLIGHT_SECONDS
var _arc_height := ARC_HEIGHT

@onready var _trail: GPUParticles3D = $Trail


## 使用发射快照初始化可见弹体，沿瞄准点飞行后再结算伤害。
func _ready():
	assert(not attack_id.is_empty(), "attack instance id was not provided")
	assert(projectile_runtime != null, "projectile runtime was not provided")
	visible = visible_snapshot
	global_position = launch_transform.origin
	_flight_seconds = float(get_meta("flight_seconds", FLIGHT_SECONDS))
	_arc_height = float(get_meta("arc_height", ARC_HEIGHT))
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
	var ratio := clampf(_elapsed / _flight_seconds, 0.0, 1.0)
	# 视觉终点抬到目标躯干高度，避免末端下坠的炮弹看起来砸进地里。
	var visual_aim := aim_point + Vector3(0.0, 0.3, 0.0)
	var position := origin.lerp(visual_aim, ratio)
	# 直线弹道 + 平方递增的轻微下坠（arc_height 此时表示末端下坠幅度，非抛物线高度）
	position.y -= _arc_height * ratio * ratio
	global_position = position
	var travel := aim_point - origin
	if travel.length_squared() > 0.0001:
		look_at(global_position + travel, Vector3.UP)

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
