extends SceneTree

# 炮塔战斗流程模拟：按 AttackingWhileInRange 的实际逻辑（根节点限速转向 + 同步器跟随），
# 每 10 帧记录 root/mesh/muzzle 朝向，验证炮管是否正确指向目标。
# 用法: godot --headless --path . -s res://dev/turret_diag.gd

const TURN_SPEED_DEG := 90.0  # 与 AttackingWhileInRange.STATIONARY_TURN_SPEED_DEG_PER_SEC 一致

var _frame := 0
var _turret: Node3D
# 目标方向：+X（东），根初始朝 -Z（北）→ 需要顺时针转 90°（yaw -90°）
var _target_dir := Vector3(1, 0, 0)


func _initialize():
	var scene: PackedScene = load("res://source/match/units/AntiGroundTurret.tscn")
	_turret = scene.instantiate()
	root.add_child(_turret)


func _process(delta: float) -> bool:
	_frame += 1
	match _frame:
		2:
			_dump("初始")
		10:
			pass  # 开始转向
	if _frame >= 10 and _frame <= 200:
		_simulate_combat_rotation(delta)
	if _frame == 20 or _frame == 40 or _frame == 60 or _frame == 90 or _frame == 130:
		_dump("转向中 f%d" % _frame)
	if _frame == 200:
		_dump("结束")
		return true  # quit
	return false


## 逐帧复刻新的战斗瞄准逻辑：炮塔直接旋转炮管节点（mesh）而非根节点。
func _simulate_combat_rotation(delta: float) -> void:
	var mesh: Node3D = _turret.get_node("DetachTransform/Geometry/SM_Veh_Turret_Large_01")
	var turn_speed := TURN_SPEED_DEG
	var target_yaw := atan2(-_target_dir.x, -_target_dir.z)
	var current_yaw := mesh.global_transform.basis.get_euler().y
	var yaw_diff := angle_difference(current_yaw, target_yaw)
	if absf(yaw_diff) < 0.01:
		return
	var max_step := deg_to_rad(turn_speed) * delta
	var new_yaw := current_yaw + clampf(yaw_diff, -max_step, max_step)
	mesh.global_rotation_degrees.y = rad_to_deg(new_yaw)


func _dump(label: String) -> void:
	var mesh: Node3D = _turret.get_node("DetachTransform/Geometry/SM_Veh_Turret_Large_01")
	var muzzle: Node3D = _turret.get_node(
		"DetachTransform/Geometry/SM_Veh_Turret_Large_01/ProjectileOrigin"
	)
	var to_target_yaw := atan2(-_target_dir.x, -_target_dir.z)
	print("==== %s ====" % label)
	print("root yaw   = %7.2f  (目标 yaw = %.2f)" % [
		rad_to_deg(_turret.global_transform.basis.get_euler().y), rad_to_deg(to_target_yaw)])
	print("mesh yaw(global) = %7.2f" % rad_to_deg(mesh.global_transform.basis.get_euler().y))
	print("muzzle pos = ", muzzle.global_position)
	# 炮口相对根的位置（正面应为 -Z 侧再随转向旋转）
	var muzzle_local_to_root: Vector3 = (
		_turret.global_transform.affine_inverse() * muzzle.global_position
	)
	print("muzzle@root局部 = ", muzzle_local_to_root)
