extends Node

## 真实 Match 中的弹道位置探针：记录炮口、弹体根节点、可见 Body 和 Path3D 起点，
## 并在多种弹体同时飞行时保存一张可见截图。

const MatchSettings = preload("res://source/data-model/MatchSettings.gd")
const PlayerSettings = preload("res://source/data-model/PlayerSettings.gd")
const UnitScenes := {
	"tank": "res://source/match/units/Tank.tscn",
	"heavy_tank": "res://source/match/units/HeavyTank.tscn",
	"soldier": "res://source/match/units/Infantry.tscn",
	"sniper": "res://source/match/units/Sniper.tscn",
	"helicopter": "res://source/match/units/Helicopter.tscn",
	"rocketeer": "res://source/match/units/Rocketeer.tscn",
	"anti_ground_turret": "res://source/match/units/AntiGroundTurret.tscn",
	"machine_gun_turret": "res://source/match/units/MachineGunTurret.tscn",
	"anti_air_turret": "res://source/match/units/AntiAirTurret.tscn",
	"apc": "res://source/match/units/APC.tscn",
}
const OUT_DIR := "res://agent/runs/20261010-projectile-origin/probe"

var _failures := 0
var _match: Node
var _projectiles: Node
var _records: Array[Dictionary] = []


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	var settings := MatchSettings.new()
	var human := PlayerSettings.new()
	human.controller = Constants.PlayerType.HUMAN
	human.color = Color.BLUE
	settings.players.append(human)
	var ai := PlayerSettings.new()
	ai.controller = Constants.PlayerType.HUMAN
	ai.color = Color.RED
	settings.players.append(ai)
	settings.visible_player = 0
	settings.local_player_index = 0

	_match = load("res://source/match/Match.tscn").instantiate()
	_match.settings = settings
	_match.map = load("res://source/match/maps/PlainAndSimple.tscn").instantiate()
	get_tree().root.add_child.call_deferred(_match)
	await get_tree().process_frame
	await _wait_for_match_ready()

	_projectiles = _match.get_node("Projectiles")
	var players: Node = _match.get_node("Players")
	var human_player: Node = players.get_child(0)
	var enemy_player: Node = players.get_child(1)
	var catalog = _match.get_node("BalanceConfigRuntime")
	var runtime = _match.get_node("ProjectileRuntime")
	var focus := Vector3(32.0, 0.0, 29.0)

	var launch_specs := [
		["tank", human_player, Vector3(24.0, 0.0, 22.0), Vector3(34.0, 0.6, 22.0)],
		["heavy_tank", human_player, Vector3(24.0, 0.0, 28.0), Vector3(34.0, 0.6, 28.0)],
		["soldier", human_player, Vector3(24.0, 0.0, 34.0), Vector3(34.0, 0.6, 34.0)],
		["rocketeer", human_player, Vector3(30.0, 0.0, 22.0), Vector3(40.0, 0.6, 22.0)],
		["anti_ground_turret", human_player, Vector3(30.0, 0.0, 28.0), Vector3(40.0, 0.6, 28.0)],
		["machine_gun_turret", human_player, Vector3(50.0, 0.0, 40.0), Vector3(60.0, 0.6, 40.0)],
		["anti_air_turret", human_player, Vector3(50.0, 0.0, 46.0), Vector3(60.0, 5.6, 46.0)],
		["apc", human_player, Vector3(50.0, 0.0, 52.0), Vector3(60.0, 0.6, 52.0)],
	]
	for spec in launch_specs:
		var shooter := _spawn_unit(catalog, str(spec[0]), spec[1], spec[2])
		var target := Node3D.new()
		target.name = "%s_Target" % spec[0]
		_match.add_child(target)
		target.global_position = spec[3]
		var aim_node = shooter.presentation_aim_node()
		if aim_node != null:
			aim_node.global_rotation.y = PI / 2.0
		else:
			shooter.rotation.y = -PI / 2.0
		var gateway = human_player.get_node("UnitCommandGateway")
		gateway.SetFirePolicy([shooter], "HoldFire", human_player)
		await get_tree().create_timer(0.5).timeout
		var attack_id: String = runtime.LaunchEntity(shooter, target, false)
		var record := _capture_record(str(spec[0]), shooter, target, attack_id)
		_records.append(record)
		_validate_record(record)
		_validate_barrel_alignment(shooter, str(spec[0]))

	_write_records()
	if DisplayServer.get_name() == "headless":
		print("Projectile origin visual probe completed: %d failure(s)" % _failures)
		_match.queue_free()
		await get_tree().process_frame
		get_tree().quit(0 if _failures == 0 else 1)
		return
	var camera := _match.get_node_or_null("IsometricCamera3D") as Camera3D
	if camera != null:
		camera.edge_scroll_enabled = false
		camera.set_size_safely(25.0)
		camera.global_position = focus + Vector3(0.0, 35.0, 35.0)
		camera.look_at(focus, Vector3.UP)
	await get_tree().create_timer(0.22).timeout
	await RenderingServer.frame_post_draw
	var image: Image = get_viewport().get_texture().get_image()
	var screenshot_path := ProjectSettings.globalize_path(OUT_DIR + "/projectile-origins.png")
	var screenshot_error := image.save_png(screenshot_path) if image != null else ERR_CANT_CREATE
	_check(screenshot_error == OK, "应保存真实 Match 弹道位置截图")
	print("[PROBE] screenshot=%s error=%d" % [screenshot_path, screenshot_error])
	await get_tree().create_timer(0.25).timeout
	print("Projectile origin visual probe completed: %d failure(s)" % _failures)
	_match.queue_free()
	await get_tree().process_frame
	get_tree().quit(0 if _failures == 0 else 1)


