extends "res://tests/automated/AiBuildingLayoutSmokeTest.gd"

var _last_worker_trace := -1

func _process(_delta: float) -> void:
	if not is_instance_valid(_match) or not _match.is_inside_tree():
		return
	var second := int((Time.get_ticks_msec()-_started)/1000)
	if second == _last_worker_trace:
		return
	_last_worker_trace = second
	var player = _match.get_local_player()
	if player == null:
		return
	var workers: Array = []
	for worker in _units(player,"worker"):
		var chain: Array = []
		var action = worker.action
		for depth in range(4):
			if action == null or not is_instance_valid(action): break
			var path := str(action.get_script().resource_path)
			var item := {"script":path}
			if path.ends_with("CollectingResourcesSequentially.gd"):
				item["state"] = action.get("_state")
				for key in ["_resource_unit","_cc_unit"]:
					var target = action.get(key)
					if is_instance_valid(target):item[key]=str(target.name)
			chain.append(item)
			if path.ends_with("AutoGatheringResources.gd") or path.ends_with("CollectingResourcesSequentially.gd"):
				action = action.get("_sub_action")
			else: break
		var movement = worker.find_child("Movement",false,false)
		workers.append({"name":str(worker.name),"position":str(worker.global_position),"cargo":worker.resource_a,
			"action":chain,"goal":str(movement.get("target_position")) if movement else "unknown"})
	var refineries: Array = []
	for refinery in _units(player,"ore_refinery"):
		refineries.append({"name":str(refinery.name),"deliveries":refinery.delivered_count,"amount":refinery.delivered_amount})
	var trace_path := _out.path_join("worker-trace.jsonl")
	var file = FileAccess.open(trace_path,FileAccess.READ_WRITE if FileAccess.file_exists(trace_path) else FileAccess.WRITE)
	file.seek_end()
	file.store_line(JSON.stringify({"second":second,"workers":workers,"refineries":refineries}))

