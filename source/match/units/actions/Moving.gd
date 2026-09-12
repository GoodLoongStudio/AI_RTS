extends "res://source/match/units/actions/Action.gd"

const OpportunisticMovingFire = preload(
	"res://source/match/units/actions/OpportunisticMovingFire.gd"
)

var _target_position = null
var _enable_opportunistic_fire := false
var _moving_fire = null
## 运行时导航是异步烘焙的，Match 会在烘焙结束后才把单位登记进 "units" 组。
## 在这之前创建的 Action 取不到 _unit/_movement_trait，旧实现直接解引用 Nil 抛
## SCRIPT ERROR 且永久站桩；这里改为惰性解析并在下一帧补发移动。
var _applied := false
## 调试开关：逐命令打印移动目标。默认关闭，避免数百单位刷屏（诊断时置 true）。
static var debug_log_moves := false

@onready var _unit = Utils.NodeEx.find_parent_with_group(self, "units")
@onready var _movement_trait = _unit.find_child("Movement") if _unit != null else null


static func is_applicable(unit):
	return unit.find_child("Movement") != null


func _init(target_position, enable_opportunistic_fire := false):
	_target_position = target_position
	_enable_opportunistic_fire = enable_opportunistic_fire


func _ready():
	_try_apply_move()


func _exit_tree():
	if _movement_trait != null and is_instance_valid(_movement_trait) and is_inside_tree():
		_movement_trait.stop()


func _physics_process(_delta):
	if not _applied:
		_try_apply_move()
		return
	# 自愈(2026-08-31): 旧动作退出时的 stop() 竞态会清除本动作刚下发的移动目标
	# (target_position=INF), 造成「命令 Accepted 但单位站桩」。检测到即重发。
	# 守卫: 单位死亡拆树时 _movement_trait 可能已释放, 悬空访问会崩游戏。
	if _target_position == null or _movement_trait == null:
		return
	if not is_instance_valid(_movement_trait) or not is_inside_tree():
		return
	if _movement_trait.target_position == Vector3.INF:
		_movement_trait.move(_target_position)


## 惰性解析单位与移动特质；单位尚未登记进 "units" 组时留到后续帧重试。
func _try_apply_move():
	if _applied:
		return
	if _unit == null:
		_unit = Utils.NodeEx.find_parent_with_group(self, "units")
	if _unit == null:
		return
	if _movement_trait == null:
		_movement_trait = _unit.find_child("Movement")
	if _movement_trait == null:
		return
	_applied = true
	if debug_log_moves:
		print("[MOVE] ", _unit.name, " move-> ", _target_position)
	_movement_trait.move(_target_position)
	_movement_trait.movement_finished.connect(_on_movement_finished)
	if _enable_opportunistic_fire:
		_moving_fire = OpportunisticMovingFire.new()
		add_child(_moving_fire)


func _on_movement_finished():
	queue_free()


## 在普通或强制移动期间立即应用新的停火策略，不改变导航目标。
func refresh_combat_policy():
	if _moving_fire != null:
		_moving_fire.refresh_weapon_target()
