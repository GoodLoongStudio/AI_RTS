extends Node

var _match: Node
var _out := ""
var _phase := "all"
var _failures := 0
var _rows: Array = []
var _started := 0

func _ready() -> void:
	_out = OS.get_environment("LAYOUT_OUT")
	_phase = OS.get_environment("LAYOUT_PHASE")
	if _phase.is_empty():
		_phase = "all"
	_started = Time.get_ticks_msec()
	get_tree().create_timer(195.0, true).timeout.connect(func(): get_tree().quit(3))
	_run.call_deferred()

func _run() -> void:
	await _boot()
	var player = _match.get_local_player()
	player.add_resources({"resource_a": 60000}, "ScriptedAdjustment")
	var cc = _units(player, "command_center")[0]
	var drone = _units(player, "drone")[0]
	var start: Vector3 = drone.global_position
	var receipt = player.get_node("UnitCommandGateway").MoveUnits([drone], start + Vector3(14, 0, 0), player)
	await get_tree().create_timer(4.0).timeout
	_check(receipt.get("status") == "Accepted" and drone.global_position.distance_to(start) > 3.0, "opening drone move")
	_rows.append({"phase":"opening_move", "displacement":drone.global_position.distance_to(start)})
	var runtime = _match.get_node("StructurePlacementRuntime")
	var server = get_node("/root/DebugControlServer")
	var scenes := ["OreRefinery", "VehicleFactory", "Barracks", "AircraftFactory"]
	for name_ in scenes:
		var before := _structures(player).size()
		var stamp := Time.get_ticks_usec()
		var reply: Dictionary = JSON.parse_string(server._op_build(_match, {
			"scene":"res://source/match/units/"+name_+".tscn", "auto":"base"}))
		_rows.append({"phase":"adjutant_build", "building":name_, "reply":reply,
			"elapsed_ms":(Time.get_ticks_usec()-stamp)/1000.0})
		_check(_structures(player).size() == before+1, "adjutant placed "+name_)
		await _wait_construction(player)
	var gap := INF
	var structures := _structures(player)
	for i in structures.size():
		for j in range(i+1, structures.size()):
			gap = minf(gap, _flat_distance(structures[i].global_position, structures[j].global_position)
				- float(structures[i].radius) - float(structures[j].radius))
	_rows.append({"phase":"layout", "minimum_gap_m":gap, "structures":_structure_rows(player)})
	if _phase != "baseline":
		_check(gap >= runtime.StructurePassGapMeters()-0.01, "all automatic buildings leave passage clearance")
	if DisplayServer.get_name() != "headless":
		var camera = _match.get_node("IsometricCamera3D")
		camera.set_process(false)
		camera.set_physics_process(false)
		camera.set("edge_scroll_enabled", false)
		camera.size = 90.0
		camera.set_position_safely(cc.global_position)
		await _shot("layout")
	# Production and movement are real public commands, not direct transforms.
	var factory = _units(player, "vehicle_factory")
	if not factory.is_empty():
		_check(factory[0].production_queue.produce(load("res://source/match/units/Tank.tscn")) != null, "tank production accepted")
		var deadline := Time.get_ticks_msec()+20000
		while _units(player, "tank").is_empty() and Time.get_ticks_msec() < deadline:
			await get_tree().create_timer(0.2).timeout
		var tanks := _units(player, "tank")
		_check(not tanks.is_empty(), "tank actually spawned")
		if not tanks.is_empty():
			var tank = tanks[0]
			var origin: Vector3 = tank.global_position
			var target: Vector3 = origin + Vector3(22,0,5)
			var moved = player.get_node("UnitCommandGateway").MoveUnits([tank],target,player)
			await get_tree().create_timer(9.0).timeout
			_rows.append({"phase":"tank_move", "receipt":moved.get("status"), "displacement":tank.global_position.distance_to(origin),
				"distance_to_target":_flat_distance(tank.global_position,target)})
			_check(moved.get("status") == "Accepted" and tank.global_position.distance_to(origin)>5, "produced tank moved")
	# Same type/work, tested sequentially to respect one active site per player.
	var durations: Array = []
	for offset in [Vector3(0,0,23), Vector3(105,0,0)]:
		var proto = load("res://source/match/units/CommandCenter.tscn")
		var found = runtime.FindAutoSpot(player,proto,"hint",cc.global_position+offset,18.0)
		_check(found.get("found",false), "remote CC legal site")
		if not found.get("found",false):
			continue
		var placed = runtime.Place(player,proto,Transform3D(Basis.IDENTITY,found["pos"]),{})
		_check(placed.get("accepted",false), "CC placed")
		if not placed.get("accepted",false):
			continue
		var site = placed["structure"]
		var tick_start := Engine.get_physics_frames()
		await _wait_construction(player)
		var frames := Engine.get_physics_frames()-tick_start
		durations.append(frames)
		_rows.append({"phase":"cc_construction", "distance_m":_flat_distance(cc.global_position,site.global_position),"physics_ticks":frames,
			"complete":site.is_constructed(),"pos":str(site.global_position)})
	if _phase in ["remote", "all"] and durations.size()==2:
		# The first extra completed CC supplies the existing 1.5x construction bonus.
		_check(durations[1] > durations[0]*2.0, "far construction actually slower despite extra CC bonus")
	await _cleanup()
	await _boot()
	_rows.append({"phase":"reopen", "entities":get_tree().get_nodes_in_group("units").size()})
	await _cleanup()
	var payload := {"phase":_phase,"pid":OS.get_process_id(),"project":ProjectSettings.globalize_path("res://"),
		"wall_seconds":(Time.get_ticks_msec()-_started)/1000.0,"failures":_failures,"rows":_rows,"match_cleanup":not is_instance_valid(_match)}
	if not _out.is_empty():
		var f := FileAccess.open(_out.path_join("result.json"), FileAccess.WRITE)
		f.store_string(JSON.stringify(payload,"\t"))
	print("AI_LAYOUT_RESULT ",JSON.stringify(payload))
	print("AI building layout probe completed: ",_failures," failure(s)")
	SmokeTestExit.request(get_tree(),0 if _failures==0 else 1)

