extends Node

const SmokeTestWarmup = preload("res://tests/automated/SmokeTestWarmup.gd")
const MatchScene = preload("res://tests/manual/TestOneUnit.tscn")
const TankScene = preload("res://source/match/units/Tank.tscn")


func _ready():
	var match_instance = MatchScene.instantiate()
	add_child(match_instance)
	await SmokeTestWarmup.wait_for_units(get_tree(), 1)
	await get_tree().create_timer(0.5).timeout
	var human = match_instance.get_node("Players/Human")
	var tank = TankScene.instantiate()
	tank.name = "MuzzleDiagTank"
	MatchSignals.setup_and_spawn_unit.emit(
		tank, Transform3D(Basis.IDENTITY, Vector3.ZERO), human, false
	)
	await get_tree().physics_frame
	await get_tree().create_timer(0.3).timeout

	var geometry := tank.get_node("Geometry") as Node3D
	var inv := geometry.global_transform.affine_inverse()
	for node in tank.find_children("*Barrel*", "MeshInstance3D", true, false):
		var mesh := node as MeshInstance3D
		var aabb := mesh.global_transform * mesh.get_aabb()
		var tip_front := Vector3(INF, INF, INF)
		var tip_back := Vector3(-INF, -INF, -INF)
		for i in 8:
			var c := inv * aabb.get_endpoint(i)
			tip_front = Vector3(min(tip_front.x, c.x), min(tip_front.y, c.y), min(tip_front.z, c.z))
			tip_back = Vector3(max(tip_back.x, c.x), max(tip_back.y, c.y), max(tip_back.z, c.z))
		print("[MUZZLE] barrel=", node.name)
		print("[MUZZLE] geometry-space front-most=", tip_front, " back-most=", tip_back)
	var marker := tank.get_node("Geometry/ProjectileOrigin") as Node3D
	print("[MUZZLE] current marker=", marker.position)
	print("[MUZZLE] done")
	SmokeTestExit.request(get_tree(), 0)
