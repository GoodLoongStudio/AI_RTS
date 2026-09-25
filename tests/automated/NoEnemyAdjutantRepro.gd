extends Node

## 无敌人 G4 生成图 × AI 副官 复现监控（2026-09-22）。
##
## 用途：headless 开一局「只有一个真人玩家（无敌人）」的生成图对局，副官 runner
## 从进程外连 DCS 正常发展；本脚本周期性采样全部单位，检测「小兵/工人卡住」并
## 打印根因诊断（目标 / 寻路航点 / 禁行状态 / action / 建筑阻挡）。
##
## 运行：
##   godot --headless --path <AI_RTS> res://tests/automated/NoEnemyAdjutantRepro.tscn \
##     -- --debugport=24591 [map_key] [--seconds=600]
##
## 输出：每 10s 一行 [REPRO] 概要；发现卡住打 [STUCK] 明细（含逐帧 [TRACE]）。

const MAPS := {
	"47-0": "res://source/match/maps/generated/47-0/map_47-0.tscn",
	"49": "res://source/match/maps/generated/49-1376088014/map_49-1376088014.tscn",
	"35-0": "res://source/match/maps/generated/35-0/map_35-0.tscn",
	"16-0": "res://source/match/maps/generated/16-0/map_16-0.tscn",
	"51": "res://source/match/maps/generated/51-1540056157/map_51-1540056157.tscn",
	"55": "res://source/match/maps/generated/55-1521782457/map_55-1521782457.tscn",
	"49-rampfix": "res://source/match/maps/generated/49-1376088014-rampfix/map_49-1376088014-rampfix.tscn",
	"49-e6c": "res://source/match/maps/generated/49-1376088014-e6c10b27ba/map_49-1376088014-e6c10b27ba.tscn",
	"35-e6c": "res://source/match/maps/generated/35-0-e6c10b27ba/map_35-0-e6c10b27ba.tscn",
	"47-e6c": "res://source/match/maps/generated/47-0-12bf758c6e/map_47-0-12bf758c6e.tscn",
}

const MatchSettings = preload("res://source/data-model/MatchSettings.gd")
const SAMPLE_INTERVAL := 10.0
## 同单位两次采样位移小于此值且间隔超过 STUCK_WINDOW_S 才算卡住。
const STUCK_MOVE_EPS_M := 0.5
const STUCK_WINDOW_S := 20.0
## 振荡（伪推进）检测：窗口内路程足够长但净位移与到目标距离的改善都极小。
const OSC_WINDOW_S := 60.0
const OSC_MIN_PATH_M := 6.0
const OSC_MAX_NET_M := 2.5
const OSC_MIN_PROGRESS_M := 2.0

var _map_key := "49"
var _seconds := 600.0
var _stuck_history := {}  # unit_path -> [pos, elapsed]
var _stuck_reported := {}  # unit_path -> 最近一次已报告的 elapsed
var _osc_history := {}  # unit_path -> {samples: [[pos, elapsed, dist_to_target]], last_report}
var _trace_unit: Node3D = null
var _trace_frames := 0
var _occupancy = null
var _started_unix := 0.0
var _osc_reports := 0


func _ready():
	var args := OS.get_cmdline_user_args()
	for a in args:
		if MAPS.has(a):
			_map_key = a
		elif a.begins_with("--seconds="):
			_seconds = maxf(30.0, float(a.substr("--seconds=".length())))
	print("[REPRO] map_key=", _map_key, " seconds=", _seconds)
	await get_tree().process_frame
	await get_tree().process_frame
	await _run(MAPS.get(_map_key, MAPS["49"]))


