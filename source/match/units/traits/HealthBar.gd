@tool
extends Node3D

const BAR_AUTO_VISIBILITY_DURATION = 2.0

@export var size = Vector2(200, 20):
	set(value):
		size = value
		find_child("ActualBar").texture.width = size.x
		find_child("ActualBar").texture.height = size.y

var _bar_value_initialized = false
## 单位是否处于选中态。选中期间血条常显，伤害触发的续期不得启动自动隐藏计时器。
var _selected = false

@onready var _unit = get_parent()
@onready var _actual_bar = find_child("ActualBar")
@onready var _visibility_timer = find_child("Timer")


func _ready():
	if Engine.is_editor_hint():
		return
	hide()
	_apply_enemy_color_if_needed()
	_recalulate_bar_value()
	_unit.selected.connect(_on_unit_selected)
	_unit.deselected.connect(_on_unit_deselected)
	_unit.hp_changed.connect(_on_hp_changed)
	_visibility_timer.timeout.connect(_on_visibility_timer_timeout)
	# 【2026-10-10 残血常显】出生/镜像进来时就已经受伤的单位，也要立刻显示血条
	# （客户端中途加入、或单位在 _ready 之前就掉过血）。
	_sync_visibility()


## 【2026-10-10 用户口径】残血（受伤）单位与建筑的血条**常显**。
##
## 判据 = 有 hp/hp_max、**不是施工中的建筑**、且 hp < hp_max。
##
## ⚠️ 为什么必须排除施工中的建筑：`Structure.mark_as_under_construction()` 故意把 hp 置 1，
## 之后按施工进度 `1 + progress * (hp_max - 1)` 逐段补血（`Structure.gd:96`、`:108-112`）。
## 若直接按 "hp < hp_max" 判定，**所有在建建筑都会常显血条**（明显观感回归）。
func _is_damaged() -> bool:
	if _unit.hp == null or _unit.hp_max == null:
		return false
	if _unit.has_method("is_under_construction") and _unit.is_under_construction():
		return false
	return float(_unit.hp) < float(_unit.hp_max)


## 可见性**单一入口**：选中或残血 ⇒ 常显（并停掉自动隐藏计时器）；
## 否则"没有待熄灭的窗口"时隐藏（保留"数值变化后闪 2 秒"的既有行为）。
func _sync_visibility():
	if _selected or _is_damaged():
		_visibility_timer.stop()
		show()
		return
	if _visibility_timer.is_stopped():
		hide()


## 非本地玩家的单位血条染红（满血红色，随血量衰减到灰）。
func _apply_enemy_color_if_needed():
	var match_node = _unit.find_parent("Match")
	if match_node == null or not match_node.has_method("get_local_player"):
		return
	var local_player = match_node.get_local_player()
	if local_player == null or _unit.get_parent() == local_player:
		return
	var gradient: Gradient = _actual_bar.texture.gradient
	gradient.set_color(0, Color(0.9, 0.12, 0.05, 1.0))


func _recalulate_bar_value():
	if _unit.hp == null or _unit.hp_max == null:
		return
	var old_value = _actual_bar.texture.gradient.get_offset(1)
	var new_value = float(_unit.hp) / _unit.hp_max
	new_value = new_value if not is_equal_approx(new_value, 1.0) else 1.1  # fixing 1px gap
	_actual_bar.texture.gradient.set_offset(1, new_value)
	# ⚠️ 必须用 `is_equal_approx`，不能写 `old_value != new_value`：
	# `get_offset()` 读回的是 **float32**（0.7 会变成 0.69999998807907），
	# 而 `float(hp) / hp_max` 是 float64 的 0.7 ⇒ 精确比较**恒不相等**，
	# 于是每次 `hp_changed`（包括网络快照每帧重复赋同一个值）都会无谓点亮血条
	# ⇒ 血条在毫无变化时也一闪一闪（用户 2026-09-10 报告的另一半现象，
	# `HealthBarFlickerSmokeTest` 断言 4 覆盖）。
	if _bar_value_initialized and not is_equal_approx(old_value, new_value):
		_show_for_a_while()
	_bar_value_initialized = true
	# 【2026-10-10 残血常显】数值变化后立刻同步一次：
	# 残血 ⇒ 停表常显；刚修满 ⇒ 保留 `_show_for_a_while()` 起的 2s 窗口，窗口结束后再隐藏。
	_sync_visibility()


func _show_for_a_while():
	show()
	# ⚠️ 不能因为「已经可见」就早退（2026-09-10 之前的实现就是这样）：
	# 早退不会续期自动隐藏计时器，于是只要伤害间隔短于 BAR_AUTO_VISIBILITY_DURATION，
	# 计时器每次都从**首次**伤害起算、在同一时刻到点熄灭，下一次伤害再把血条点亮
	# ⇒ 周期性闪烁。用户报告的"血条一闪一闪"就是这个（`HealthBarFlickerSmokeTest` 覆盖）。
	# 现在每次伤害都重新 start()，以最后一次伤害为基准续期。
	# 选中期间由 `_on_unit_selected()` 常显，这里不碰计时器，否则会在选中中把血条熄灭。
	if not _selected:
		_visibility_timer.start(BAR_AUTO_VISIBILITY_DURATION)


func _on_unit_selected():
	_selected = true
	_visibility_timer.stop()
	show()


func _on_unit_deselected():
	_selected = false
	# 【2026-10-10 残血常显】取消选中不再无条件隐藏：仍残血就继续显示。
	_sync_visibility()


func _on_hp_changed():
	_recalulate_bar_value()


func _on_visibility_timer_timeout():
	# 兜底：选中或残血期间不该熄灭（正常路径下计时器已被 _sync_visibility() 停掉）。
	if _selected or _is_damaged():
		return
	hide()
