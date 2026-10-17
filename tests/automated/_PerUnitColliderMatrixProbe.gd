extends Node

## 逐实体碰撞层测量探针（本任务 1 号交付物）
## 每个实体一行，量出：视觉世界 AABB / 近地投影 hull / 碰撞形状(类型+世界尺寸+owner 路径) /
## 形状读取器是否成功 / Movement.radius / MovementObstacle(vertices 数+carve 外缘+两个开关) /
## carve 净空 / 服务半径。first_limiting_layer 由四方向贴边探针单独填（本文件写 unknown）。
## 输出：res://agent/runs/2026-10-01-per-unit-collider-clearance/per-unit-collider-matrix.json

const OUT_PATH := "res://agent/runs/2026-10-01-per-unit-collider-clearance/per-unit-collider-matrix.json"
const MAP_SCENE := "res://source/match/maps/PlainAndSimple.tscn"

const ENTITIES := [
	"CommandCenter", "VehicleFactory", "Barracks", "AircraftFactory", "OreRefinery",
	"AntiGroundTurret", "AntiAirTurret", "MachineGunTurret",
	"Tank", "HeavyTank", "APC", "TransportTruck", "Worker", "Scout",
	"Infantry", "Rocketeer", "Sniper", "Helicopter", "Drone",
]
const NON_PLAYER := ["ResourceA", "ResourceB"]


func _ready():
	# 兜底：任何情况下 150 秒内必退，避免探针挂住（此前踩过"进程不退出"的坑）。
	get_tree().create_timer(150.0).timeout.connect(func() -> void:
		push_error("[MATRIX] 超时兜底退出")
		get_tree().quit(2))

	var settings = load("res://source/data-model/MatchSettings.gd").new()
	var hs = load("res://source/data-model/PlayerSettings.gd").new()
	hs.controller = Constants.PlayerType.HUMAN
	hs.color = Constants.Player.COLORS[0]
	settings.players.append(hs)
	settings.visible_player = 0
	var m: Node = load("res://source/match/Match.tscn").instantiate()
	m.settings = settings
	m.map = load(MAP_SCENE).instantiate()
	add_child(m)
	get_tree().current_scene = m
	for _f in range(200):
		await get_tree().physics_frame
	var player: Node = m.get_node("Players").get_children()[0]

	var rows: Array = []
	var z := 60.0
	for name in ENTITIES + NON_PLAYER:
		var path: String = "res://source/match/units/" + name + ".tscn"
		if name in NON_PLAYER:
			path = "res://source/match/units/non-player/" + name + ".tscn"
		var inst: Node3D = (load(path) as PackedScene).instantiate()
		if name in NON_PLAYER:
			# 【测量专用】资源点不属于任何玩家：挂到独立 holder 上量几何，
			# 不走 _setup_and_spawn_unit（否则会被当成玩家单位，触发 AI/索敌报错死循环）。
			var holder := Node3D.new()
			holder.position = Vector3(70.0, 0.0, z)
			add_child(holder)
			holder.add_child(inst)
		else:
			m.call("_setup_and_spawn_unit", inst, Transform3D(Basis.IDENTITY, Vector3(70.0, 0.0, z)), player, false)
		z += 14.0
		# 等稳定初始化：MovementObstacle._sync_carve_vertices 会在 _enter_tree/_ready 重写 vertices
		for _f in range(20):
			await get_tree().physics_frame
		rows.append(_measure(name, path, inst))
	for row in rows:
		print("[MATRIX] %s|视觉X=%.2f|近地X=%.2f|碰撞=%s:%.2f|逻辑r=%.2f|vertices=%d|carve外缘=%.2f|affect=%s|frombounds=%s|净空=%.2f" % [
			row.entity, row.visual_world_aabb_m.size[0], row.ground_projection_hull_m.size[0],
			row.collision_shape_types_and_owner_paths[0].shape if row.collision_shape_types_and_owner_paths.size() > 0 else "无",
			(row.collision_shape_world_m[0] if row.collision_shape_world_m != null else -1.0),
			row.movement_hull_or_radius_m, row.obstacle_vertex_count,
			row.obstacle_vertices_and_carve_bounds_m, str(row.obstacle_affect_navigation),
			str(row.obstacle_carve_from_bounds), row.logic_blocker_and_stand_off_m])
	var payload := {
		"schema": "per-unit-collider-matrix/v1",
		"generated_at": Time.get_datetime_string_from_system(),
		"map": MAP_SCENE,
		"note": "first_limiting_layer 需由四方向贴边探针填写；本表该字段为 unknown 的实体不得判通过。",
		"rows": rows,
	}
	var f := FileAccess.open(OUT_PATH, FileAccess.WRITE)
	if f == null:
		push_error("无法写入 %s" % OUT_PATH)
	else:
		f.store_string(JSON.stringify(payload, "  "))
		f.close()
		print("[MATRIX] 已写入 %s（%d 行）" % [OUT_PATH, rows.size()])
	get_tree().quit(0)


