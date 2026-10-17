extends Node

## 两辆坦克相向开进。权威碰撞看平面距离是否始终不小于碰撞半径之和，并且两辆都移动了。
## 随后一辆对另一辆强制攻击，看血量是否下降。证据由启动命令重定向。

const MAP_SCENE := "res://source/match/maps/PlainAndSimple.tscn"
const A_AT := Vector3(200.0, 0.0, 180.0)
const B_AT := Vector3(200.0, 0.0, 196.0)

var _m: Node = null
var _player: Node = null


func _ready() -> void:
	get_tree().create_timer(240.0).timeout.connect(func() -> void:
		push_error("[TANK] 超时兜底退出")
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
	for _f in range(200):
		await get_tree().physics_frame
	_player = _m.get_node("Players").get_children()[0]
	var terrain: Node = _m.map.find_child("Terrain", true, false)
	print("[TANK] logic=", Utils.Match.is_logic_terrain_map(_m.map),
		" cell=", terrain.call("ground_path_cell_meters") if terrain != null and terrain.has_method("ground_path_cell_meters") else -1)
	var passed := await _drive()
	print("[TANK] probe done pass=%s" % str(passed))
	get_tree().quit(0 if passed else 1)


func _spawn(at: Vector3) -> Node3D:
	var unit: Node3D = (load("res://source/match/units/Tank.tscn") as PackedScene).instantiate()
	_m.call("_setup_and_spawn_unit", unit, Transform3D(Basis.IDENTITY, at), _player, false)
	return unit


func _drive() -> bool:
	var tank_a := _spawn(A_AT)
	var tank_b := _spawn(B_AT)
	for _f in range(90):
		await get_tree().physics_frame
	var move_a: Node = tank_a.find_child("Movement", true, false)
	var move_b: Node = tank_b.find_child("Movement", true, false)
	var r_a := float(move_a.call("ground_combat_collision_radius"))
	var r_b := float(move_b.call("ground_combat_collision_radius"))
	var start_a := tank_a.global_position
	var start_b := tank_b.global_position
	var start_dist := Vector2(start_a.x - start_b.x, start_a.z - start_b.z).length()
	print("[TANK] start_a=(%.3f,%.3f) start_b=(%.3f,%.3f) start_dist=%.3f r_a=%.3f r_b=%.3f sum=%.3f attack_range=%s" % [
		start_a.x, start_a.z, start_b.x, start_b.z, start_dist, r_a, r_b, r_a + r_b,
		str(tank_a.get("attack_range") != null)])
	move_a.call("move", start_b)
	move_b.call("move", start_a)
	var min_dist := start_dist
	var min_frame := 0
	var samples: PackedStringArray = PackedStringArray()
	for frame in range(700):
		await get_tree().physics_frame
		var pa := tank_a.global_position
		var pb := tank_b.global_position
		var dist := Vector2(pa.x - pb.x, pa.z - pb.z).length()
		if dist < min_dist:
			min_dist = dist
			min_frame = frame
		if frame % 30 == 0:
			samples.append("%d:%.3f" % [frame, dist])
	var end_a := tank_a.global_position
	var end_b := tank_b.global_position
	var travel_a := Vector2(end_a.x - start_a.x, end_a.z - start_a.z).length()
	var travel_b := Vector2(end_b.x - start_b.x, end_b.z - start_b.z).length()
	var end_dist := Vector2(end_a.x - end_b.x, end_a.z - end_b.z).length()
	var sum_r := r_a + r_b
	var separated := r_a > 0.05 and r_b > 0.05 and min_dist + 0.02 >= sum_r
	var moved := travel_a > 1.0 and travel_b > 1.0
	print("[TANK] end_a=(%.3f,%.3f) end_b=(%.3f,%.3f) end_dist=%.3f min_dist=%.3f at_frame=%d travel_a=%.3f travel_b=%.3f blocks=%s/%s" % [
		end_a.x, end_a.z, end_b.x, end_b.z, end_dist, min_dist, min_frame, travel_a, travel_b,
		str(move_a.get("ground_combat_blocks")), str(move_b.get("ground_combat_blocks"))])
	print("[TANK] samples %s" % " ".join(samples))
	var hp_before := float(tank_b.hp) if is_instance_valid(tank_b) else -1.0
	var attack_ok := false
	if is_instance_valid(tank_a) and is_instance_valid(tank_b):
		attack_ok = bool(tank_a.call("request_legacy_force_attack", tank_b))
	for _f in range(240):
		await get_tree().physics_frame
		if not is_instance_valid(tank_b):
			break
	var alive := is_instance_valid(tank_b)
	var hp_after := float(tank_b.hp) if alive else 0.0
	var attacked := attack_ok and ((not alive and hp_before > 0.0) or hp_after < hp_before - 0.01)
	print("[TANK] attack accepted=%s hp %.3f -> %.3f attacked=%s" % [str(attack_ok), hp_before, hp_after, str(attacked)])
	var passed := separated and moved
	print("[TANK] result pass=%s separated=%s moved=%s attacked=%s" % [str(passed), str(separated), str(moved), str(attacked)])
	return passed