func _run(map_path: String) -> void:
	var settings = MatchSettings.new()
	var ps = load("res://source/data-model/PlayerSettings.gd").new()
	ps.controller = Constants.PlayerType.HUMAN
	ps.color = Color.BLUE
	settings.players.append(ps)
	settings.visible_player = 0
	settings.visibility = MatchSettings.Visibility.FULL

	var map_instance = load(map_path).instantiate()
	var a_match = load("res://source/match/Match.tscn").instantiate()
	# 无敌人房间：只有一个玩家时 LastSurvivingSide 会立刻判胜收场，摘掉终局处理器。
	var end_handler = a_match.find_child("MatchEndHandler")
	if end_handler != null:
		end_handler.queue_free()
	a_match.settings = settings
	a_match.map = map_instance
	get_tree().root.add_child(a_match)
	# DCS 的 status/tactical/adjutant_command 都以 tree.current_scene 为对局节点；
	# 副官 runner 从进程外连进来，没有 current_scene 就永远 status.match=false。
	get_tree().current_scene = a_match

	# 等对局就绪（玩家 + 单位 + 占用格）。
	var ready := false
	var deadline := Time.get_ticks_msec() + 180000
	while not ready and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
		var players = a_match.get_node_or_null("Players")
		if players != null and players.get_child_count() >= 1:
			for p in players.get_children():
				if p.get_child_count() > 0:
					ready = true
	# 地形 GridMap/占用格在 Match 就绪后建立，多等几帧。
	for _i in range(120):
		await get_tree().process_frame
	_occupancy = a_match.map.get_meta("water_occupancy", null) if a_match.map.has_meta("water_occupancy") else null
	print("[REPRO] players_ready=", ready, " occupancy=", _occupancy,
		" bridges=", _bridge_count(_occupancy),
		" units=", get_tree().get_nodes_in_group("units").size())

	_started_unix = Time.get_unix_time_from_system()
	var elapsed := 0.0
	var sample := 0
	while elapsed < _seconds:
		await get_tree().create_timer(SAMPLE_INTERVAL).timeout
		elapsed += SAMPLE_INTERVAL
		sample += 1
		_dump(a_match, sample, elapsed)
	print("[REPRO] completed seconds=", elapsed, " (map=", _map_key, ")")
	get_tree().quit(0)


func _bridge_count(occupancy) -> int:
	if occupancy == null or not occupancy.has_method("_sample_bridge_deck"):
		return -1
	return int(occupancy.get("_bridge_rects").size())


func _planar(v) -> String:
	if v == null:
		return "null"
	return "(%.2f, %.2f)" % [float(v.x), float(v.z)]


func _unit_action_name(unit: Node) -> String:
	var action = unit.get("action")
	if action != null and action.get_script() != null:
		return str(action.get_script().resource_path.get_file())
	return "null"


func _dump(a_match: Node, sample: int, elapsed: float) -> void:
	var total := 0
	var workers := 0
	var soldiers := 0
	var stuck_now: Array = []
	var osc_now := 0
	for player in a_match.get_node_or_null("Players").get_children():
		if not (player is Node3D):
			continue
		for unit in player.get_children():
			if not (unit is Node3D) or not unit.is_in_group("units"):
				continue
			total += 1
			var type := str(unit.get("unit_type_id"))
			if type == "worker":
				workers += 1
			elif type in ["soldier", "tank", "rocketeer", "heavy_tank", "apc"]:
				soldiers += 1
			var movement = unit.find_child("Movement", false, false)
			if movement == null:
				continue
			var committed = movement.get("_committed_target")
			var velocity: float = float(movement.get("velocity").length()) if "velocity" in movement else -1.0
			var key := str(unit.get_path())
			var pos: Vector3 = unit.global_position
			# 保留一段采样历史，与 **STUCK_WINDOW_S 之前**的采样比。
			# （旧实现每轮覆盖成"上一拍"，elapsed - prev[1] 恒等于采样间隔，
			#   永远小于窗口阈值 → STUCK 一次都没报过，监控实际失效。）
			var hist: Array = _stuck_history.get(key, [])
			hist.append([pos, elapsed])
			while hist.size() > 2 and float(hist[0][1]) < elapsed - 40.0:
				hist.pop_front()
			_stuck_history[key] = hist
			# 振荡（伪推进）检测：一直在动、但既不接近目标也不脱困。
			var before := _osc_reports
			_note_oscillation(unit, movement, elapsed)
			osc_now += _osc_reports - before
			if committed == null:
				continue
			var reference: Variant = null
			for past in hist:
				if elapsed - float(past[1]) >= STUCK_WINDOW_S:
					reference = past
			if reference == null:
				continue
			if pos.distance_to(reference[0]) >= STUCK_MOVE_EPS_M:
				continue
			if velocity > 0.05:
				continue
			# 卡住：有任务目标、长时间零位移、零速度。
			var last_report: float = float(_stuck_reported.get(key, -1e9))
			if elapsed - last_report < STUCK_WINDOW_S:
				continue
			_stuck_reported[key] = elapsed
			stuck_now.append(unit)
			print("[STUCK] ", unit.name, "(", type, "/", _unit_action_name(unit), ") pos=",
				_planar(pos), " committed=", _planar(committed),
				" path=", int(movement.get("_logic_path").size()) if "_logic_path" in movement else -1,
				" blocked_here=", _is_blocked(pos),
				" blocked_target=", _is_blocked(committed),
				" phys=", str(movement.is_physics_processing()),
				" elapsed=", elapsed)
			if not is_instance_valid(_trace_unit):
				_trace_unit = unit
				_trace_frames = 0
				print("[TRACE] tracking ", unit.name, " action=", _unit_action_name(unit))
			var unit_action = unit.get("action")
			if unit_action != null:
				var sub = unit_action.get("_sub_action")
				if sub != null and sub.get_script() != null:
					print("[TRACE] sub_action=", sub.get_script().resource_path.get_file())
				var tu = unit_action.get("_target_unit")
				if tu != null and is_instance_valid(tu):
					var d: float = Vector2(pos.x, pos.z).distance_to(Vector2(tu.global_position.x, tu.global_position.z))
					print("[TRACE] target_unit=", tu.name, " dist=", "%.2f" % d,
						" site=", _planar(tu.global_position))
	_print_ui_state(elapsed)
	if stuck_now.is_empty():
		print("[REPRO] t=%.0fs units=%d workers=%d soldiers=%d stuck=0 osc=%d %s" % [elapsed, total, workers, soldiers, osc_now, _compact_positions(a_match)])
	else:
		print("[REPRO] t=%.0fs units=%d workers=%d soldiers=%d stuck=%d osc=%d (%s) %s" % [
			elapsed, total, workers, soldiers, stuck_now.size(), osc_now,
			",".join(stuck_now.map(func(u): return str(u.name))), _compact_positions(a_match)])


