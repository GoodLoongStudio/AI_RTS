extends Node3D

@export var rectangular_selection_3d: NodePath

var _rectangular_selection_3d = null
var _highlighted_units = Utils.Set.new()
## 最近一次拖动拿到的屏幕矩形（finished/finished_rect 两个信号合并用）。
var _pending_screen_rect = null


func _ready():
	_rectangular_selection_3d = get_node_or_null(rectangular_selection_3d)
	if _rectangular_selection_3d == null:
		return
	_rectangular_selection_3d.started.connect(_on_selection_started)
	_rectangular_selection_3d.interrupted.connect(_on_selection_interrupted)
	_rectangular_selection_3d.finished.connect(_on_selection_finished)
	if _rectangular_selection_3d.has_signal("finished_rect"):
		_rectangular_selection_3d.finished_rect.connect(_on_selection_finished_rect)
	if _rectangular_selection_3d.has_signal("changed_rect"):
		_rectangular_selection_3d.changed_rect.connect(_on_selection_changed_rect)


func _force_highlight(units_to_highlight):
	for unit in units_to_highlight.iterate():
		var highlight = unit.find_child("Highlight")
		if highlight != null:
			highlight.force()


func _unforce_highlight(units_not_to_highlight_anymore):
	for unit in units_not_to_highlight_anymore.iterate():
		if unit == null:
			continue
		var highlight = unit.find_child("Highlight")
		if highlight != null:
			highlight.unforce()


func _get_controlled_units_from_navigation_domain_within_topdown_polygon_2d(
	navigation_domain, topdown_polygon_2d
):
	if topdown_polygon_2d == null:
		return Utils.Set.new()
	var camera = get_viewport().get_camera_3d()
	var units_within_polygon = Utils.Set.new()
	for unit in get_tree().get_nodes_in_group("controlled_units"):
		if not unit.visible or not _domain_matches(unit, navigation_domain):
			continue
		var unit_position_2d = Vector2(unit.transform.origin.x, unit.transform.origin.z)
		if navigation_domain == Constants.Match.Navigation.Domain.AIR:
			unit_position_2d = _air_unit_topdown_position_2d(unit, camera, unit_position_2d)
		if Geometry2D.is_point_in_polygon(unit_position_2d, topdown_polygon_2d):
			units_within_polygon.add(unit)
	return units_within_polygon


## 【2026-09-29 用户要求"框选可以支持任何单位"】域匹配放宽：
## 旧实现 `unit.movement_domain != navigation_domain` 是严格相等，读不到域
## （Movement/MovementObstacle 都没挂，`_get_movement_domain()` 返回 null）的单位
## 在 TERRAIN 与 AIR 两次扫描里都被跳过 → 永远无法框选，只能点选。
## 现在：读不到域的单位按地面单位收下（保守但不漏）；有域的仍按原域精确分流。
func _domain_matches(unit, navigation_domain) -> bool:
	var domain_value = unit.get("movement_domain")
	if domain_value == null:
		return int(navigation_domain) == Constants.Match.Navigation.Domain.TERRAIN
	return int(domain_value) == int(navigation_domain)


## 空中单位贴地 HOVER_OFFSET 飞行，而 `topdown_polygon_2d` 是"屏幕像素 → 地表"的投影
## （见 RectangularSelection3D._screen_rect_2d_to_topdown_polygon_2d）。直接拿飞机的 XZ
## 去比会因俯角视差与地形高差错位（实测能差出十几米），框住了也选不中；沿同一条视线
## 把它投到遮住的地面点，判定才和玩家所见一致。旧实现改投 Constants.Match.Air.PLANE
## (y=40，只是空域导航的烘焙参考高度)，而相机离地 25~35 米俯视、射线打不到该平面
## ⇒ 恒为 null ⇒ 空军整批不参与框选。
func _air_unit_topdown_position_2d(unit, camera, fallback_position_2d: Vector2) -> Vector2:
	if camera == null:
		return fallback_position_2d
	var ground_hit = camera.get_ray_intersection(
		camera.unproject_position(unit.global_position)
	)
	if ground_hit == null:
		return fallback_position_2d
	return Vector2(ground_hit.x, ground_hit.z)


func _on_selection_started():
	_rectangular_selection_3d.changed.connect(_on_selection_changed)
	_pending_screen_rect = null


func _on_selection_changed(topdown_polygon_2d):
	var units_to_highlight = _get_controlled_units_from_navigation_domain_within_topdown_polygon_2d(
		Constants.Match.Navigation.Domain.TERRAIN, topdown_polygon_2d
	)
	units_to_highlight.merge(
		_get_controlled_units_from_navigation_domain_within_topdown_polygon_2d(
			Constants.Match.Navigation.Domain.AIR, topdown_polygon_2d
		)
	)
	var units_not_to_highlight_anymore = Utils.Set.subtracted(
		_highlighted_units, units_to_highlight
	)
	_force_highlight(units_to_highlight)
	_unforce_highlight(units_not_to_highlight_anymore)
	_highlighted_units = units_to_highlight


