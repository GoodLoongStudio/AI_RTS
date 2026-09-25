extends Node

## 生成图寻路监控（无头运行）：开一局 4 人对局，周期性 dump
## 工人采集 / 卡住 / 过桥 / 导航路径状态，用来定位"工人采矿寻路"和"过桥寻路"问题。
## 运行：Godot --headless --path <repo> res://tests/automated/GeneratedPathMonitorTest.tscn [map_scene]

const MAPS := {
	"47-0": "res://source/match/maps/generated/47-0/map_47-0.tscn",
	"49": "res://source/match/maps/generated/49-1376088014/map_49-1376088014.tscn",
	"35-0": "res://source/match/maps/generated/35-0/map_35-0.tscn",
	"16-0": "res://source/match/maps/generated/16-0/map_16-0.tscn",
}

const MatchSettings = preload("res://source/data-model/MatchSettings.gd")

const MONITOR_SECONDS := 150.0
const SAMPLE_INTERVAL := 5.0

var _failures := 0


func _ready():
	var args := OS.get_cmdline_user_args()
	var key := "47-0"
	for a in args:
		if MAPS.has(a):
			key = a
	var map_path: String = MAPS.get(key, MAPS["47-0"])
	print("[MON] map=", map_path)
	await get_tree().process_frame
	await get_tree().process_frame
	await _run(map_path)
	print("Generated path monitor completed: 0 failure(s)")
	get_tree().quit(0)


func _run(map_path: String) -> void:
	var settings = MatchSettings.new()
	var colors := [Color.BLUE, Color.RED, Color.GREEN, Color.YELLOW]
	for i in range(4):
		var ps = load("res://source/data-model/PlayerSettings.gd").new()
		ps.controller = Constants.PlayerType.HUMAN if i == 0 else Constants.PlayerType.SIMPLE_CLAIRVOYANT_AI
		ps.color = colors[i]
		settings.players.append(ps)
	settings.visible_player = 0
	settings.visibility = MatchSettings.Visibility.FULL

	var map_instance = load(map_path).instantiate()
	var a_match = load("res://source/match/Match.tscn").instantiate()
	a_match.settings = settings
	a_match.map = map_instance
	get_tree().root.add_child(a_match)

	var terrain = a_match.get_node_or_null("Map/Geometry/Terrain")
	var occupancy = a_match.map.get_meta("water_occupancy", null) if a_match.map.has_meta("water_occupancy") else null
	print("[MON] occupancy=", occupancy, " bridges=", _bridge_count(occupancy))

	# 等对局就绪（玩家 + 单位 + 导航）
	var players_ready := false
	var deadline := Time.get_ticks_msec() + 120000
	while not players_ready and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
		var players = a_match.get_node_or_null("Players")
		if players != null and players.get_child_count() >= 4:
			var ok := true
			for p in players.get_children():
				if p.get_child_count() == 0:
					ok = false
			players_ready = ok
	print("[MON] players_ready=", players_ready)
	if not players_ready:
		return

	# 监控循环
	var elapsed := 0.0
	var sample := 0
	while elapsed < MONITOR_SECONDS:
		await get_tree().create_timer(SAMPLE_INTERVAL).timeout
		elapsed += SAMPLE_INTERVAL
		sample += 1
		_dump(a_match, terrain, occupancy, sample, elapsed)
		if is_instance_valid(_trace_unit):
			var mv = _trace_unit.find_child("Movement", false, false)
			var ct = mv.get("_committed_target") if mv != null else null
			var vel: float = float(mv.get("velocity").length()) if mv != null and "velocity" in mv else -1.0
			if ct == null or vel > 0.05:
				_trace_unit = null
				_trace_frames = 0
				print("[TRACE] untrack (moved or idle)")


var _trace_unit: Node3D = null
var _trace_frames := 0
var _trace_last_action := ""
var _pos_history := {}  # unit_name -> [pos, elapsed]


func _real_stuck(unit: Node3D, elapsed: float) -> bool:
	var key := unit.name
	var prev = _pos_history.get(key)
	_pos_history[key] = [unit.global_position, elapsed]
	if prev == null:
		return false
	if elapsed - prev[1] < 10.0:
		return false
	return unit.global_position.distance_to(prev[0]) < 0.5


func _on_trace_action_changed(new_action) -> void:
	if not is_instance_valid(_trace_unit):
		return
	var name_now := "null"
	if new_action != null and new_action.get_script() != null:
		name_now = new_action.get_script().resource_path.get_file()
		var tu = new_action.get("_target_unit")
		if tu != null and is_instance_valid(tu):
			name_now += " site=" + _planar(tu.global_position)
	var movement = _trace_unit.find_child("Movement", false, false)
	var committed = movement.get("_committed_target") if movement != null else null
	print("[TRACE][act] %s -> %s (committed=%s)" % [_trace_last_action, name_now, _planar(committed)])
	_trace_last_action = name_now


func _physics_process(_delta):
	_trace_worker()