func _is_blocked(pos) -> bool:
	if pos == null:
		return false
	if _occupancy != null and _occupancy.has_method("is_ground_blocked"):
		return bool(_occupancy.is_ground_blocked(pos))
	return false


## 振荡（伪推进）检测：单位**在动**（零位移检测抓不到），但一个 OSC_WINDOW_S
## 窗口内走了很长的路、净位移和到目标的接近量都极小 —— 就是用户说的"卡住"：
## 贴着障碍/目标外围一直绕，既不到达也不脱困。
func _note_oscillation(unit: Node, movement: Node, elapsed: float) -> void:
	var committed = movement.get("_committed_target")
	if committed == null:
		_osc_history.erase(str(unit.get_path()))
		return
	var key := str(unit.get_path())
	var pos: Vector3 = unit.global_position
	var dist := Vector2(pos.x, pos.z).distance_to(Vector2(committed.x, committed.z))
	var entry: Dictionary = _osc_history.get(key, {})
	var samples: Array = entry.get("samples", [])
	# 目标换了就重新开窗：单位被重新指派（前压逐格推进本来就每个航点换目标），
	# 跨目标算"净位移"没有意义（会把正常推进误报成振荡）。
	if not samples.is_empty():
		var last_target: Vector3 = samples[samples.size() - 1][3]
		if last_target.distance_to(committed) > 1.0:
			samples.clear()
	samples.append([pos, elapsed, dist, committed])
	while samples.size() > 2 and float(samples[0][1]) < elapsed - OSC_WINDOW_S - SAMPLE_INTERVAL:
		samples.pop_front()
	entry["samples"] = samples
	var last_report: float = float(entry.get("last_report", -1e9))
	if elapsed - last_report < OSC_WINDOW_S:
		_osc_history[key] = entry
		return
	if samples.size() < 6:
		_osc_history[key] = entry
		return
	var path_len := 0.0
	for i in range(samples.size() - 1):
		path_len += samples[i][0].distance_to(samples[i + 1][0])
	var first_pos: Vector3 = samples[0][0]
	var last_pos: Vector3 = samples[samples.size() - 1][0]
	var net := first_pos.distance_to(last_pos)
	if path_len < OSC_MIN_PATH_M or net > OSC_MAX_NET_M:
		_osc_history[key] = entry
		return
	entry["last_report"] = elapsed
	_osc_history[key] = entry
	_osc_reports += 1
	print("[OSC] ", unit.name, "(", str(unit.get("unit_type_id")), "/", _unit_action_name(unit),
		") pos=", _planar(pos), " committed=", _planar(committed),
		" path_len=%.1fm net=%.1fm dist_now=%.1fm blocked_here=%s blocked_target=%s" % [
			path_len, net, dist,
			str(_is_blocked(pos)), str(_is_blocked(committed))])
	if not is_instance_valid(_trace_unit):
		_trace_unit = unit
		_trace_frames = 0
		print("[TRACE] tracking (osc) ", unit.name, " action=", _unit_action_name(unit))


