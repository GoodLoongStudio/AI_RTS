extends Node

## 电脑玩家建筑重叠检测（2026-09-23 用户报"敌方电脑会造重叠建筑"）。
##
## 开一局 人 vs N 电脑 对局，周期性 dump 每个玩家的全部建筑位置，
## 检测同一玩家任意两座建筑的平面距离是否小于 (半径和 × 0.9)——
## 小于即重叠（合法放置的间距至少是半径和 + 余量）。
##
## 用法：
##   godot --headless --path <AI_RTS> res://tests/automated/AiOverlapBuildCheck.tscn \
##     -- --seconds=180 [--ai=3]

const MatchSettings = preload("res://source/data-model/MatchSettings.gd")
const CHECK_INTERVAL := 5.0

var _seconds := 180.0
var _ai_count := 3
var _overlap_reports := 0
var _checks := 0


func _ready():
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--seconds="):
			_seconds = maxf(30.0, float(argument.substr("--seconds=".length())))
		elif argument.begins_with("--ai="):
			_ai_count = clampi(int(argument.substr("--ai=".length())), 1, 3)
	await get_tree().process_frame
	await get_tree().process_frame
	await _run()
	print("AI overlap build check completed: %d overlap report(s) over %d checks"
		% [_overlap_reports, _checks])
	get_tree().quit(1 if _overlap_reports > 0 else 0)


func _run() -> void:
	var settings = MatchSettings.new()
	var colors := [Color.BLUE, Color.RED, Color.GREEN, Color.YELLOW]
	var ps = load("res://source/data-model/PlayerSettings.gd").new()
	ps.controller = Constants.PlayerType.HUMAN
	ps.color = colors[0]
	settings.players.append(ps)
	for i in range(_ai_count):
		var ai = load("res://source/data-model/PlayerSettings.gd").new()
		ai.controller = Constants.PlayerType.SIMPLE_CLAIRVOYANT_AI
		ai.color = colors[i + 1]
		settings.players.append(ai)
	settings.visible_player = 0
	settings.visibility = MatchSettings.Visibility.FULL

	var a_match = load("res://source/match/Match.tscn").instantiate()
	a_match.settings = settings
	a_match.map = load("res://source/match/maps/PlainAndSimple.tscn").instantiate()
	get_tree().root.add_child(a_match)
	get_tree().current_scene = a_match

	# 等对局就绪
	var deadline := Time.get_ticks_msec() + 120000
	while Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
		var players = a_match.get_node_or_null("Players")
		if players != null and players.get_child_count() >= 1 + _ai_count:
			var ready := true
			for p in players.get_children():
				if p.get_child_count() == 0:
					ready = false
			if ready:
				break

	var elapsed := 0.0
	while elapsed < _seconds:
		await get_tree().create_timer(CHECK_INTERVAL).timeout
		elapsed += CHECK_INTERVAL
		_check_overlaps(a_match, elapsed)


func _check_overlaps(a_match: Node, elapsed: float) -> void:
	var players = a_match.get_node_or_null("Players")
	if players == null:
		return
	for player in players.get_children():
		if not (player is Node3D):
			continue
		var structures: Array = []
		for unit in player.get_children():
			if not (unit is Node3D) or not unit.is_in_group("units"):
				continue
			if unit.find_child("MovementObstacle", false, false) == null:
				continue
			var radius: float = float(unit.get("radius"))
			structures.append({
				"name": str(unit.name),
				"type": str(unit.get("unit_type_id")),
				"pos": Vector2((unit as Node3D).global_position.x, (unit as Node3D).global_position.z),
				"radius": radius,
			})
		for i in range(structures.size()):
			for j in range(i + 1, structures.size()):
				var a: Dictionary = structures[i]
				var b: Dictionary = structures[j]
				var distance: float = (a["pos"] as Vector2).distance_to(b["pos"] as Vector2)
				var min_distance: float = (float(a["radius"]) + float(b["radius"])) * 0.9
				if distance < min_distance:
					_overlap_reports += 1
					print("[OVERLAP] t=%.0f player=%s %s(%s,r=%.1f) @ (%.1f,%.1f) <-> %s(%s,r=%.1f) @ (%.1f,%.1f) d=%.2f < %.2f" % [
						elapsed, player.name,
						a["name"], a["type"], float(a["radius"]),
						(a["pos"] as Vector2).x, (a["pos"] as Vector2).y,
						b["name"], b["type"], float(b["radius"]),
						(b["pos"] as Vector2).x, (b["pos"] as Vector2).y,
						distance, min_distance])
		_checks += 1
		if structures.size() > 0 and elapsed <= 10.0:
			print("[AIOVL] t=%.0f player=%s structures=%d" % [elapsed, player.name, structures.size()])