func _wait_for_match_ready() -> void:
	var deadline := Time.get_ticks_msec() + 90000
	while Time.get_ticks_msec() < deadline:
		var players: Node = _match.get_node_or_null("Players")
		if _match.is_node_ready() and players != null and players.get_child_count() >= 2 \
				and get_tree().get_nodes_in_group("units").size() >= 2:
			await get_tree().physics_frame
			await get_tree().physics_frame
			return
		await get_tree().physics_frame
	_failures += 1
	push_error("真实 Match 未在 90 秒内就绪")


func _spawn_unit(catalog, type_id: String, player: Node, position: Vector3) -> Node3D:
	var unit := (load(UnitScenes[type_id]) as PackedScene).instantiate() as Node3D
	catalog.ConfigureUnit(unit)
	_match._setup_and_spawn_unit(unit, Transform3D(Basis.IDENTITY, position), player, false)
	return unit


func _capture_record(type_id: String, shooter: Node3D, target: Node3D, attack_id: String) -> Dictionary:
	var muzzles: Array[Vector3] = []
	for name in ["MuzzleL", "MuzzleR"]:
		var muzzle := shooter.find_child(name, true, false) as Node3D
		if muzzle != null:
			muzzles.append(muzzle.global_position)
	var origin := shooter.find_child("ProjectileOrigin", true, false) as Node3D
	if origin != null:
		muzzles.append(origin.global_position)
	var mesh_data: Array = []
	for child in shooter.find_children("*", "MeshInstance3D", true, false):
		var mesh_node := child as MeshInstance3D
		if mesh_node.mesh == null:
			continue
		var ref_node := origin.get_parent() as Node3D
		var ref_xform: Transform3D = ref_node.global_transform.affine_inverse() * mesh_node.global_transform
		var aabb: AABB = ref_xform * mesh_node.mesh.get_aabb()
		mesh_data.append({"path": str(shooter.get_path_to(mesh_node)), "aabb_min": _vec(aabb.position), "aabb_max": _vec(aabb.end)})
		if "barrel" in String(mesh_node.name).to_lower():
			mesh_data[-1]["caps"] = _mesh_caps(mesh_node, ref_xform, type_id)
	var projectile := _projectile_by_attack_id(attack_id)
	var record := {
		"type": type_id,
		"shooter": _vec(shooter.global_position),
		"target": _vec(target.global_position),
		"muzzles": muzzles.map(func(value): return _vec(value)),
		"attack_id": attack_id,
		"meshes_in_marker_parent": mesh_data,
		"marker_local": _vec(origin.position),
	}
	if projectile == null:
		return record
	record["projectile_root"] = _vec(projectile.global_position)
	var body := projectile.find_child("Body", true, false) as Node3D
	if body != null:
		record["body"] = _vec(body.global_position)
	var visible_mesh := projectile.find_child("MeshInstance3D", true, false) as Node3D
	if visible_mesh != null:
		record["visible_mesh"] = _vec(visible_mesh.global_position)
	var path := projectile.find_child("Path3D", true, false) as Path3D
	if path != null and path.curve.point_count >= 2:
		record["path_start"] = _vec(path.to_global(path.curve.get_point_position(0)))
		record["path_end"] = _vec(path.to_global(path.curve.get_point_position(1)))
	return record


func _validate_record(record: Dictionary) -> void:
	var type_id := str(record.get("type", ""))
	var muzzle_values: Array = record.get("muzzles", [])
	if muzzle_values.is_empty():
		_check(false, "%s 应记录至少一个炮口挂点" % type_id)
		return
	var root := _from_vec(record.get("projectile_root", {}))
	var body := _from_vec(record.get("body", record.get("visible_mesh", {})))
	var nearest_root := _nearest_distance(root, muzzle_values)
	_check(nearest_root <= 0.35,
		"%s 弹体根节点应从炮口出膛（最近 %.3fm）" % [type_id, nearest_root])
	if body.is_finite():
		var nearest_body := _nearest_distance(body, muzzle_values)
		_check(nearest_body <= 0.35,
			"%s 可见弹体应从炮口出现（最近 %.3fm）" % [type_id, nearest_body])
	if record.has("path_start"):
		var path_start := _from_vec(record.path_start)
		var nearest_path := _nearest_distance(path_start, muzzle_values)
		_check(nearest_path <= 0.35,
			"%s Path3D 起点应从炮口出膛（最近 %.3fm）" % [type_id, nearest_path])


