extends Node

const MatchScene = preload("res://tests/manual/TestOneUnit.tscn")

var _failures := 0


func _ready():
	var match_instance = MatchScene.instantiate()
	add_child(match_instance)
	await get_tree().process_frame
	await get_tree().process_frame

	var fade = match_instance.get_node("Handlers/BuildingOcclusionFade")
	var decorations = match_instance.get_node("Map/Decorations")
	var camera: Camera3D = match_instance.get_node("IsometricCamera3D")
	var tank = match_instance.get_node("Players/Human/Tank")
	var mid: Vector3 = camera.global_position.lerp(tank.global_position + Vector3(0, 0.7, 0), 0.4)
	var pillar := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(4, 12, 4)
	pillar.mesh = box
	pillar.position = Vector3(mid.x, 6, mid.z)
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
