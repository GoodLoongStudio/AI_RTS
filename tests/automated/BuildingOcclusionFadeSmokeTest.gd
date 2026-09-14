extends Node

const SmokeTestWarmup = preload("res://tests/automated/SmokeTestWarmup.gd")
const MatchScene = preload("res://tests/manual/TestOneUnit.tscn")

var _failures := 0


func _ready():
	var match_instance = MatchScene.instantiate()
	add_child(match_instance)
	# ⚠️ `Match._ready()` 是异步的：单位约 0.3 秒后才进 `units` 组。遮挡检测遍历的正是
	# `get_nodes_in_group("units")`，只等两帧时该组为空 ⇒ `_find_blocking_occluders()` 恒返回
	# 空字典 ⇒ 建筑永远不会被虚化（断言恒红）。
	await SmokeTestWarmup.wait_for_units(get_tree(), 1)

	var fade = match_instance.get_node("Handlers/BuildingOcclusionFade")
	var decorations = match_instance.get_node("Map/Decorations")
	var camera: Camera3D = match_instance.get_node("IsometricCamera3D")
	var tank = match_instance.get_node("Players/Human/Tank")
	var mid: Vector3 = camera.global_position.lerp(tank.global_position + Vector3(0, 0.7, 0), 0.4)
	var pillar := MeshInstance3D.new()
	var box := BoxMesh.new()
	# ⚠️ 柱高必须**由实际视线高度派生**，不能写死：镜头高度会随设置/版本变化，
	# 写死 12 米时一旦机位抬高，视线就从柱顶上方越过 ⇒ 遮挡检测恒判「没挡住」
	# （2026-09-15 实测：相机 y 从 19.7 抬到 25.0 后，40% 处视线高度 15.5 > 12）。
	# 这里让柱子从地面一直长到视线之上 6 米，机位再变也不会失效。
	var sight_y: float = mid.y
	var pillar_height: float = sight_y + 6.0
	box.size = Vector3(4, pillar_height, 4)
	pillar.mesh = box
	pillar.position = Vector3(mid.x, pillar_height * 0.5, mid.z)
	decorations.add_child(pillar)

	fade._refresh_occluders()
	fade._process(0.0)
	_check(pillar.material_override != null, "挡住单位的建筑应换成半透明材质")
	if pillar.material_override is StandardMaterial3D:
		_check(
			is_equal_approx(pillar.material_override.albedo_color.a, fade.FADE_ALBEDO_ALPHA),
			"挡住单位的建筑透明度应使用虚化值"
		)

	pillar.position = tank.global_position + Vector3(40, 6, 40)
	fade._refresh_occluders()
	fade._process(0.0)
	_check(pillar.material_override == null, "不再挡住单位的建筑应恢复实心材质")

	print("Building occlusion fade smoke test completed: %d failure(s)" % _failures)
	match_instance.queue_free()
	await get_tree().process_frame
	SmokeTestExit.request(get_tree(), 0 if _failures == 0 else 1)


func _check(condition: bool, message: String):
	if condition:
		return
	_failures += 1
	push_error("Building occlusion fade assertion failed: %s" % message)
