extends SceneTree
## 单位双向过桥验证：NavigationAgent3D 在烘焙 terrain 导航上从岸a→岸b、岸b→岸a
## 实际行走（模拟单位路径跟随），记录轨迹与高度，验证上桥(升到 deck_top)/过桥/下桥。
## 用法：godot --rendering-driver opengl3 --path AI_RTS --script bridge_cross_test.gd -- \
##   --map=<scene> --ax= --az= --bx= --bz= --deck= --out=<json>

func _init() -> void:
	_run()


func _run() -> void:
	await process_frame
	var map_path := ""
	var ax := 0.0
	var az := 0.0
	var bx := 0.0
	var bz := 0.0
	var deck := 1.3
	var out := "bridge_cross.json"
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--map="):
			map_path = a.substr(6)
		elif a.begins_with("--ax="):
			ax = float(a.substr(5))
		elif a.begins_with("--az="):
			az = float(a.substr(5))
		elif a.begins_with("--bx="):
			bx = float(a.substr(7 - 2))
		elif a.begins_with("--bz="):
			bz = float(a.substr(5))
		elif a.begins_with("--deck="):
			deck = float(a.substr(7))
		elif a.begins_with("--out="):
			out = a.substr(6)
	var map = load(map_path).instantiate()
	var match_node = load("res://source/match/Match.tscn").instantiate()
	var settings = load("res://source/data-model/MatchSettings.gd").new()
	var ps_script = load("res://source/data-model/PlayerSettings.gd")
	var players: Array[Resource] = []
	for i in range(4):
		var p = ps_script.new()
		p.controller = 0
		p.color = Color.WHITE
		players.append(p)
	settings.players = players
	settings.visibility = 2
	settings.local_player_index = -1
	match_node.settings = settings
	match_node.map = map
	root.add_child(match_node)
	root.gui_disable_input = true
	root.borderless = true
	root.position = Vector2i(3600, 80)
	for _i in range(12):
		await process_frame
		await physics_frame
	# 等待 terrain 导航烘焙
	var nav = match_node.get("navigation")
	var terrain_map: RID = nav.get_navigation_map_rid_by_domain(1)
	var center := Vector3((ax + bx) / 2.0, 0.2, (az + bz) / 2.0)
	for _w in range(600):
		var probe: Vector3 = NavigationServer3D.map_get_closest_point(terrain_map, center)
		if probe.length() > 1.0:
			break
		await process_frame

	var results: Dictionary = {}
	for dir_name in ["a_to_b", "b_to_a"]:
		var from := Vector3(ax, 0.8, az) if dir_name == "a_to_b" else Vector3(bx, 0.8, bz)
		var to := Vector3(bx, 0.8, bz) if dir_name == "a_to_b" else Vector3(ax, 0.8, az)
		var agent := NavigationAgent3D.new()
		var body := Node3D.new()
		root.add_child(body)
		body.add_child(agent)
		agent.path_desired_distance = 0.5
		agent.target_desired_distance = 0.5
		body.global_position = from
		await physics_frame
		agent.target_position = to
		var traj: Array = []
		var max_y := -999.0
		var min_y := 999.0
		var reached := false
		var speed := 6.0
		for step in range(900):
			await physics_frame
			var nxt: Vector3 = agent.get_next_path_position()
			var d: Vector3 = nxt - body.global_position
			d.y = 0
			if d.length() > 0.01:
				body.global_position += d.normalized() * minf(speed * (1.0 / 60.0), d.length())
			# Y 吸附到导航可走面高度，使轨迹高度反映上桥/桥面/下桥
			var surf: Vector3 = NavigationServer3D.map_get_closest_point(
				terrain_map, body.global_position)
			if surf.length() > 1.0:
				body.global_position.y = surf.y
			var y: float = body.global_position.y
			max_y = maxf(max_y, y)
			min_y = minf(min_y, y)
			if step % 20 == 0:
				traj.append([round(body.global_position.x * 10) / 10,
							 round(y * 100) / 100,
							 round(body.global_position.z * 10) / 10])
			if agent.is_navigation_finished() or body.global_position.distance_to(to) < 2.0:
				reached = true
				break
		results[dir_name] = {
			"reached": reached,
			"max_y": round(max_y * 100) / 100,
			"min_y": round(min_y * 100) / 100,
			"climbed_to_deck": max_y >= deck - 0.35,
			"traj": traj,
		}
		agent.queue_free()
		body.queue_free()
		await process_frame
	var ok: bool = (results["a_to_b"]["reached"] and results["b_to_a"]["reached"]
			   and results["a_to_b"]["climbed_to_deck"] and results["b_to_a"]["climbed_to_deck"])
	results["all_pass"] = ok
	results["deck_top"] = deck
	var f := FileAccess.open(out, FileAccess.WRITE)
	f.store_string(JSON.stringify(results, "  "))
	f.close()
	print("BRIDGECROSS a_to_b reached=%s maxY=%s | b_to_a reached=%s maxY=%s | all=%s" % [
		results["a_to_b"]["reached"], results["a_to_b"]["max_y"],
		results["b_to_a"]["reached"], results["b_to_a"]["max_y"], ok])
	quit(0 if ok else 1)
