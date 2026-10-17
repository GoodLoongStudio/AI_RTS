extends Node

## 实测探针：真实建筑 + 真实地形 navmesh 重烘后，沿 72 个方向从碰撞表面往外走，
## 找到第一个落在可走面上的点，记录"洞边离碰撞表面的距离"。
## 用来确定 STRUCTURE_CARVE_MARGIN_M：洞边最小值须 ≥ 矿车推出层表面距离（≈1.21m）。
## 环境变量：AIRTS_CARVE_MARGIN（米，空=场景默认）、AIRTS_CARVE_BOUNDS（1/0，空=场景默认，只作用于方盒建筑）、
## AIRTS_CARVE_OFFSET（整体平移 x=v、z=v/2，测体素对齐的影响）、AIRTS_CARVE_TAG。

const MAP_SCENE := "res://source/match/maps/PlainAndSimple.tscn"
const WORKER_STAND_OFF_M := 1.21
const LAYOUT := [
	["CommandCenter", Vector3(40.0, 0.0, 40.0), 0.0],
	["OreRefinery", Vector3(80.0, 0.0, 40.0), 0.0],
	["OreRefinery", Vector3(120.0, 0.0, 40.0), 45.0],
	["Barracks", Vector3(160.0, 0.0, 40.0), 0.0],
	["VehicleFactory", Vector3(40.0, 0.0, 170.0), 0.0],
	["AircraftFactory", Vector3(80.0, 0.0, 170.0), 90.0],
	["MachineGunTurret", Vector3(120.0, 0.0, 170.0), 0.0],
	["AntiAirTurret", Vector3(160.0, 0.0, 170.0), 0.0],
]

var _m: Node = null


func _ready():
	get_tree().create_timer(120.0).timeout.connect(func() -> void:
		push_error("[CARVE] 超时兜底退出")
		get_tree().quit(2))
	var settings = load("res://source/data-model/MatchSettings.gd").new()
	var hs = load("res://source/data-model/PlayerSettings.gd").new()
	hs.controller = Constants.PlayerType.HUMAN
	hs.color = Constants.Player.COLORS[0]
	settings.players.append(hs)
	settings.visible_player = 0
	_m = load("res://source/match/Match.tscn").instantiate()
	_m.settings = settings
	_m.map = load(MAP_SCENE).instantiate()
	add_child(_m)
	get_tree().current_scene = _m
	for _f in range(160):
		await get_tree().physics_frame
	var player: Node = _m.get_node("Players").get_children()[0]
	for resource in get_tree().get_nodes_in_group("resource_units"):
		resource.queue_free()
	var margin_raw := OS.get_environment("AIRTS_CARVE_MARGIN").strip_edges()
	var bounds_raw := OS.get_environment("AIRTS_CARVE_BOUNDS").strip_edges()
	var offset_raw := OS.get_environment("AIRTS_CARVE_OFFSET").strip_edges()
	var offset := Vector3(float(offset_raw), 0.0, float(offset_raw) * 0.5) if not offset_raw.is_empty() else Vector3.ZERO
	var spawned: Array = []
	for row in LAYOUT:
		var unit: Node3D = (load("res://source/match/units/%s.tscn" % row[0]) as PackedScene).instantiate()
		var obstacle: Node = unit.find_child("MovementObstacle", true, false)
		if not margin_raw.is_empty():
			obstacle.set("carve_margin_m", float(margin_raw))
		if not bounds_raw.is_empty() and str(row[0]).find("Turret") < 0 and row[0] != "CommandCenter":
			obstacle.set("carve_from_collision_bounds", bounds_raw == "1")
		var basis := Basis(Vector3.UP, deg_to_rad(float(row[2])))
		_m.call("_setup_and_spawn_unit", unit, Transform3D(basis, row[1] + offset), player, false)
		spawned.append([row, unit])
	for _f in range(300):
		await get_tree().physics_frame
	var map_rid: RID = _m.navigation.get_navigation_map_rid_by_domain(Constants.Match.Navigation.Domain.TERRAIN)
	var report := {"schema": "structure-carve-edge/v1", "margin_override": margin_raw,
		"bounds_override": bounds_raw, "worker_stand_off_m": WORKER_STAND_OFF_M, "buildings": []}
	var worst := INF
	for entry in spawned:
		var row: Array = entry[0]
		var unit: Node3D = entry[1]
		var shape_node: CollisionShape3D = unit.find_child("CollisionShape3D", false, false)
		var obstacle: Node = unit.find_child("MovementObstacle", true, false)
		var edges: Array = []
		var below := 0
		for step in 72:
			var angle := TAU * float(step) / 72.0
			var dir := Vector3(cos(angle), 0.0, sin(angle))
			var support := _support(shape_node, dir)
			var found := -1.0
			var d := 0.0
			while d <= 4.0:
				var p: Vector3 = unit.global_position + dir * (support + d)
				var closest := NavigationServer3D.map_get_closest_point(map_rid, p + Vector3.UP)
				if Vector2(closest.x - p.x, closest.z - p.z).length() < 0.06:
					found = d
					break
				d += 0.05
			edges.append(found)
			if found >= 0.0 and found < WORKER_STAND_OFF_M:
				below += 1
		var valid := edges.filter(func(v): return v >= 0.0)
		var lo := INF
		var hi := -INF
		var total := 0.0
		for v in valid:
			lo = minf(lo, v)
			hi = maxf(hi, v)
			total += v
		var mean := total / maxf(float(valid.size()), 1.0)
		worst = minf(worst, lo)
		var item := {"scene": row[0], "yaw_deg": row[2],
			"margin": obstacle.get("carve_margin_m"), "from_bounds": obstacle.get("carve_from_collision_bounds"),
			"avoidance_enabled": obstacle.get("avoidance_enabled"),
			"edge_min_m": lo, "edge_mean_m": mean, "edge_max_m": hi,
			"directions_below_stand_off": below, "directions_no_edge": 72 - valid.size()}
		report["buildings"].append(item)
		print("[CARVE] %s yaw=%d margin=%s bounds=%s avoid=%s 洞边离表面 min=%.2f mean=%.2f max=%.2f <1.21 的方向=%d/72" % [
			row[0], int(row[2]), str(item["margin"]), str(item["from_bounds"]), str(item["avoidance_enabled"]),
			lo, mean, hi, below])
	report["worst_edge_min_m"] = worst
	print("[CARVE] 全部建筑洞边最小值=%.2f（矿车推出层要求 %.2f）" % [worst, WORKER_STAND_OFF_M])
	var tag := OS.get_environment("AIRTS_CARVE_TAG").strip_edges()
	var out_path := "res://agent/runs/nav-clearance/carve-%s.json" % ("run" if tag.is_empty() else tag)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://agent/runs/nav-clearance"))
	var f := FileAccess.open(out_path, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(report, "  "))
		f.close()
	print("[CARVE] 写入 %s" % out_path)
	get_tree().quit(0)


func _support(shape_node: CollisionShape3D, dir: Vector3) -> float:
	var shape := shape_node.shape
	if shape is BoxShape3D:
		var half: Vector3 = (shape as BoxShape3D).size * 0.5
		var local: Vector3 = shape_node.global_transform.basis.inverse() * dir
		var t := INF
		if absf(local.x) > 0.0001:
			t = minf(t, half.x / absf(local.x))
		if absf(local.z) > 0.0001:
			t = minf(t, half.z / absf(local.z))
		return t
	if shape is CylinderShape3D:
		return (shape as CylinderShape3D).radius
	return 0.0