## 副官 UI 三处状态元素快照（2026-09-23 用户截图：按钮"停止"/标题"尚未启动"/
## 正文"运行中"互相打脸）。每次采样打印真实文本，端到端验证一致性。
func _print_ui_state(elapsed: float) -> void:
	var adjutant := get_node_or_null("/root/AdjutantButton")
	if adjutant == null:
		return
	var button := "?"
	var title := "?"
	var body := "?"
	var hud := "?"
	if adjutant.get("_button") != null and is_instance_valid(adjutant._button):
		button = str(adjutant._button.text)
	if adjutant.get("_title_label") != null and is_instance_valid(adjutant._title_label):
		title = str(adjutant._title_label.text)
	if adjutant.get("_state_label") != null and is_instance_valid(adjutant._state_label):
		body = str(adjutant._state_label.text)
	var hud_node: Variant = adjutant.call("_find_agent_hud")
	if hud_node != null and hud_node.get("_agent_state") != null:
		hud = str(hud_node._agent_state.text)
	print("[UISTATE] t=%.0f button=%s | panel_title=%s | panel_body=%s | hud_title=%s" % [
		elapsed, button, title, body, hud])


## 紧凑位置快照：`Unit_1(12,34)` 列表，用来肉眼确认单位是否在推进。
func _compact_positions(a_match: Node) -> String:
	var parts: Array = []
	for player in a_match.get_node_or_null("Players").get_children():
		if not (player is Node3D):
			continue
		for unit in player.get_children():
			if not (unit is Node3D) or not unit.is_in_group("units"):
				continue
			var type := str(unit.get("unit_type_id"))
			if type == "command_center" or type == "":
				continue
			parts.append("%s(%.0f,%.0f)" % [unit.name, unit.global_position.x, unit.global_position.z])
	return "pos=[" + ",".join(parts) + "]"


func _physics_process(_delta):
	_trace_worker()
	_heartbeat()


## 模拟心跳：每 ~10s（600 物理帧）一行。进程活着但心跳停了 = 模拟冻结，
## 配合外部存活探测（DCS status）就能区分"挂死"与"正常退出"。
var _hb_frame := -1
func _heartbeat() -> void:
	var frame := Engine.get_physics_frames()
	if _hb_frame < 0:
		_hb_frame = frame
		return
	if frame - _hb_frame < 600:
		return
	_hb_frame = frame
	print("[HB] physics_frame=%d units=%d" % [frame, get_tree().get_nodes_in_group("units").size()])


func _trace_worker() -> void:
	if not is_instance_valid(_trace_unit):
		return
	var movement = _trace_unit.find_child("Movement", false, false)
	if movement == null:
		_trace_unit = null
		return
	_trace_frames += 1
	var committed = movement.get("_committed_target")
	var velocity: float = float(movement.get("velocity").length()) if "velocity" in movement else -1.0
	if committed == null or velocity > 0.05:
		if _trace_frames > 12:
			print("[TRACE] untrack (moved or idle) after ", _trace_frames, " frames")
		_trace_unit = null
		return
	if _trace_frames % 30 != 0:
		return
	var path = movement.get("_logic_path")
	var i := int(movement.get("_logic_path_i"))
	var seek: Vector3 = movement.call("_logic_current_seek")
	var from: Vector3 = _trace_unit.global_position
	var remain: float = Vector2(seek.x - from.x, seek.z - from.z).length()
	var skip_nav: Variant = movement.call("_skip_navigation_server") if movement.has_method("_skip_navigation_server") else "?"
	var move_radius: Variant = movement.get("radius")
	print("[TRACE] f=%d pos=(%.2f,%.2f) committed=%s pathN=%d i=%d seek=(%.1f,%.1f) remain=%.2f pending=%s cd=%.2f stuck=%d repaths=%d blocked=%s skip_nav=%s radius=%s" % [
		_trace_frames, from.x, from.z, _planar(committed), path.size(), i,
		seek.x, seek.z, remain,
		str(movement.get("_logic_path_pending")), float(movement.get("_logic_repath_cd")),
		int(movement.get("_logic_stuck")), int(movement.get("_logic_repath_attempts")),
		str(_is_blocked(from)), str(skip_nav), str(move_radius)])
