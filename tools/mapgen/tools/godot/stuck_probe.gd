extends SceneTree
## 一次性探针：AI 局内对比前后快照，dump 仍未移动的非建筑单位坐标（用后即删）。
## 用法：Godot_mono --rendering-driver opengl3 --path AI_RTS --script stuck_probe.gd
##        -- --map=res://.../seed_16.tscn --out=<abs json> [--size=256] [--seconds=120]

const COLORS := [Color("66b1ff"), Color("ff5c73"), Color("a5ff99"), Color("ed85ff")]

var _structure_prefixes := ["CommandCenter", "Factory", "Turret", "Depot", "Barracks", "Tech"]


func _init() -> void:
	_run()


func _snapshot(match_node: Node) -> Dictionary:
	var snap := {}
	for u in get_nodes_in_group("units"):
		if match_node.is_ancestor_of(u) and u is Node3D:
			snap[u.get_instance_id()] = {
				"name": String(u.name),
				"pos": (u as Node3D).global_position,
				"player": str(u.get("player")) if u.get("player") != null else "?",
			}
	return snap


func _is_structure(name: String) -> bool:
	for pref in _structure_prefixes:
		if name.begins_with(pref) or pref in name:
			return true
	return false


func _run() -> void:
	await process_frame
	var map_path := ""
	var out_path := "stuck_probe.json"
	var size := 256.0
	var seconds := 120.0
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--map="):
			map_path = a.substr(6)
		elif a.begins_with("--out="):
			out_path = a.substr(6)
		elif a.begins_with("--size="):
			size = float(a.substr(7))
		elif a.begins_with("--seconds="):
			seconds = float(a.substr(10))
	var map = load(map_path).instantiate()
	var match_node = load("res://source/match/Match.tscn").instantiate()
	var settings = load("res://source/data-model/MatchSettings.gd").new()
	var ps_script = load("res://source/data-model/PlayerSettings.gd")
	var players: Array[Resource] = []
	for i in range(4):
		var p = ps_script.new()
		p.controller = 2
		p.color = COLORS[i]
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
	var t0_ms := Time.get_ticks_msec()
	var t := 0.0
	var snap_a := {}
	var snap_b := {}
	while t < seconds:
		await process_frame
		t = (Time.get_ticks_msec() - t0_ms) / 1000.0
		if t >= seconds * 0.5 and snap_a.is_empty():
			snap_a = _snapshot(match_node)
	snap_b = _snapshot(match_node)
	var still := []
	var movers := 0
	for id in snap_b:
		if snap_a.has(id) and not _is_structure(snap_b[id]["name"]):
			var moved: bool = snap_a[id]["pos"].distance_to(snap_b[id]["pos"]) > 0.05
			if moved:
				movers += 1
			else:
				still.append({"name": snap_b[id]["name"], "player": snap_b[id]["player"],
							  "x": snap_b[id]["pos"].x, "z": snap_b[id]["pos"].z})
	var f := FileAccess.open(out_path, FileAccess.WRITE)
	f.store_string(JSON.stringify({"checked": snap_b.size(), "movers": movers,
		"still": still}, "  "))
	f.close()
	print("stuck_probe: units=%d movers=%d still=%d -> %s" % [snap_b.size(), movers, still.size(), out_path])
	quit(0)