func _boot() -> void:
	var settings = load("res://source/data-model/MatchSettings.gd").new()
	var player = load("res://source/data-model/PlayerSettings.gd").new()
	player.controller = Constants.PlayerType.HUMAN
	player.color = Constants.Player.COLORS[0]
	settings.players.append(player)
	settings.visible_player=0
	_match=load("res://source/match/Match.tscn").instantiate()
	_match.settings=settings
	_match.map=load("res://source/match/maps/PlainAndSimple.tscn").instantiate()
	get_tree().root.add_child(_match)
	get_tree().current_scene=_match
	await get_tree().create_timer(2.5).timeout
	_check(get_tree().get_nodes_in_group("units").size()==2,"normal opening CC and drone")

func _wait_construction(player) -> void:
	# Distance penalty now works: 100 work at 0.2/tick requires 500 ticks.
	# This large-map runtime uses fewer physics ticks per wall second, so the
	# prior 20s wall watchdog expired at tick 401 before legitimate completion.
	var deadline := Time.get_ticks_msec()+50000
	while _match.get_node("StructurePlacementRuntime").HasActiveConstructionSite(player) and Time.get_ticks_msec()<deadline:
		await get_tree().physics_frame
	_check(not _match.get_node("StructurePlacementRuntime").HasActiveConstructionSite(player),"construction completed")

func _structures(player) -> Array:
	return get_tree().get_nodes_in_group("units").filter(func(u):return u.get_parent()==player and u.find_child("MovementObstacle",false,false)!=null and u.find_child("Movement",false,false)==null)

func _units(player, type_id: String) -> Array:
	return get_tree().get_nodes_in_group("units").filter(func(u):return u.get_parent()==player and u.get("unit_type_id")==type_id)

func _structure_rows(player) -> Array:
	var rows: Array=[]
	for u in _structures(player):
		rows.append({"type":u.unit_type_id,"x":u.global_position.x,"z":u.global_position.z,"radius":u.radius})
	return rows

func _flat_distance(a: Vector3,b: Vector3) -> float:
	return Vector2(a.x-b.x,a.z-b.z).length()

func _shot(label: String) -> void:
	await RenderingServer.frame_post_draw
	if not _out.is_empty():
		get_viewport().get_texture().get_image().save_png(_out.path_join(label+".png"))

func _cleanup() -> void:
	# Follow normal leave-match semantics; deleting units individually while AI
	# timers run can trigger the defeat pause or commands to released actions.
	MatchSignals.match_aborted.emit()
	get_tree().paused=true
	_match.queue_free()
	get_tree().current_scene=null
	await get_tree().process_frame
	await get_tree().process_frame
	get_tree().paused=false
	_check(get_tree().get_nodes_in_group("units").is_empty(),"normal teardown removes units")
	await get_tree().create_timer(0.1,true).timeout

func _check(ok: bool,label: String) -> void:
	if not ok:
		_failures+=1
		push_error("AI_LAYOUT_FAIL "+label)
