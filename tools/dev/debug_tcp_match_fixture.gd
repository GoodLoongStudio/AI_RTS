extends Node

# Dedicated real-Match lifecycle fixture; no OS input or user-instance interaction.
var match_node: Node
var out := ""
var round_number := 0
var measure := false
var frame_samples: Array = []
var last_frame_us := 0
var sample_origin_us := 0
var simulated_seconds := 0.0
var render_samples: Array = []
var last_draw_us := 0
var capture_until_us := 0
var next_capture_us := 0
var capture_index := 0
var capture_busy := false
var gpu_probe := false

func _physics_process(delta: float) -> void:
	if measure:
		simulated_seconds += delta

func _draw_observed() -> void:
	var now := Time.get_ticks_usec()
	if measure and last_draw_us > 0:
		render_samples.append({"us": now, "frame_ms": float(now-last_draw_us)/1000.0})
	last_draw_us = now
	if gpu_probe and not capture_busy and now < capture_until_us and now >= next_capture_us:
		next_capture_us = now + 200000
		_capture_frame.call_deferred()

func _capture_frame() -> void:
	capture_busy = true
	await RenderingServer.frame_post_draw
	var before := Time.get_ticks_usec()
	var image := get_viewport().get_texture().get_image()
	var path := out.path_join("frame-%04d.png" % capture_index)
	var rc := image.save_png(path)
	var record := FileAccess.open(out.path_join("capture.jsonl"), FileAccess.READ_WRITE)
	record.seek_end()
	record.store_line(JSON.stringify({"index": capture_index, "us": before, "completed_us": Time.get_ticks_usec(), "rc": rc, "drawn": Engine.get_frames_drawn(), "path": path}))
	record.close()
	capture_index += 1
	capture_busy = false

func _measurement_snapshot() -> Dictionary:
	var camera = match_node.get_node("IsometricCamera3D")
	return {"samples": frame_samples, "render_samples": render_samples, "simulated_seconds": simulated_seconds, "end_us": Time.get_ticks_usec(), "origin_us": sample_origin_us,
		"display_driver": DisplayServer.get_name(), "render_driver": RenderingServer.get_current_rendering_driver_name(),
		"native_hwnd": DisplayServer.window_get_native_handle(DisplayServer.WINDOW_HANDLE), "window_mode": DisplayServer.window_get_mode(), "window_visible": get_window().visible, "frames_drawn": Engine.get_frames_drawn(), "cmdline": OS.get_cmdline_args(),
		"physics_frames": Engine.get_physics_frames(), "physics_ticks": Engine.physics_ticks_per_second,
		"time_scale": Engine.time_scale, "max_fps": Engine.max_fps,
		"vsync": DisplayServer.window_get_vsync_mode(), "window_size": str(DisplayServer.window_get_size()),
		"camera_transform": str(camera.global_transform), "camera_size": camera.size,
		"renderer": RenderingServer.get_current_rendering_method(),
		"gpu": RenderingServer.get_video_adapter_name(), "entities": get_tree().get_nodes_in_group("units").size()}

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	for arg in OS.get_cmdline_user_args():
		if arg == "--gpu-probe":
			gpu_probe = true
		if arg.begins_with("--tcp-out="):
			out = arg.trim_prefix("--tcp-out=")
	if gpu_probe:
		RenderingServer.frame_post_draw.connect(_draw_observed)
	_start_round.call_deferred()

func _start_round() -> void:
	round_number += 1
	var settings = load("res://source/data-model/MatchSettings.gd").new()
	var player = load("res://source/data-model/PlayerSettings.gd").new()
	player.controller = Constants.PlayerType.HUMAN
	player.color = Constants.Player.COLORS[0]
	settings.players.append(player)
	settings.visible_player = 0
	settings.local_player_index = 0
	match_node = load("res://source/match/Match.tscn").instantiate()
	match_node.settings = settings
	match_node.map = load("res://source/match/maps/PlainAndSimple.tscn").instantiate()
	get_tree().root.add_child(match_node)
	get_tree().current_scene = match_node
	await get_tree().create_timer(6.0).timeout
	var camera = match_node.get_node("IsometricCamera3D")
	camera.edge_scroll_enabled = false
	if gpu_probe:
		seed(461011)
		var human = match_node.get_local_player()
		var roster := ["Infantry", "Tank", "APC", "Worker", "HeavyTank", "Sniper"]
		for i in range(44):
			var unit = load("res://source/match/units/%s.tscn" % roster[i % roster.size()]).instantiate()
			match_node._setup_and_spawn_unit(unit, Transform3D(Basis(), Vector3(65 + i % 8 * 6, 0, 65 + i / 8 * 6)), human)
		camera.size = 80.0
		camera.set_position_safely(Vector3(80, 0, 65))
		await get_tree().create_timer(8.0).timeout
		var identity := FileAccess.open(out.path_join("gpu-identity.json"), FileAccess.WRITE)
		identity.store_string(JSON.stringify(_measurement_snapshot()))
		identity.close()
	var file := FileAccess.open(out.path_join("ready-%d.json" % round_number), FileAccess.WRITE)
	file.store_string(JSON.stringify({"round": round_number, "pid": OS.get_process_id(),
		"units": get_tree().get_nodes_in_group("units").size(), "written_at": Time.get_datetime_string_from_system()}))
	file.close()

