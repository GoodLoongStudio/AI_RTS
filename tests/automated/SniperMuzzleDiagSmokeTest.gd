extends Node

const SmokeTestWarmup = preload("res://tests/automated/SmokeTestWarmup.gd")
const MatchScene = preload("res://tests/manual/TestOneUnit.tscn")
const SniperScene = preload("res://source/match/units/Sniper.tscn")


func _ready():
	var match_instance = MatchScene.instantiate()
	add_child(match_instance)
	await SmokeTestWarmup.wait_for_units(get_tree(), 1)
	await get_tree().create_timer(0.5).timeout
	var human = match_instance.get_node("Players/Human")
	var sniper = SniperScene.instantiate()
	sniper.name = "MuzzleDiagSniper"
	MatchSignals.setup_and_spawn_unit.emit(
		sniper, Transform3D(Basis.IDENTITY, Vector3.ZERO), human, false
	)
	await get_tree().physics_frame
	await get_tree().create_timer(0.4).timeout

	var marker = sniper.find_child("ProjectileOrigin", true, false) as Node3D
	var geometry = sniper.get_node("Geometry") as Node3D
	var inv = geometry.global_transform.affine_inverse()
	var marker_local = inv * marker.global_position
	print("[MZS] marker geometry-space=", marker_local)
	var driver = sniper.find_child("InfantryAnimationDriver", true, false)
	print("[MZS] driver=", driver)
	var rifle = sniper.find_child("Rifle", true, false)
	print("[MZS] rifle=", rifle)
	if rifle != null:
		var aabb = rifle.global_transform * rifle.get_aabb()
		var tip = inv * (aabb.position + Vector3(0, 0, aabb.size.z))
		print("[MZS] rifle aabb min-local=", inv * aabb.position, " max-local=", inv * (aabb.position + aabb.size))
	print("[MZS] done")
	SmokeTestExit.request(get_tree(), 0)
