extends Node

## 框选（拖拽选框）冒烟测试（2026-09-27 用户反馈"无人机无法框选中"）。
##
## 空中单位贴地飞行，而选框多边形是"屏幕像素 → 地表"的投影；两者不同坐标系时就会出现
## "明明框住了却选不中"。这里用与 RectangularSelection3D 完全相同的换算造选框多边形，
## 驱动 ArealUnitSelectionHandler 的结算，分别钉住两件事：
##   · 空军整批不参与框选（旧实现把多边形重投影到 y=40 的空域平面，射线恒为 null）；
##   · 俯角视差（紧贴飞机只框一小圈时，选框落到地面的位置与飞机 XZ 差出一大截，
##     拿 XZ 直接判定的实现会漏选）。

const MatchScene = preload("res://tests/manual/TestAllUnits.tscn")
const SmokeTestWarmup = preload("res://tests/automated/SmokeTestWarmup.gd")
const DroneScene = preload("res://source/match/units/Drone.tscn")
const TankScene = preload("res://source/match/units/Tank.tscn")

## 两个对照单位在世界里隔 30 米（落地后可能因导航微调而靠近些，但默认镜头下选框只有
## 16×22 米，仍盖不住另一个），保证"没框住就不该选中"的负对照有效。
const DRONE_HOME := Vector3(35, 0, 55)
const TANK_HOME := Vector3(65, 0, 55)

var _failures := 0
var _finished := false
var _match: Node = null
## 对局里的 IsometricCamera3D。刻意不标注 Camera3D：edge_scroll_enabled 与
## get_ray_intersection 都是它自定义的成员。
var _camera = null


func _ready():
	get_tree().create_timer(120.0).timeout.connect(_on_failsafe)
	_match = MatchScene.instantiate()
	add_child(_match)
	await get_tree().process_frame
	await SmokeTestWarmup.wait_for_units(get_tree(), 1, 2)

	_camera = get_viewport().get_camera_3d()
	_check(_camera != null, "对局应提供当前相机")
	if _camera == null:
		_finish()
		return
	# 无头环境里真实鼠标停在 (0,0)，会一直触发贴边滚动把镜头拖走，必须先关掉。
	_camera.edge_scroll_enabled = false

	var human = _match.get_node("Players/Human")
	var drone = _spawn(DroneScene, DRONE_HOME, human)
	var tank = _spawn(TankScene, TANK_HOME, human)
	# 空中高度由 Movement._snap_air_height 逐帧贴合地表，先等它抬起来。
	await get_tree().physics_frame
	await get_tree().physics_frame
	await get_tree().process_frame
	_check(
		drone.global_position.y > 0.5,
		"Drone 应已抬到离地高度（框选视差的前提），实际 y=%s" % drone.global_position.y
	)

	# 1) 框住无人机在屏幕上占据的位置 → 选中无人机，且不牵连远处的坦克。
	#    旧实现在这一步整批丢弃空军，坦克却照常选中，正是玩家看到的"框不住无人机"。
	_box_select(_screen_rect_around(drone, 24.0))
	await get_tree().process_frame
	_check(_is_selected(drone), "框住屏幕上的无人机应能选中它")
	_check(not _is_selected(tank), "选框没盖住坦克时不应选中它")

	# 2) 框住地面坦克 → 地面框选不能被这次改动破坏。
	_box_select(_screen_rect_around(tank, 24.0))
	await get_tree().process_frame
	_check(_is_selected(tank), "框住地面坦克仍应选中（地面框选回归）")
	_check(not _is_selected(drone), "选框没盖住无人机时不应选中无人机")

	# 3) 一个大框同时盖住两者 → 一起选中。
	_box_select(
		_screen_rect_around(drone, 24.0).expand(_camera.unproject_position(tank.global_position))
	)
	await get_tree().process_frame
	_check(_is_selected(drone) and _is_selected(tank), "大框应同时框住无人机与坦克")

	# 4) 紧贴屏幕上的无人机只框一小圈：选框投到地面上只有半张图那么深，装得下"无人机
	#    遮住的地面点"却装不下它的 XZ（45° 俯角 + 地形高差把两者拉开）。拿 XZ 直接判定
	#    的实现会在这里漏选，所以这条是视差换算的判别用例。
	_box_select(_screen_rect_around(drone, 12.0))
	await get_tree().process_frame
	_check(_is_selected(drone), "紧贴屏幕框住无人机（小选框）仍应选中")

	# 5) 拖拽过程中的高亮走同一套换算。
	var selector = _match.get_node("RectangularSelection3D")
	selector.started.emit()
	selector.changed.emit(_topdown_polygon_2d(_screen_rect_around(drone, 24.0)))
	await get_tree().process_frame
	_check(_is_highlighted(drone), "拖拽选框盖住无人机时应高亮它")
	selector.interrupted.emit()
	await get_tree().process_frame
	_check(not _is_highlighted(drone), "选框中断后应取消高亮")

	_finish()


func _spawn(scene, position: Vector3, player):
	var unit = scene.instantiate()
	_match.call("_setup_and_spawn_unit", unit, Transform3D(Basis.IDENTITY, position), player, false)
	return unit


## 走完一次完整的框选结算（started → finished，与 RectangularSelection3D 的信号时序一致）。
func _box_select(rect: Rect2):
	var selector = _match.get_node("RectangularSelection3D")
	var polygon = _topdown_polygon_2d(rect)
	print("[BOX] rect=", rect, " polygon=", str(polygon))
	selector.started.emit()
	selector.finished.emit(polygon)


func _screen_rect_around(world_unit, half_margin: float) -> Rect2:
	var center = _camera.unproject_position(world_unit.global_position)
	return Rect2(
		center - Vector2(half_margin, half_margin), Vector2(half_margin * 2, half_margin * 2)
	)


## 与 RectangularSelection3D._screen_rect_2d_to_topdown_polygon_2d 同口径：
## 屏幕四角沿视线打到地表，取水平面坐标。
func _topdown_polygon_2d(rect: Rect2) -> Array:
	var corners = [
		rect.position,
		Vector2(rect.position.x, rect.end.y),
		rect.end,
		Vector2(rect.end.x, rect.position.y),
	]
	var polygon = []
	for corner in corners:
		var ground_hit = _camera.get_ray_intersection(corner)
		if ground_hit == null:
			ground_hit = _camera.get_ray_intersection_with_plane(
				corner, Constants.Match.Terrain.PLANE
			)
		if ground_hit == null:
			return []
		polygon.append(Vector2(ground_hit.x, ground_hit.z))
	return polygon


func _is_selected(unit) -> bool:
	return unit.is_in_group("selected_units")


func _is_highlighted(unit) -> bool:
	var highlight = unit.find_child("Highlight")
	return highlight != null and highlight._forced


func _on_failsafe():
	if _finished:
		return
	_finished = true
	_failures += 1
	print("FAIL: 看门狗超时——测试协程中断未收尾")
	print("Air box selection smoke test completed: %d failure(s)" % _failures)
	SmokeTestExit.request(get_tree(), 1, _match)


func _finish():
	if _finished:
		return
	_finished = true
	print("Air box selection smoke test completed: %d failure(s)" % _failures)
	SmokeTestExit.request(get_tree(), 0 if _failures == 0 else 1, _match)


func _check(condition: bool, message: String):
	if condition:
		return
	_failures += 1
	print("FAIL: %s" % message)
	push_error("Air box selection smoke test assertion failed: %s" % message)