func _process(_delta: float) -> void:
	if out.is_empty() or match_node == null:
		return
	var now_us := Time.get_ticks_usec()
	if measure and last_frame_us > 0:
		frame_samples.append({"us": now_us, "frame_ms": float(now_us-last_frame_us)/1000.0,
			"physics_frames": Engine.get_physics_frames()})
	last_frame_us = now_us
	if FileAccess.file_exists(out.path_join("measure-start")):
		DirAccess.remove_absolute(out.path_join("measure-start"))
		frame_samples = []
		render_samples = []
		simulated_seconds = 0.0
		sample_origin_us = now_us
		measure = true
	if gpu_probe and FileAccess.file_exists(out.path_join("capture-start")):
		DirAccess.remove_absolute(out.path_join("capture-start"))
		var cap := FileAccess.open(out.path_join("capture.jsonl"), FileAccess.WRITE)
		cap.close()
		capture_until_us = now_us + 60000000
		next_capture_us = now_us
	if FileAccess.file_exists(out.path_join("tcp-inspect")):
		DirAccess.remove_absolute(out.path_join("tcp-inspect"))
		var dcs = get_node("/root/DebugControlServer")
		var peers: Array = []
		for peer in dcs._clients:
			var id: int = peer.get_instance_id()
			peers.append({"port": peer.get_connected_port(), "input_bytes": dcs._buffers[id].size(),
				"kernel_bytes": peer.get_available_bytes(), "output_bytes": dcs._outputs[id].size()})
		var inspect_file := FileAccess.open(out.path_join("tcp-state.json"), FileAccess.WRITE)
		inspect_file.store_string(JSON.stringify({"clients": dcs._clients.size(), "peers": peers,
			"buffers": dcs._buffers.size(), "output_bytes": dcs._output_bytes,
			"idle_closed": dcs._idle_closed, "written_ms": Time.get_ticks_msec()}))
		inspect_file.close()
	if FileAccess.file_exists(out.path_join("measure-stop")):
		DirAccess.remove_absolute(out.path_join("measure-stop"))
		measure = false
		var sample_file := FileAccess.open(out.path_join("measurement.json"), FileAccess.WRITE)
		sample_file.store_string(JSON.stringify(_measurement_snapshot()))
		sample_file.close()
	# A standalone automated human must resolve normal draft offers, not freeze TCP tests.
	var augment = match_node.get_node_or_null("AugmentRuntime")
	if augment != null and augment.has_method("snapshot_for"):
		var player = match_node.get_local_player()
		var state: Dictionary = augment.snapshot_for(player)
		var offer: Array = state.get("offer", [])
		if not offer.is_empty():
			augment.pick(player, str(offer[0].get("id", "")), "player")
	var selected_file := out.path_join("select.json")
	if FileAccess.file_exists(selected_file):
		var parsed = JSON.parse_string(FileAccess.get_file_as_string(selected_file))
		DirAccess.remove_absolute(selected_file)
		for unit in get_tree().get_nodes_in_group("units"):
			if str(unit.name) == str(parsed.get("unit", "")):
				unit.add_to_group("selected_units")
	if FileAccess.file_exists(out.path_join("next-round")):
		DirAccess.remove_absolute(out.path_join("next-round"))
		_restart.call_deferred()
	if FileAccess.file_exists(out.path_join("quit")):
		DirAccess.remove_absolute(out.path_join("quit"))
		SmokeTestExit.request(get_tree(), 0, match_node)

func _restart() -> void:
	get_tree().current_scene = null
	match_node.queue_free()
	match_node = null
	await get_tree().process_frame
	await get_tree().process_frame
	_start_round()
