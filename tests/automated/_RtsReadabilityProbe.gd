extends Node

const MatchSettings = preload("res://source/data-model/MatchSettings.gd")
const ROSTER := [
	"CommandCenter", "VehicleFactory", "Barracks", "OreRefinery", "AircraftFactory",
	"AntiGroundTurret", "AntiAirTurret", "MachineGunTurret", "Tank", "HeavyTank",
	"APC", "TransportTruck", "Worker", "Helicopter", "Drone",
	"Infantry", "Rocketeer", "Sniper",
]
var _failures := 0
var _out := ""
var _produced: Node3D = null
var _check_results: Array = []


func _ready() -> void:
	await get_tree().process_frame
	_out = OS.get_environment("AIRTS_READABILITY_OUT")
	if _out.is_empty() or not _out.is_absolute_path():
		push_error("AIRTS_READABILITY_OUT must be a fresh absolute evidence directory")
		get_tree().quit(2)
		return
	DirAccess.make_dir_recursive_absolute(_out)
	var started := Time.get_ticks_msec()
	var m: Node = await _new_match()
	var player: Node = m.get_node("Players").get_child(0)
	var balance: Node = m.get_node("BalanceConfigRuntime")
	_check(balance.IsHealthy(), "retired roster catalog and asset manifest are healthy")
	_check(balance.GetUnitTypeId(load("res://source/match/units/Scout.tscn")) == "",
		"retired Scout scene has no registered unit type")
	_check(balance.GetUnitTypeId(load("res://source/match/units/Drone.tscn")) == "drone",
		"current Drone scene remains registered")
	var camera: Camera3D = m.get_node("IsometricCamera3D")
	camera.set_process(false)
	camera.set_process_input(false)
	camera.set_process_unhandled_input(false)
	var report := {"unix_time": Time.get_unix_time_from_system(), "pid": OS.get_process_id(),
		"project": ProjectSettings.globalize_path("res://"), "entities": {}, "checks": {}}
	report["opening_camera"] = {"size": camera.size, "height": camera.position.y}
	await _shot("opening")
	var units := {}
	for index in ROSTER.size():
		var name: String = ROSTER[index]
		var unit: Node3D = load("res://source/match/units/%s.tscn" % name).instantiate()
		var point := Vector3(80.0 + float(index % 5) * 12.0, 0.0,
			80.0 + float(index / 5) * 12.0)
		m.call("_setup_and_spawn_unit", unit, Transform3D(Basis.IDENTITY, point), player, false)
		units[name] = unit
		var label := Label3D.new()
		label.text = name
		label.font_size = 36
		label.pixel_size = 0.008
		label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		label.no_depth_test = true
		unit.add_child(label)
		label.position = Vector3(0.0, 0.3, 4.0)
	for frame in 90:
		await get_tree().physics_frame
	for name in units:
		var unit: Node3D = units[name]
		report.entities[name] = _measure(unit)
		_check(unit.scale.is_equal_approx(Vector3.ONE), name + " root scale is one")
	var main_size: Array = report.entities["CommandCenter"]["resource_bounds_size"]
	var main_area := float(main_size[0]) * float(main_size[2])
	var main_volume := main_area * float(main_size[1])
	for name in ROSTER.slice(1, 8):
		var other: Array = report.entities[name]["resource_bounds_size"]
		var area := float(other[0]) * float(other[2])
		_check(float(main_size[0]) > float(other[0]) and float(main_size[2]) > float(other[2]),
			"main base wider and longer than " + name)
		_check(main_area > area and main_volume > area * float(other[1]),
			"main base has greater ground area and bounding volume than " + name)
	# Run the unchanged geometric assertions on initialized units, not orphan fixtures.
	var coverage: Node = load("res://tests/automated/UnitRadiusCoverageSmokeTest.gd").new()
	for name in units:
		coverage.call("_check_unit", name, units[name])
	var coverage_failures := int(coverage.get("_failures"))
	_check(coverage_failures == 0, "all current roster coverage contracts in real Match")
	report.checks["radius_coverage_failures"] = coverage_failures
	coverage.free()
	# Remove HUD only in the diagnostic lineup, not the actual opening screenshot.
	for node in m.find_children("*", "CanvasLayer", true, false):
		node.hide()
	camera.call("force_opening_isometric")
	camera.call("set_position_safely", Vector3(104.0, 0.0, 100.0))
	await _shot("lineup")
	var tank: Node3D = units["Tank"]
	var begin := tank.global_position
	var destination := begin + Vector3(4.0, 0.0, 4.0)
	var result: Dictionary = player.get_node("UnitCommandGateway").MoveUnits([tank], destination, player)
	_check(str(result.get("status", "")) == "Accepted", "move command accepted")
	var deadline := Time.get_ticks_msec() + 20000
	while Time.get_ticks_msec() < deadline:
		await get_tree().physics_frame
		if Vector2(tank.position.x - destination.x, tank.position.z - destination.z).length() < 0.6:
			break
	var travel := Vector2(tank.position.x - begin.x, tank.position.z - begin.z).length()
	var remaining := Vector2(tank.position.x - destination.x, tank.position.z - destination.z).length()
	_check(travel > 3.0 and remaining < 0.6, "tank actually moves and arrives")
	report.checks["movement"] = {"result": result, "travel_m": travel, "remaining_m": remaining}
	var factory: Node3D = units["VehicleFactory"]
	var produced_callback := func(unit: Node3D, producer: Node):
		if producer == factory:
			_produced = unit
	MatchSignals.unit_production_finished.connect(produced_callback)
	var queue: Node = factory.get_node("ProductionQueue")
	_check(queue.produce(load("res://source/match/units/Tank.tscn")) != null, "normal factory production queued")
	deadline = Time.get_ticks_msec() + 25000
	while _produced == null and Time.get_ticks_msec() < deadline:
		await get_tree().physics_frame
	_check(_produced != null, "normal factory actually deploys a tank")
	if _produced != null:
		var from_factory: Vector3 = _produced.position - factory.position
		var spawn_distance := Vector2(from_factory.x, from_factory.z).length()
		var minimum := float(factory.get("radius")) + float(_produced.get("radius")) + 0.1
		_check(spawn_distance > minimum, "produced tank clears the enlarged factory")
		_check(_produced.scale.is_equal_approx(Vector3.ONE), "produced tank root scale is one")
		report.checks["production"] = {"spawn_distance_m": spawn_distance, "minimum_m": minimum,
			"root_scale": _v(_produced.scale)}
	MatchSignals.unit_production_finished.disconnect(produced_callback)
	_produced = null
	var airport: Node3D = units["AircraftFactory"]
	var drone_callback := func(unit: Node3D, producer: Node):
		if producer == airport:
			_produced = unit
	MatchSignals.unit_production_finished.connect(drone_callback)
	var air_queue: Node = airport.get_node("ProductionQueue")
	_check(air_queue.produce(load("res://source/match/units/Scout.tscn")) == null,
		"airport rejects retired Scout production")
	_check(air_queue.produce(load("res://source/match/units/Drone.tscn")) != null,
		"airport accepts current Drone production")
	deadline = Time.get_ticks_msec() + 20000
	while _produced == null and Time.get_ticks_msec() < deadline:
		await get_tree().physics_frame
	_check(_produced != null and _produced.scene_file_path.ends_with("/Drone.tscn"),
		"airport actually deploys current Drone")
	MatchSignals.unit_production_finished.disconnect(drone_callback)
	_produced = null
	m.queue_free()
	for frame in 12:
		await get_tree().physics_frame
	_check(not is_instance_valid(m), "first match freed")
	var restarted: Node = await _new_match()
	_check(restarted.get_node("Players").get_child_count() == 1, "fresh match reopens")
	restarted.queue_free()
	for frame in 12:
		await get_tree().physics_frame
	_check(not is_instance_valid(restarted), "reopened match freed")
	report["failures"] = _failures
	report["assertions"] = _check_results
	report["wall_seconds"] = float(Time.get_ticks_msec() - started) / 1000.0
	var file := FileAccess.open(_out.path_join("measurements.json"), FileAccess.WRITE)
	file.store_string(JSON.stringify(report, "\t"))
	file.close()
	print("RTS readability probe completed: %d failure(s)" % _failures)
	SmokeTestExit.request(get_tree(), 0 if _failures == 0 else 1)