func _on_selection_interrupted():
	_rectangular_selection_3d.changed.disconnect(_on_selection_changed)
	if _rectangular_selection_3d.has_signal("changed_rect") and \
			_rectangular_selection_3d.changed_rect.is_connected(_on_selection_changed_rect):
		_rectangular_selection_3d.changed_rect.disconnect(_on_selection_changed_rect)
	_unforce_highlight(_highlighted_units)
	_highlighted_units = Utils.Set.new()
	_pending_screen_rect = null


func _on_selection_finished(topdown_polygon_2d):
	_rectangular_selection_3d.changed.disconnect(_on_selection_changed)
	_unforce_highlight(_highlighted_units)
	_highlighted_units = Utils.Set.new()
	var units_to_select = _get_controlled_units_from_navigation_domain_within_topdown_polygon_2d(
		Constants.Match.Navigation.Domain.TERRAIN, topdown_polygon_2d
	)
	units_to_select.merge(
		_get_controlled_units_from_navigation_domain_within_topdown_polygon_2d(
			Constants.Match.Navigation.Domain.AIR, topdown_polygon_2d
		)
	)
	# 屏幕矩形口径（真实运行两个信号都会到；只发 polygon 的测试/回退路径到此为止）
	if _pending_screen_rect != null:
		units_to_select.merge(_collect_air_units_within_screen_rect(_pending_screen_rect))
		_pending_screen_rect = null
	Utils.Match.select_units(units_to_select)


## 屏幕矩形口径的收尾事件：缓存矩形，与同一批的 finished(polygon) 合并成一次选中。
func _on_selection_finished_rect(screen_rect_2d):
	if screen_rect_2d == null:
		return
	var polygon = null
	if _rectangular_selection_3d.has_method("_screen_rect_2d_to_topdown_polygon_2d"):
		polygon = _rectangular_selection_3d.call(
			"_screen_rect_2d_to_topdown_polygon_2d", screen_rect_2d
		)
	_on_selection_finished(polygon)
	_pending_screen_rect = null


## 【2026-09-29 用户要求"框选可以支持任何单位"】空中单位按**屏幕矩形**判定：
## 等距相机俯角下，悬停单位的"视线投影地面点"与玩家所见会错位（贴脸小框尤明显），
## 而玩家心智是"看到在框里就选中"。屏幕矩形包含判定与玩家所见完全一致。
## 相机不可用/矩形为空时返回空集，由 polygon 口径兜底（不漏也不误选）。
func _collect_air_units_within_screen_rect(screen_rect_2d):
	var result = Utils.Set.new()
	var camera = get_viewport().get_camera_3d()
	if camera == null or screen_rect_2d == null:
		return result
	for unit in get_tree().get_nodes_in_group("controlled_units"):
		if not is_instance_valid(unit) or not unit.visible:
			continue
		if not _is_air_domain(unit):
			continue
		var screen_position: Vector2 = camera.unproject_position(unit.global_position)
		if screen_rect_2d.has_point(screen_position):
			result.add(unit)
	return result


func _is_air_domain(unit) -> bool:
	var domain_value = unit.get("movement_domain")
	if domain_value == null:
		return false
	return int(domain_value) == Constants.Match.Navigation.Domain.AIR


## 拖动过程中的高亮：空中单位同样按屏幕矩形预览（多边形口径只服务地面单位）。
func _on_selection_changed_rect(screen_rect_2d):
	if screen_rect_2d == null:
		return
	var air = _collect_air_units_within_screen_rect(screen_rect_2d)
	var ground = Utils.Set.new()
	if _rectangular_selection_3d.has_method("_screen_rect_2d_to_topdown_polygon_2d"):
		var polygon = _rectangular_selection_3d.call(
			"_screen_rect_2d_to_topdown_polygon_2d", screen_rect_2d
		)
		ground = _get_controlled_units_from_navigation_domain_within_topdown_polygon_2d(
			Constants.Match.Navigation.Domain.TERRAIN, polygon
		)
	var units_to_highlight = Utils.Set.new()
	units_to_highlight.merge(ground)
	units_to_highlight.merge(air)
	var units_not_to_highlight_anymore = Utils.Set.subtracted(
		_highlighted_units, units_to_highlight
	)
	_force_highlight(units_to_highlight)
	_unforce_highlight(units_not_to_highlight_anymore)
	_highlighted_units = units_to_highlight
	_pending_screen_rect = screen_rect_2d
