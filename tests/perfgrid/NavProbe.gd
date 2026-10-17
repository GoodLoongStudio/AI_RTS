extends Node

## 临时探针：PlainAndSimple 上量化导航网格覆盖（多边形数 + 采样点可达率）。

const MatchScene = preload("res://tests/manual/TestOneUnit.tscn")
const SmokeTestWarmup = preload("res://tests/automated/SmokeTestWarmup.gd")

const SAMPLE_POINTS := [
	Vector3(8, 0, 6), Vector3(27, 0, 6), Vector3(40, 0, 40), Vector3(60, 0, 60),
	Vector3(80, 0, 80), Vector3(100, 0, 100), Vector3(120, 0, 120), Vector3(150, 0, 150),
	Vector3(20, 0, 180), Vector3(180, 0, 20), Vector3(24, 0, 24), Vector3(102, 0, 108),
]


func _ready():
	var match_instance = MatchScene.instantiate()
	add_child(match_instance)
	await SmokeTestWarmup.wait_for_units(get_tree(), 1)
	var tank = match_instance.get_node("Players/Human/Tank")
	var movement = tank.find_child("Movement")
	await SmokeTestWarmup.wait_for_navigation(get_tree(), movement, tank.global_position)
	var reachable := 0
	for point in SAMPLE_POINTS:
		var ok: bool = false
		if movement.has_method("is_target_reachable"):
			ok = movement.is_target_reachable(point)
		else:
			ok = movement.is_target_reachable.call(point)
		print("[NAVPROBE] %s reachable=%s" % [point, str(ok)])
		if ok:
			reachable += 1
	print("[NAVPROBE] summary %d/%d reachable, map_size=%s" % [
		reachable, SAMPLE_POINTS.size(), str(match_instance.map.size)])
	get_tree().quit(0)