func _trace_worker() -> void:
	if not is_instance_valid(_trace_unit):
		return
	var movement = _trace_unit.find_child("Movement", false, false)
	if movement == null:
		return
	_trace_frames += 1
	if _trace_frames % 12 != 0:
		return
	var committed = movement.get("_committed_target")
	var path = movement.get("_logic_path")
	var i := int(movement.get("_logic_path_i"))
	var seek: Vector3 = movement.call("_logic_current_seek")
	var pending: bool = movement.get("_logic_path_pending")
	var cd: float = movement.get("_logic_repath_cd")
	var from: Vector3 = _trace_unit.global_position
	var remain: float = Vector2(seek.x - from.x, seek.z - from.z).length()
	print("[TRACE] f=%d pos=(%.2f,%.2f) committed=%s pathN=%d i=%d seek=(%.1f,%.1f) remain=%.2f pending=%s cd=%.2f speed=%.2f phys=%s" % [
		_trace_frames, from.x, from.z,
		_planar(committed), path.size(), i, seek.x, seek.z, remain,
		str(pending), cd, float(movement.get("speed")), str(movement.is_physics_processing())])


func _dump(a_match: Node, terrain: Node, occupancy, sample: int, elapsed: float) -> void:
	var units_node = a_match.get_node_or_null("Units")
	if units_node == null:
		return
	var workers_total := 0
	var workers_gathering := 0
	var workers_stuck := 0
	var stuck_detail: Array = []
	var on_water := 0
	var far_from_home := 0
	for player in a_match.get_node("Players").get_children():
		if not (player is Node3D):
			continue
		for unit in player.get_children():
			if not (unit is Node3D) or not unit.is_in_group("units"):
				continue
			var type := str(unit.get("unit_type_id"))
			if type != "worker":
				continue
			workers_total += 1
			var action = unit.get("action")
			var action_name := str(action.get_script().resource_path.get_file()) if action != null and action.get_script() != null else "null"
			if action_name.begins_with("Collecting") or action_name.begins_with("AutoGathering"):
				workers_gathering += 1
			var movement = unit.find_child("Movement", false, false)
			var committed = movement.get("_committed_target") if movement != null else null
			var pos: Vector3 = unit.global_position
			# 卡住判据：有目标但速度≈0
			var velocity: float = float(movement.get("velocity").length()) if movement != null and "velocity" in movement else -1.0
			var stalls: int = int(movement.get("_stall_windows")) if movement != null else 0
			var recovery := str(movement.get("_recovery_mode")) if movement != null else ""
			if committed != null and velocity < 0.05 and _real_stuck(unit, elapsed):
				workers_stuck += 1
				if not is_instance_valid(_trace_unit):
					_trace_unit = unit
					_trace_frames = 0
					_trace_last_action = ""
					unit.action_changed.connect(_on_trace_action_changed)
					print("[TRACE] tracking ", unit.name)
				if stuck_detail.size() < 10:
					var dist: float = Vector2(pos.x, pos.z).distance_to(Vector2(committed.x, committed.z))
					var path_size: int = int(movement.get("_logic_path").size()) if movement != null else -1
					var logic_stuck: int = int(movement.get("_logic_stuck")) if movement != null else -1
					var here_blocked := false
					var there_blocked := false
					if occupancy != null and occupancy.has_method("is_ground_blocked"):
						here_blocked = occupancy.is_ground_blocked(pos)
						there_blocked = occupancy.is_ground_blocked(committed)
					var seek: Vector3 = Vector3.ZERO
					if movement != null and movement.has_method("_logic_current_seek"):
						seek = movement.call("_logic_current_seek")
					var sub := "?"
					var adhere := "?"
					if action != null:
						var sub_node = action.get("_sub_action")
						if sub_node != null and sub_node.get_script() != null:
							sub = sub_node.get_script().resource_path.get_file()
						var tu = action.get("_target_unit")
						if tu != null and is_instance_valid(tu):
							var d_site: float = Vector2(pos.x, pos.z).distance_to(Vector2(tu.global_position.x, tu.global_position.z))
							var thr: float = float(unit.get("radius")) + float(tu.get("radius")) + 0.5
							adhere = "d=%.2f thr=%.2f %s site=%s r=%.1f wr=%.1f" % [
								d_site, thr, str(Utils.Match.Unit.Movement.units_adhere(unit, tu)),
								_planar(tu.global_position), float(tu.get("radius")), float(unit.get("radius"))]
					stuck_detail.append("%s(%s/%s) pos=%s tgt=%s d=%.1f path=%d adhere=%s seek=%s" % [
						unit.name, action_name, sub, _planar(pos), _planar(committed), dist,
						path_size, adhere, _planar(seek)])
			# 是否站在禁行格（水/崖）上
			if occupancy != null and occupancy.has_method("is_ground_blocked") and occupancy.is_ground_blocked(pos):
				on_water += 1
			# 离基地距离
			var base: Vector3 = _base_anchor(a_match, player)
			if base != Vector3.INF and Vector2(pos.x, pos.z).distance_to(Vector2(base.x, base.z)) > 60.0:
				far_from_home += 1
	print("[MON] t=%.0fs #%d workers=%d gathering=%d stuck=%d on_blocked=%d far=%d" % [
		elapsed, sample, workers_total, workers_gathering, workers_stuck, on_water, far_from_home])
	for d in stuck_detail:
		print("[MON][stuck] ", d)


func _planar(v) -> String:
	if v is Vector3:
		return "(%.1f,%.1f)" % [v.x, v.z]
	return "null"


func _base_anchor(a_match: Node, player: Node) -> Vector3:
	for unit in player.get_children():
		if str(unit.get("unit_type_id")) == "command_center":
			return unit.global_position
	return Vector3.INF


func _bridge_count(occupancy) -> int:
	if occupancy != null and occupancy.has_method("_bridge_rects"):
		return occupancy._bridge_rects.size()
	return -1
