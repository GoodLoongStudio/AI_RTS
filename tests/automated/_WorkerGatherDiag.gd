extends Node

## worker-gather 回归诊断：TestAllUnits 里矿车出生在主基地 carve 洞内，紧挨 ResourceB5。
## AIRTS_WG_VARIANT：default / margin0 / nobounds / nopass / noapproach / legacy（前四项全关）。
## 打印取得第一份载荷耗时与每 0.25s 的位置、动作、离主基地中心距离。

const SmokeTestWarmup = preload("res://tests/automated/SmokeTestWarmup.gd")
const MatchScene = preload("res://tests/manual/TestAllUnits.tscn")
const MovementScript = preload("res://source/match/units/traits/Movement.gd")
const MovementUtils = preload("res://source/match/utils/UnitMovementUtils.gd")


func _ready():
	var variant := OS.get_environment("AIRTS_WG_VARIANT").strip_edges()
	if variant.is_empty():
		variant = "default"
	var legacy := variant == "legacy" or variant == "rvo"
	var match_instance = MatchScene.instantiate()
	for obstacle in match_instance.find_children("MovementObstacle", "", true, false):
		if legacy or variant == "margin0":
			obstacle.set("carve_margin_m", 0.0)
		if legacy or variant == "nobounds":
			obstacle.set("carve_from_collision_bounds", false)
	MovementScript.structure_pass_enabled = not (legacy or variant == "nopass")
	MovementUtils.structure_approach_enabled = not (legacy or variant == "noapproach")
	add_child(match_instance)
	await SmokeTestWarmup.wait_for_units(get_tree(), 1)
	if variant == "rvo" or variant == "rvoonly":
		for obstacle in match_instance.find_children("MovementObstacle", "", true, false):
			if bool(obstacle.get("affect_navigation_mesh")):
				obstacle.set("avoidance_enabled", true)
	var human = match_instance.get_node("Players/Human")
	var worker: Node3D = human.get_node("Worker")
	var cc: Node3D = human.get_node("CommandCenter")
	var resource = match_instance.get_node("Map/Resources/ResourceB5")
	var obstacle = cc.find_child("MovementObstacle", true, false)
	print("[WG] variant=%s worker_cc=%.2f res_cc=%.2f cc_r=%.2f carve_max=%.2f res_r=%.2f" % [
		variant, _planar(worker, cc), _planar(resource, cc), float(cc.get("radius")),
		float(obstacle.call("carve_extent_max")), float(resource.get("radius"))])
	human.get_node("UnitCommandGateway").GatherResources([worker], resource, human)
	var elapsed := 0.0
	var got := -1.0
	while elapsed < 8.0:
		if got < 0.0 and int(worker.resource_b) >= 1:
			got = elapsed
			break
		if int(elapsed * 100.0) % 25 == 0:
			var action_name := "null" if worker.action == null else str(worker.action.get_script().resource_path.get_file())
			var sub = worker.action.get("_sub_action") if worker.action != null else null
			var sub_name := "-" if sub == null else str(sub.get_script().resource_path.get_file())
			var facing = sub.call("_is_facing_resource") if sub != null and sub.has_method("_is_facing_resource") else null
			var movement = worker.find_child("Movement")
			print("[WG] t=%.2f pos=(%.2f,%.2f) d_cc=%.2f d_res=%.2f action=%s sub=%s facing=%s res_b=%s face_target=%s yaw=%.1f vel=%s committed=%s nav_target=%s" % [
				elapsed, worker.global_position.x, worker.global_position.z,
				_planar(worker, cc), _planar(worker, resource), action_name, sub_name,
				str(facing), str(resource.get("resource_b")), str(movement.get("_face_target")),
				rad_to_deg(worker.global_rotation.y), str(movement.get("velocity")),
				str(movement.get("_committed_target")), str(movement.get("target_position"))])
		await get_tree().create_timer(0.05).timeout
		elapsed += 0.05
	print("[WG] RESULT variant=%s first_cargo_s=%.2f" % [variant, got])
	match_instance.queue_free()
	await get_tree().process_frame
	get_tree().quit(0)


func _planar(a: Node3D, b: Node3D) -> float:
	return Vector2(a.global_position.x - b.global_position.x, a.global_position.z - b.global_position.z).length()
