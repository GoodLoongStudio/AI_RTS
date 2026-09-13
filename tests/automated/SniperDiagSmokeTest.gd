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
	sniper.name = "DiagSniper"
	MatchSignals.setup_and_spawn_unit.emit(
		sniper, Transform3D(Basis.IDENTITY, Vector3.ZERO), human, false
	)
	await get_tree().physics_frame
	await get_tree().create_timer(0.3).timeout

	var glb = sniper.find_child("Infantry_native_v3", true, false)
	print("[DIAG] GLB_ROOT=", glb)
	if glb != null:
		for c in glb.get_children():
			print("[DIAG]   child=", c.name, " class=", c.get_class())
		var baked = glb.find_child("Rifle", true, false)
		print("[DIAG] BAKED_RIFLE=", baked, " visible=", baked.visible if baked else "n/a")
		var skel = glb.find_child("InfantrySkeleton", true, false)
		print("[DIAG] SKEL=", skel, " class=", skel.get_class() if skel else "none")
		if skel is Skeleton3D:
			print("[DIAG]   bone_count=", skel.get_bone_count(), " Hand_R=", skel.find_bone("Hand_R"))
	var attach = sniper.find_child("HandWeaponAttachment", true, false)
	print("[DIAG] ATTACH=", attach)
	if attach != null:
		print("[DIAG]   children=", attach.get_child_count())
		for c in attach.get_children():
			var aabb_text := "n/a"
			if c is Node3D:
				var aabb: AABB = c.get_aabb()
				aabb_text = str(aabb)
			print("[DIAG]   weapon=", c.name, " class=", c.get_class(), " aabb=", aabb_text)
	print("[DIAG] done")
	SmokeTestExit.request(get_tree(), 0)