func _mesh_caps(mesh_node: MeshInstance3D, ref_xform: Transform3D, _type_id: String) -> Array:
	# Cap triangles are connected separately: an entire rack/two tubes has no single muzzle center.
	var extreme := -INF
	for surface in range(mesh_node.mesh.get_surface_count()):
		var arrays := mesh_node.mesh.surface_get_arrays(surface)
		for vertex: Vector3 in arrays[Mesh.ARRAY_VERTEX]:
			extreme = maxf(extreme, vertex.z)
	var points := {}
	var edges := {}
	for surface in range(mesh_node.mesh.get_surface_count()):
		var arrays := mesh_node.mesh.surface_get_arrays(surface)
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		if indices.is_empty():
			for index in range(vertices.size()):
				indices.append(index)
		for index in range(0, indices.size() - 2, 3):
			var face := [vertices[indices[index]], vertices[indices[index+1]], vertices[indices[index+2]]]
			if face.any(func(vertex: Vector3): return vertex.z < extreme - 0.001):
				continue
			var keys: Array[String] = []
			for vertex: Vector3 in face:
				var key := str(vertex.snapped(Vector3.ONE * 0.0001))
				points[key] = vertex
				if not edges.has(key): edges[key] = {}
				keys.append(key)
			for from_key in keys:
				for to_key in keys:
					edges[from_key][to_key] = true
	var visited := {}
	var caps: Array = []
	for key in points:
		if visited.has(key): continue
		var pending: Array = [key]
		var low := Vector3.INF
		var high := -Vector3.INF
		while not pending.is_empty():
			var next_key: String = pending.pop_back()
			if visited.has(next_key): continue
			visited[next_key] = true
			low = low.min(points[next_key])
			high = high.max(points[next_key])
			for neighbor in edges[next_key]:
				if not visited.has(neighbor): pending.append(neighbor)
		caps.append(_vec(ref_xform * ((low + high) / 2.0)))
	return caps


## Derive the forward ring from model vertices, independent of authored Marker coordinates.
func _validate_barrel_alignment(shooter: Node3D, type_id: String) -> void:
	if type_id not in ["tank", "heavy_tank", "anti_ground_turret", "machine_gun_turret", "anti_air_turret", "helicopter"]:
		return
	var origin := shooter.find_child("ProjectileOrigin", true, false) as Node3D
	var reference := origin.get_parent() as Node3D
	var caps: Array[Vector3] = []
	for mesh_node in shooter.find_children("*", "MeshInstance3D", true, false):
		var mesh_name := String(mesh_node.name).to_lower()
		if type_id == "anti_air_turret":
			if "missiles" not in mesh_name: continue
		elif type_id == "helicopter":
			if "_gun_" not in mesh_name: continue
		elif "barrel" not in mesh_name:
			continue
		# Tank's telescoping tip is the final barrel mesh, not the enclosing rear tube.
		if type_id == "tank" and not String(mesh_node.name).ends_with("_001"):
			continue
		var mesh_transform: Transform3D = reference.global_transform.affine_inverse() * mesh_node.global_transform
		for point in _mesh_caps(mesh_node, mesh_transform, type_id):
			caps.append(reference.to_global(_from_vec(point)))
	var markers: Array[Node3D] = []
	for marker_name in ["MuzzleL", "MuzzleR"]:
		var marker := shooter.find_child(marker_name, true, false) as Node3D
		if marker != null:
			markers.append(marker)
	if markers.is_empty():
		markers.append(origin)
	_check(caps.size() >= markers.size(), "%s 应找到各独立模型端面" % type_id)
	for marker in markers:
		var nearest := INF
		for cap in caps:
			nearest = minf(nearest, marker.global_position.distance_to(cap))
		_check(nearest < 0.025, "%s %s 应位于模型末端圈中心，偏差 %.4fm" % [type_id, marker.name, nearest])


func _nearest_distance(point: Vector3, muzzle_values: Array) -> float:
	var nearest := INF
	for value in muzzle_values:
		nearest = minf(nearest, point.distance_to(_from_vec(value)))
	return nearest


func _from_vec(value: Variant) -> Vector3:
	if not (value is Dictionary):
		return Vector3.INF
	return Vector3(float(value.get("x", INF)), float(value.get("y", INF)), float(value.get("z", INF)))


func _projectile_by_attack_id(attack_id: String) -> Node3D:
	for child in _projectiles.get_children():
		if child is Node3D and str(child.get("attack_id")) == attack_id:
			return child
	return null


func _write_records() -> void:
	var path := ProjectSettings.globalize_path(OUT_DIR + "/positions.json")
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		_failures += 1
		return
	file.store_string(JSON.stringify({"records": _records}, "  "))
	file.close()
	print("[PROBE] positions=%s" % path)


func _vec(value: Vector3) -> Dictionary:
	return {"x": value.x, "y": value.y, "z": value.z}


func _check(condition: bool, message: String) -> void:
	if condition:
		return
	_failures += 1
	push_error("Projectile origin probe: " + message)
