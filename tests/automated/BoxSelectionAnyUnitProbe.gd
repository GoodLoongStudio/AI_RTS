extends Node

## 框选"任何单位"回归探针（2026-09-29 用户要求）。
## 真实运行序列：RectangularSelection3D._finish() 会**同时**发 finished(polygon)
## 与 finished_rect(screen_rect)。这里照此序列驱动，钉住三件事：
##   ① 空中单位按屏幕矩形口径必中（贴脸小框，投影口径会漏的场景）；
##   ② 地面单位仍按多边形口径命中（不被屏幕矩形改动破坏）；
##   ③ movement_domain 读不到的单位现在也能框选（旧实现两次扫描都跳过它）。

const MatchScene = preload("res://tests/manual/TestAllUnits.tscn")
const SmokeTestWarmup = preload("res://tests/automated/SmokeTestWarmup.gd")
const DroneScene = preload("res://source/match/units/Drone.tscn")
const TankScene = preload("res://source/match/units/Tank.tscn")
const WorkerScene = preload("res://source/match/units/Worker.tscn")

const DRONE_HOME := Vector3(35, 0, 55)
const TANK_HOME := Vector3(65, 0, 55)

var _failures := 0
var _finished := false
var _match: Node = null
var _camera = null


func _check(cond: bool, msg: String) -> void:
	if cond:
		print("[PASS] " + msg)
	else:
		_failures += 1
		print("[FAIL] " + msg)


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
	if "edge_scroll_enabled" in _camera:
		_camera.edge_scroll_enabled = false

	var human = _match.get_node("Players/Human")
	var drone = _spawn(DroneScene, DRONE_HOME, human)
	var tank = _spawn(TankScene, TANK_HOME, human)
	# ③ 一个域读不到的单位：Worker 去掉 Movement 子节点后 movement_domain 返回 null
	var orphan = WorkerScene.instantiate()
	_match.call("_setup_and_spawn_unit", orphan, Transform3D(Basis.IDENTITY, Vector3(45, 0, 60)), human, false)
	var movement = orphan.find_child("Movement", false, false)
	if movement != null:
		movement.queue_free()
	await get_tree().physics_frame
	await get_tree().physics_frame
	await get_tree().process_frame
	_check(drone.get("movement_domain") == Constants.Match.Navigation.Domain.AIR, "Drone 是空中单位")
	_check(orphan.get("movement_domain") == null, "orphan 读不到域（构造的漏网场景）")

	# ① 只框无人机屏幕位置（±12px 贴脸小框）：屏幕矩形口径必须命中
	_box_select(_screen_rect_around(drone, 12.0))
	await get_tree().process_frame
	_check(_is_selected(drone), "贴脸小框也应选中空中单位（屏幕矩形口径）")
	_check(not _is_selected(tank), "选框没盖住坦克时不应选中它")
	_check(not _is_selected(orphan), "选框没盖住读不到域的单位时不应选中它")

	# ② 地面单位命中
	_box_select(_screen_rect_around(tank, 12.0))
	await get_tree().process_frame
	_check(_is_selected(tank), "框住地面单位仍应选中（地面回归）")
	_check(not _is_selected(drone), "选框没盖住无人机时不应选中它")

	# ③ 域读不到的单位：框住它应该能选中（旧实现永远漏它）
	_box_select(_screen_rect_around(orphan, 12.0))
	await get_tree().process_frame
	_check(_is_selected(orphan), "读不到域的单位也应能框选（旧实现必漏）")

	# 大框全中
	_box_select(_big_rect([_screen_rect_around(drone, 12.0), _screen_rect_around(tank, 12.0), _screen_rect_around(orphan, 12.0)]))
	await get_tree().process_frame
	_check(_is_selected(drone) and _is_selected(tank) and _is_selected(orphan), "大框应同时框住空/地/无域单位")

	_finish()


func _spawn(scene, position: Vector3, player):
	var unit = scene.instantiate()
	_match.call("_setup_and_spawn_unit", unit, Transform3D(Basis.IDENTITY, position), player, false)
	return unit


## 走真实运行的双信号序列：finished(polygon) + finished_rect(rect)。
func _box_select(rect: Rect2):
	var selector = _match.get_node("RectangularSelection3D")
	selector.started.emit()
	if selector.has_signal("changed_rect"):
		selector.changed_rect.emit(rect)
	selector.finished.emit(_topdown_polygon_2d(rect))
	if selector.has_signal("finished_rect"):
		selector.finished_rect.emit(rect)


func _big_rect(rects: Array) -> Rect2:
	var out := Rect2(rects[0])
	for r in rects:
		out = out.merge(r)
	return out


func _topdown_polygon_2d(rect: Rect2) -> Array:
	var pts := []
	for corner in [rect.position, Vector2(rect.position.x, rect.end.y), rect.end, Vector2(rect.end.x, rect.position.y)]:
		var hit = _camera.get_ray_intersection(corner)
		if hit == null:
			hit = _camera.get_ray_intersection_with_plane(corner, Plane(Vector3.UP, 0))
		pts.append(Vector2(hit.x, hit.z) if hit != null else Vector2.ZERO)
	return pts


func _screen_rect_around(unit: Node3D, margin: float) -> Rect2:
	var center: Vector2 = _camera.unproject_position(unit.global_position)
	return Rect2(center - Vector2(margin, margin), Vector2(margin * 2.0, margin * 2.0))


func _is_selected(unit) -> bool:
	var sel = unit.find_child("Selection")
	return sel != null and bool(sel.get("_selected"))


func _is_highlighted(unit) -> bool:
	var sel = unit.find_child("Selection")
	return sel != null and bool(sel.get("_highlighted"))


func _on_failsafe():
	if _finished:
		return
	print("FAIL: 看门狗超时")
	_finish()


func _finish():
	if _finished:
		return
	_finished = true
	print("Box selection any-unit probe: %d failure(s)" % _failures)
	SmokeTestExit.request(get_tree(), 0 if _failures == 0 else 1, _match)
