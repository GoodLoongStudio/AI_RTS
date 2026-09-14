extends "res://source/match/units/actions/Action.gd"

const REFRESH_INTERVAL = 1.0 / 60.0 * 10.0

# --- 看门狗（2026-09-14 用户截图实测：坦克挂着攻击动作却原地不动）---
## 为什么要看门狗：重发 `move` 原先只有两个触发点 ——「目标位置变了」或「`movement_finished`」。
## 但 `Movement.stop()` / `suspend_motion()`（我方 hold/固守、安全闸门、交战策略都会调）
## **不会**触发 `movement_finished` → 之后再没人发 `move`，单位**永久停在原地**，
## 而攻击动作仍然活着（界面上的攻击线/标签照旧显示，玩家看到的就是"卡住"）。
## 判据：还在这个动作里 ∧ 不在射程内 ∧ **已经停住** ∧ 距上次重发 ≥ 间隔，
## 才补发一次 `move`（不满足就什么都不做，避免和"已经在走"的正常情况打架）。
const WATCHDOG_SECONDS := 0.6
## "算停住"的速度阈值（米/秒）。0.05 ≈ 肉眼不动。
const WATCHDOG_IDLE_SPEED := 0.05
## 距离上次下发目标还有这么远才算"我们本该在走"（更近就说明已到可达边界，重发只会打转）。
const WATCHDOG_MIN_REMAINING_M := 0.5

var _target_unit = null
var _distance_to_reach = null
var _timer = null
var _last_known_target_unit_position = null
##: 距上次下发/重发 `move` 的累计时间（看门狗用）。
var _since_last_move := 0.0

@onready var _unit = Utils.NodeEx.find_parent_with_group(self, "units")
@onready var _movement_trait = _unit.find_child("Movement")


func _init(target_unit, distance_to_reach):
	_target_unit = target_unit
	_distance_to_reach = distance_to_reach


func _ready():
	_timer = Timer.new()
	_timer.timeout.connect(_refresh)
	add_child(_timer)
	_timer.start(REFRESH_INTERVAL)
	_movement_trait.movement_finished.connect(_on_movement_finished)
	_refresh()


func _exit_tree():
	_movement_trait.stop()


func _refresh():
	_since_last_move += REFRESH_INTERVAL
	if _teardown_if_distance_reached():
		return
	_align_movement_if_needed()
	_watchdog_if_parked()


## 停住且还没到 → 补发一次 `move`（见文件头"看门狗"的实测依据）。
func _watchdog_if_parked():
	if _since_last_move < WATCHDOG_SECONDS:
		return
	var speed: float = (_movement_trait.velocity * Vector3(1, 0, 1)).length()
	if speed > WATCHDOG_IDLE_SPEED:
		return                      # 在走，正常
	# ⚠ 必须显式标注类型：`_unit` 是未类型化节点，`:=` 无法推断（本仓已踩过多次，
	# 未标注会让**整份脚本解析失败 = 全单位无法移动**）。
	var remaining: float = _unit.global_position_yless.distance_to(
		_target_unit.global_position_yless)
	if remaining <= float(_distance_to_reach) + WATCHDOG_MIN_REMAINING_M:
		return                      # 已到可达边界：再发也是原地打转
	_last_known_target_unit_position = null      # 强制 `_align_movement_if_needed` 重发
	_since_last_move = 0.0
	_align_movement_if_needed()


func _teardown_if_distance_reached():
	if (
		_unit.global_position_yless.distance_to(_target_unit.global_position_yless)
		<= _distance_to_reach
	):
		queue_free()
		return true
	return false


func _align_movement_if_needed():
	if (
		_last_known_target_unit_position == null
		or not _last_known_target_unit_position.is_equal_approx(_target_unit.global_position)
	):
		_movement_trait.move(_target_unit.global_position)
		_last_known_target_unit_position = _target_unit.global_position
		_since_last_move = 0.0


func _on_movement_finished():
	# 到达/失败都会走到这里：**必须重发**，否则"到了推离点但还不在射程内"就再也没人推进
	# （这正是看门狗存在的同一个理由，见文件头说明）。
	_movement_trait.move(_target_unit.global_position)
	_last_known_target_unit_position = _target_unit.global_position
	_since_last_move = 0.0
