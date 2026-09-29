extends Node3D

@export var rectangular_selection_3d: NodePath

var _rectangular_selection_3d = null
var _highlighted_units = Utils.Set.new()


func _ready():
	_rectangular_selection_3d = get_node_or_null(rectangular_selection_3d)
	if _rectangular_selection_3d == null:
		return
	_rectangular_selection_3d.started.connect(_on_selection_started)
	_rectangular_selection_3d.interrupted.connect(_on_selection_interrupted)
	_rectangular_selection_3d.finished.connect(_on_selection_finished)


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
		if not unit.visible or unit.movement_domain != navigation_domain:
			continue
		var unit_position_2d = Vector2(unit.transform.origin.x, unit.transform.origin.z)
		if navigation_domain == Constants.Match.Navigation.Domain.AIR:
			unit_position_2d = _air_unit_topdown_position_2d(unit, camera, unit_position_2d)
		if Geometry2D.is_point_in_polygon(unit_position_2d, topdown_polygon_2d):
			units_within_polygon.add(unit)
	return units_within_polygon


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
	_unforce_highlight(_highlighted_units)
	_highlighted_units = Utils.Set.new()


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
	Utils.Match.select_units(units_to_select)