## A controlled resource fixture using real ResourceA scenes and normal Match.
## Python receives the actual tactical/rules exports and returns contract params.
func _run() -> void:
	await _boot()
	var player = _match.get_local_player()
	player.add_resources({"resource_a": 80000}, "ScriptedAdjustment")
	var cc = _units(player, "command_center")[0]
	var home: Vector3 = cc.global_position
	if DisplayServer.get_name()!="headless":
		var camera = _match.get_node("IsometricCamera3D")
		camera.set_process(false)
		camera.set_physics_process(false)
		camera.set("edge_scroll_enabled",false)
		camera.size=115.0
		camera.set_position_safely(home+Vector3(35,0,0))
	var drone = _units(player, "drone")[0]
	var start: Vector3 = drone.global_position
	var moved = player.get_node("UnitCommandGateway").MoveUnits([drone],home+Vector3(60,0,0),player)
	await get_tree().create_timer(6.0).timeout
	_check(moved.get("status", "") == "Accepted" and drone.global_position.distance_to(start)>20,"reveal real remote ore with public move")
	var server = get_node("/root/DebugControlServer")
	for stage in ["rule-refinery", "model-vehicle_factory", "model-barracks", "model-aircraft_factory", "model-anti_air_turret", "model-anti_air_turret", "model-anti_ground_turret", "model-anti_ground_turret", "rule-command_center", "rule-local-refinery", "rule-local-defense-air", "rule-local-defense-ground", "rule-local-barracks"]:
		if stage.begins_with("model-"):
			# Completion and deferred free-miner spawning are distinct events.
			var miner_deadline := Time.get_ticks_msec()+10000
			while _units(player,"worker").is_empty() and Time.get_ticks_msec()<miner_deadline:
				await get_tree().physics_frame
			_check(not _units(player,"worker").is_empty(),"real free miner available to model BLD")
		var tactical: Dictionary = server._op_tactical(_match,{"as_player":str(player.name),"limit":512})
		var payload := {"stage":stage,"tactical":tactical,"rules":server._op_rules(_match)}
		var index := _rows.size()
		FileAccess.open(_out.path_join("input-%d.json" % index),FileAccess.WRITE).store_string(JSON.stringify(payload))
		var reply_path := _out.path_join("command-%d.json" % index)
		var deadline := Time.get_ticks_msec()+12000
		var generated: Dictionary = {}
		# Windows file publication/antivirus can briefly expose an unreadable
		# newly renamed file. Wait for valid JSON, rather than aborting the Match.
		while Time.get_ticks_msec()<deadline:
			if FileAccess.file_exists(reply_path):
				var parser := JSON.new()
				if parser.parse(FileAccess.get_file_as_string(reply_path))==OK and parser.data is Dictionary:
					generated=parser.data
					break
			await get_tree().create_timer(0.1).timeout
		_check(not generated.is_empty(), "python responds "+stage)
		if generated.is_empty():break
		var params: Dictionary = generated.get("params",{})
		# Same trusted scene-ID resolution performed by _op_adjutant_command.
		if params.has("scene"):
			params["scene"]=server._adjutant_resolve_scene_path(_match,str(params["scene"]))
		var before := _structures(player).size()
		var stamp := Time.get_ticks_usec()
		var reply: Dictionary = JSON.parse_string(server._op_build(_match,params)) if not params.is_empty() else {}
		_rows.append({"phase":stage,"python":generated,"reply":reply,"placement_ms":(Time.get_ticks_usec()-stamp)/1000.0,
			"placed_wall_seconds":(Time.get_ticks_msec()-_started)/1000.0})
		_check(_structures(player).size()==before+1,"Python intent actually places "+stage)
		await _wait_construction(player)
		_rows[-1]["completed_wall_seconds"]=(Time.get_ticks_msec()-_started)/1000.0
		if DisplayServer.get_name()!="headless":
			var camera = _match.get_node("IsometricCamera3D")
			camera.set_process(false)
			camera.set_physics_process(false)
			camera.set("edge_scroll_enabled",false)
			camera.size=115.0
			camera.set_position_safely(home+Vector3(35,0,0))
			await _shot(stage)
	var centers := _units(player,"command_center")
	var refineries := _units(player,"ore_refinery")
	_check(centers.size()==2,"adjutant builds a real second HQ")
	_check(refineries.size()==2,"both bases have refinery")
	if centers.size()==2:
		_check(_flat_distance(centers[0].global_position,centers[1].global_position)>=30,"HQ separation")
		if refineries.size()==2:
			_check(_flat_distance(refineries[1].global_position,centers[1].global_position)<30,"refinery uses remote HQ network")
		var towers := _units(player,"anti_ground_turret")
		_check(towers.size()==3,"remote defense still builds after two home towers")
		_check(towers.any(func(tower): return (tower.is_constructed() and
			_flat_distance(tower.global_position,centers[1].global_position)<30)),"remote defense completes")
		var air_towers := _units(player,"anti_air_turret")
		_check(air_towers.size()==3 and air_towers.any(func(tower): return (tower.is_constructed() and
			_flat_distance(tower.global_position,centers[1].global_position)<30)),"remote air defense completes after home cap")
		for type_id in ["vehicle_factory","barracks","aircraft_factory"]:
			for producer in _units(player,type_id):
				_check(_flat_distance(producer.global_position,centers[0].global_position)
					<_flat_distance(producer.global_position,centers[1].global_position),"production stays at opening HQ")
	var factories := _units(player,"vehicle_factory")
	if not factories.is_empty():
		_check(factories[0].production_queue.produce(load("res://source/match/units/Tank.tscn"))!=null,"production accepted")
		var deadline := Time.get_ticks_msec()+30000
		while _units(player,"tank").is_empty() and Time.get_ticks_msec()<deadline:
			await get_tree().create_timer(0.2).timeout
		var tanks := _units(player,"tank")
		_check(not tanks.is_empty(),"actual tank spawn")
		if not tanks.is_empty():
			var origin: Vector3=tanks[0].global_position
			var move_started: float=(Time.get_ticks_msec()-_started)/1000.0
			player.get_node("UnitCommandGateway").MoveUnits([tanks[0]],home+Vector3(60,0,30),player)
			await get_tree().create_timer(12.0).timeout
			_check(tanks[0].global_position.distance_to(origin)>15,"tank travels through expanded base")
			_rows.append({"phase":"tank-passage","displacement":tanks[0].global_position.distance_to(origin),
				"started_wall_seconds":move_started,"completed_wall_seconds":(Time.get_ticks_msec()-_started)/1000.0})
	await get_tree().create_timer(12.0).timeout
	var deliveries := 0
	var gap := INF
	var structures := _structures(player)
	var refinery_results: Array = []
	for refinery in refineries:
		deliveries+=refinery.delivered_count
		refinery_results.append({"name":str(refinery.name),"deliveries":refinery.delivered_count,"amount":refinery.delivered_amount})
		_check(refinery.delivered_count>0,"each completed refinery really delivers: "+str(refinery.name))
	for i in structures.size():
		for j in range(i+1,structures.size()):
			gap=minf(gap,_flat_distance(structures[i].global_position,structures[j].global_position)-float(structures[i].radius)-float(structures[j].radius))
	_rows.append({"phase":"final","structures":_structure_rows(player),"minimum_gap_m":gap,"deliveries":deliveries,"refineries":refinery_results})
	_check(gap>=5.6,"expanded layout clearance")
	_check(deliveries>0,"real mineral delivery")
	await _cleanup()
	await _boot()
	_check(get_tree().get_nodes_in_group("units").size()==2,"clean reopen")
	await _cleanup()
	FileAccess.open(_out.path_join("result.json"),FileAccess.WRITE).store_string(JSON.stringify({"failures":_failures,"rows":_rows,"wall_seconds":(Time.get_ticks_msec()-_started)/1000.0},"\t"))
	print("AI building layout probe completed: ",_failures," failure(s)")
	SmokeTestExit.request(get_tree(),0 if _failures==0 else 1)

func _boot() -> void:
	var settings=load("res://source/data-model/MatchSettings.gd").new()
	var player=load("res://source/data-model/PlayerSettings.gd").new()
	player.controller=Constants.PlayerType.HUMAN
	player.color=Constants.Player.COLORS[0]
	settings.players.append(player)
	settings.visible_player=0
	_match=load("res://source/match/Match.tscn").instantiate()
	_match.settings=settings
	_match.map=load("res://source/match/maps/PlainAndSimple.tscn").instantiate()
	var resource_parent=_match.map.get_node("Resources")
	# Map fixture only, before Match initialization; no unit/query mutation.
	var resources: Array = resource_parent.get_children()
	resources[0].position=Vector3(117,0.6,70)
	resources[1].position=Vector3(165,0.6,70)
	for i in range(2,resources.size()):resources[i].free()
	get_tree().root.add_child(_match)
	get_tree().current_scene=_match
	await get_tree().create_timer(2.5).timeout
	_check(get_tree().get_nodes_in_group("units").size()==2,"normal opening CC and drone")