func _new_match() -> Node:
	var settings = MatchSettings.new()
	var human = load("res://source/data-model/PlayerSettings.gd").new()
	human.controller = Constants.PlayerType.HUMAN
	human.color = Constants.Player.COLORS[0]
	settings.players.append(human)
	settings.visible_player = 0
	settings.visibility = MatchSettings.Visibility.FULL
	var m: Node = load("res://source/match/Match.tscn").instantiate()
	m.settings = settings
	m.map = load("res://source/match/maps/PlainAndSimple.tscn").instantiate()
	get_tree().root.add_child(m)
	get_tree().current_scene = m
	var deadline := Time.get_ticks_msec() + 45000
	while Time.get_ticks_msec() < deadline:
		await get_tree().physics_frame
		var players: Node = m.get_node_or_null("Players")
		if players == null or players.get_child_count() != 1:
			continue
		var rid: RID = m.navigation.get_navigation_map_rid_by_domain(
			Constants.Match.Navigation.Domain.TERRAIN)
		if NavigationServer3D.map_get_closest_point_owner(rid, Vector3(104, 0, 104)).is_valid():
			for frame in 30:
				await get_tree().physics_frame
			return m
	_check(false, "match ready before watchdog")
	return m


func _measure(unit: Node3D) -> Dictionary:
	var geometry: Node3D = unit.find_child("Geometry", true, false)
	var collision: CollisionShape3D = unit.get_node("CollisionShape3D")
	var shape: Shape3D = collision.shape
	var dimensions := {}
	if shape is BoxShape3D:
		dimensions = {"type": "box", "size": _v(shape.size)}
	elif shape is CylinderShape3D or shape is CapsuleShape3D:
		dimensions = {"type": shape.get_class(), "radius": shape.radius, "height": shape.height}
	var box := AABB()
	var first := true
	var skinned := false
	for node in geometry.find_children("*", "MeshInstance3D", true, false):
		var mesh_node := node as MeshInstance3D
		if mesh_node.mesh == null:
			continue
		skinned = skinned or mesh_node.skin != null
		var local_box: AABB = unit.global_transform.affine_inverse() * mesh_node.global_transform * mesh_node.mesh.get_aabb()
		box = local_box if first else box.merge(local_box)
		first = false
	var obstacle: Node = unit.get_node_or_null("MovementObstacle")
	var data := {"root_scale": _v(unit.scale), "geometry_scale": _v(geometry.scale),
		"resource_bounds_size": _v(box.size), "bounds_kind": "skinned-resource-not-animated-envelope" if skinned else "mesh-resource-aabb",
		"collision": dimensions, "collision_center": _v(collision.position),
		"logical_radius": unit.get("radius"), "position": _v(unit.position),
		"selection_radius": unit.get_node("Selection").get("radius")}
	if obstacle != null:
		data["carve_vertices"] = Array(obstacle.vertices).map(func(v: Vector3): return _v(v))
	return data


func _v(value: Vector3) -> Array:
	return [value.x, value.y, value.z]


func _shot(name: String) -> void:
	if DisplayServer.get_name() == "headless":
		return
	var rc := ERR_UNAVAILABLE
	for attempt in 5:
		for frame in 15:
			await get_tree().process_frame
		await RenderingServer.frame_post_draw
		var snapshot := get_viewport().get_texture().get_image()
		if snapshot != null and not snapshot.is_empty():
			rc = snapshot.save_png(_out.path_join(name + ".png"))
			if rc == OK:
				break
	_check(rc == OK, "saved " + name + " screenshot (rc=%d)" % rc)


func _check(condition: bool, message: String) -> void:
	_check_results.append({"passed": condition, "message": message})
	if not condition:
		_failures += 1
	print("[READABILITY] %s %s" % ["PASS" if condition else "FAIL", message])