func _measure(name: String, path: String, unit: Node3D) -> Dictionary:
	var visual := _union_geometry(unit, 1.0)
	var ground := _union_geometry(unit, 0.5)
	var shapes: Array = []
	for child in unit.find_children("*", "CollisionShape3D", true, false):
		var cs := child as CollisionShape3D
		if cs == null or cs.shape == null:
			continue
		var world := _world_aabb(cs)
		shapes.append({
			"owner_path": str(unit.get_path_to(cs)),
			"shape": _shape_class(cs.shape),
			"world_size_m": [world.size.x, world.size.y, world.size.z],
			"reader_ok": _reader_ok(cs.shape),
		})
	var obstacle: Node = unit.find_child("MovementObstacle", true, false)
	var verts := PackedVector3Array()
	var carve_extent := 0.0
	var affect := false
	var from_bounds := false
	if obstacle != null:
		verts = obstacle.get("vertices")
		for v in verts:
			carve_extent = maxf(carve_extent, Vector2(v.x, v.z).length())
		affect = bool(obstacle.get("affect_navigation_mesh"))
		from_bounds = bool(obstacle.get("carve_from_collision_bounds"))
	return {
		"entity": name,
		"scene_path": path,
		"visual_world_aabb_m": {"size": [visual.size.x, visual.size.y, visual.size.z], "min": [visual.position.x, visual.position.y, visual.position.z]},
		"ground_projection_hull_m": {"size": [ground.size.x, ground.size.y, ground.size.z]},
		"collision_shape_world_m": shapes[0].world_size_m if shapes.size() > 0 else null,
		"collision_shape_types_and_owner_paths": shapes,
		"movement_hull_or_radius_m": float(unit.get("radius")) if unit.get("radius") != null else -1.0,
		"obstacle_vertex_count": verts.size(),
		"obstacle_vertices_and_carve_bounds_m": carve_extent,
		"obstacle_affect_navigation": affect,
		"obstacle_carve_from_bounds": from_bounds,
		"logic_blocker_and_stand_off_m": Utils.Match.Unit.Movement.carve_clearance_of(unit),
		"service_radius_m": float(unit.get("service_radius_m")) if unit.get("service_radius_m") != null else -1.0,
		"first_limiting_layer": "unknown",
	}


func _shape_class(shape: Shape3D) -> String:
	if shape is CylinderShape3D: return "CylinderShape3D"
	if shape is BoxShape3D: return "BoxShape3D"
	if shape is CapsuleShape3D: return "CapsuleShape3D"
	if shape is SphereShape3D: return "SphereShape3D"
	if shape is ConvexPolygonShape3D: return "ConvexPolygonShape3D"
	if shape is ConcavePolygonShape3D: return "ConcavePolygonShape3D"
	return "未知"


## 读取器是否支持（调用 MovementObstacle 的真实分支实现，不靠名字猜）
func _reader_ok(shape: Shape3D) -> bool:
	var probe: Object = load("res://source/match/units/traits/MovementObstacle.gd").new()
	var box = probe.call("_shape_local_aabb", shape)
	probe.free()
	if box == null:
		return false
	return (box as AABB).size.length_squared() > 0.0


func _union_geometry(unit: Node3D, ground_ratio: float) -> AABB:
	var boxes: Array = []
	var top := 0.0
	for gi in unit.find_children("*", "GeometryInstance3D", true, false):
		var p := str(gi.get_path())
		if p.contains("Selection") or p.contains("Highlight") or p.contains("Targetability") \
				or p.contains("HealthBar") or p.contains("RallyPoint"):
			continue
		var local: AABB = (gi as GeometryInstance3D).get_aabb()
		if gi is MeshInstance3D and (gi as MeshInstance3D).mesh != null and local.size.length() < 0.01:
			local = (gi as MeshInstance3D).mesh.get_aabb()
		if local.size.length() < 0.001:
			continue
		var xf: Transform3D = (gi as Node3D).global_transform
		var box := AABB()
		var first := true
		for i in range(8):
			var pt: Vector3 = xf * local.get_endpoint(i)
			if first:
				box = AABB(pt, Vector3.ZERO); first = false
			else:
				box = box.expand(pt)
		boxes.append(box)
		top = maxf(top, box.position.y + box.size.y)
	var limit := top * ground_ratio
	var out := AABB()
	var first_out := true
	for box in boxes:
		if box.position.y > limit:
			continue
		for i in range(8):
			var pt2: Vector3 = box.get_endpoint(i)
			if first_out:
				out = AABB(pt2, Vector3.ZERO); first_out = false
			else:
				out = out.expand(pt2)
	return out


func _world_aabb(cs: CollisionShape3D) -> AABB:
	var local := AABB()
	var s := cs.shape
	if s is CylinderShape3D:
		var c := s as CylinderShape3D
		local = AABB(Vector3(-c.radius, -c.height * 0.5, -c.radius), Vector3(c.radius * 2, c.height, c.radius * 2))
	elif s is BoxShape3D:
		var b := s as BoxShape3D
		local = AABB(-b.size * 0.5, b.size)
	elif s is CapsuleShape3D:
		var cap := s as CapsuleShape3D
		local = AABB(Vector3(-cap.radius, -cap.height * 0.5, -cap.radius), Vector3(cap.radius * 2, cap.height, cap.radius * 2))
	elif s is SphereShape3D:
		var sp := s as SphereShape3D
		local = AABB(Vector3.ONE * -sp.radius, Vector3.ONE * sp.radius * 2.0)
	else:
		return AABB()
	var xf: Transform3D = cs.global_transform
	var out := AABB()
	var first := true
	for i in range(8):
		var pt: Vector3 = xf * local.get_endpoint(i)
		if first:
			out = AABB(pt, Vector3.ZERO); first = false
		else:
			out = out.expand(pt)
	return out
