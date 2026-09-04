extends Node

## 步兵程序化骨骼动画（期 2 Step10）：外部动作剪辑尚未产出，本驱动按绑骨管线
## full_anim.py 的姿态函数在 Godot 内实时驱动 Skeleton3D，提供待命/行走/开火三态。
## 待动作剪辑就绪后可整体替换为 AnimationPlayer，而单位场景与测试不受影响。

const ATTACK_ACTION_SUFFIXES := [
	"OrdinaryAttacking.gd",
	"AutoAttacking.gd",
	"AttackingWhileInRange.gd",
	"ExplicitForceAttacking.gd",
]
const BONES := [
	"Hips", "Spine", "Spine2", "Head",
	"LeftArm", "RightArm", "LeftForeArm", "RightForeArm",
	"LeftUpLeg", "RightUpLeg", "LeftLeg", "RightLeg",
]
const MOVE_SPEED_EPSILON := 0.25
## 手臂从 T-Pose 垂放的轴向与角度（轴扫描截图验证：双臂同绕 X 轴 -90° 正确）
@export var arm_axis := 0
@export var arm_down_degrees := -90.0
## 行走摆频（Hz）
@export var walk_cycle_hz := 0.9

var _skeleton: Skeleton3D
var _unit: Node
var _time := 0.0
var _last_position := Vector3.INF
var _moving := false
var _bone_indices := {}
var _rest_rotations := {}


func _ready() -> void:
	_unit = get_parent()
	_skeleton = _unit.find_child("Skeleton3D", true, false)
	if _skeleton == null:
		push_warning("InfantryAnimationDriver: 未找到 Skeleton3D，动画驱动停用")
		set_process(false)
		return
	for bone in BONES:
		var index := _skeleton.find_bone(bone)
		if index >= 0:
			_bone_indices[bone] = index
			_rest_rotations[bone] = _skeleton.get_bone_rest(index).basis.get_rotation_quaternion()


func _process(delta: float) -> void:
	if _skeleton == null:
		return
	_time += delta
	_update_moving(delta)
	if _moving:
		_pose_walk()
	elif _is_attacking():
		_pose_attack()
	else:
		_pose_idle()


func _update_moving(delta: float) -> void:
	var position: Vector3 = _unit.global_position
	if _last_position == Vector3.INF:
		_last_position = position
		return
	var displacement := position - _last_position
	displacement.y = 0.0
	_moving = displacement.length() / maxf(delta, 0.0001) > MOVE_SPEED_EPSILON
	_last_position = position


func _is_attacking() -> bool:
	var action = _unit.get("action")
	if action == null or action.get_script() == null:
		return false
	var script_path := str(action.get_script().resource_path)
	for suffix in ATTACK_ACTION_SUFFIXES:
		if script_path.ends_with(suffix):
			return true
	return false


func _set_rot(bone: String, axis: int, degrees: float) -> void:
	if not _bone_indices.has(bone):
		return
	var axis_vectors := [Vector3(1, 0, 0), Vector3(0, 1, 0), Vector3(0, 0, 1)]
	var axis_vector: Vector3 = axis_vectors[axis]
	_skeleton.set_bone_pose_rotation(
		_bone_indices[bone],
		_rest_rotations[bone] * Quaternion(axis_vector, deg_to_rad(degrees))
	)


## 双臂从 T-Pose 垂放到持枪下垂位（左右骨骼 rest 非镜像，需同号旋转）。
func _arm_down() -> void:
	_set_rot("LeftArm", arm_axis, arm_down_degrees)
	_set_rot("RightArm", arm_axis, arm_down_degrees)


## 待命：轻微呼吸起伏 + 双臂持枪下垂。
func _pose_idle() -> void:
	var sway := sin(_time * PI / 2.0)
	_arm_down()
	_set_rot("LeftForeArm", 0, -12.0)
	_set_rot("RightForeArm", 0, -12.0)
	_set_rot("Spine", 0, 2.0 * sway)
	_set_rot("Hips", 0, 1.2 * sway)
	_set_rot("Head", 2, 4.0 * sin(_time * PI / 4.0))


## 行走：摆腿摆臂 + 髋部摆动（频率随配置，幅度沿用绑骨管线行走姿态）。
func _pose_walk() -> void:
	var cycle := fmod(_time * walk_cycle_hz, 1.0) * 2.0 * PI
	var swing := sin(cycle)
	var counter_swing := sin(cycle * 0.5 + PI / 3.0)
	_set_rot("LeftUpLeg", 0, 36.0 * swing)
	_set_rot("RightUpLeg", 0, -36.0 * swing)
	_set_rot("LeftLeg", 0, maxf(0.0, -28.0 * cos(cycle)))
	_set_rot("RightLeg", 0, maxf(0.0, 28.0 * cos(cycle)))
	_set_rot("LeftArm", arm_axis, arm_down_degrees + 26.0 * counter_swing)
	_set_rot("RightArm", arm_axis, arm_down_degrees + 26.0 * counter_swing)
	_set_rot("LeftForeArm", 0, -18.0)
	_set_rot("RightForeArm", 0, -18.0)
	_set_rot("Hips", 2, 3.5 * swing)


## 开火：双手端枪指向正前 + 随冷却节奏的后坐起伏。
func _pose_attack() -> void:
	var recoil := sin(fmod(_time, 0.6) / 0.6 * PI) * 8.0
	_set_rot("LeftArm", arm_axis, arm_down_degrees)
	_set_rot("RightArm", arm_axis, arm_down_degrees)
	_set_rot("LeftForeArm", 0, -70.0)
	_set_rot("RightForeArm", 0, -70.0)
	_set_rot("Spine2", 2, -6.0 + recoil)
