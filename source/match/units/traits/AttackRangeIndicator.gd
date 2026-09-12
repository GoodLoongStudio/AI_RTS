@tool
extends Node3D

## 选中单位/建筑时显示其攻击范围圈（2026-09-12 用户要求："点击炮塔和单位要显示其攻击范围"）。
##
## 挂在 Selection.tscn 下、由 Selection.select()/deselect() 驱动，自己不监听输入。
##
## 为什么直接复用 FadedCircle3D：它与选中圈/悬停圈共用同一套 shader
## （source/shaders/3d/faded_circle.gdshader），线宽按**屏幕像素**恒定 ——
## 8 米的炮塔射程圈在拉远视角下也不会细到看不见；而该 shader 关闭了深度测试
## （depth_test_disabled / depth_draw_never），贴着地形、建筑也能看清。
##
## 半径口径与权威判定完全一致：所有射程比较都是"单位中心到目标中心的水平距离
## <= attack_range"（actions/AttackingWhileInRange、UnitCommandService.ValidateAttack），
## 所以"以单位中心为圆心、attack_range 为半径"的圆就是精确的攻击范围。

## 线宽（屏幕像素）与内外边缘渐变，保持细而清晰的一条线。
const CIRCLE_WIDTH_PIXELS := 6.0
const CIRCLE_INNER_EDGE_PIXELS := 6.0
const CIRCLE_OUTER_EDGE_PIXELS := 6.0
## 画在选中圈（render_priority=10）之下，保证绿色选中圈始终压在最上面。
const CIRCLE_RENDER_PRIORITY := 5

@onready var _circle = $RangeCircle


func _ready():
	# 编辑器里保持可见以便调参数；运行时显隐完全交给 Selection。
	if not Engine.is_editor_hint():
		hide()


## 以 radius_meters 为半径显示攻击范围圈；半径非法（无武器单位）时保持隐藏。
func show_range(radius_meters: float) -> void:
	if _circle == null or not is_finite(radius_meters) or radius_meters <= 0.0:
		hide_range()
		return
	_circle.radius = radius_meters
	_circle.width = CIRCLE_WIDTH_PIXELS
	_circle.inner_edge_width = CIRCLE_INNER_EDGE_PIXELS
	_circle.outer_edge_width = CIRCLE_OUTER_EDGE_PIXELS
	_circle.render_priority = CIRCLE_RENDER_PRIORITY
	_circle.color = Constants.Match.ATTACK_RANGE_CIRCLE_COLOR
	show()


## 隐藏范围圈（取消选中，或该单位没有武器）。
func hide_range() -> void:
	hide()


## 供测试/调试查询：当前是否正在显示范围圈。
func is_range_visible() -> bool:
	return visible and _circle != null


## 供测试/调试查询：当前圈的半径（未显示时为 0）。
func get_range_radius() -> float:
	return _circle.radius if _circle != null and visible else 0.0
