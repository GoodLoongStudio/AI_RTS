extends Node

## 真实布局人群交通探针（RSI round-01 Explorer ✓）
## 与压力型探针的**唯一区别**（为了可证伪地检验 H1 ✓）：
##   ① 建筑按**正常间距**铺开（3×3 网格、间距 16m ✓），不再紧贴成 r=9m 环 ✗；
##   ② 命令改为**玩家式**：每个单位先下一条 ✓，**到达/失败后**才下一条 ✓；
##      只有"卡住超过 20 秒"才像玩家一样重点一次（并计入 `reissued` ✓），不再每 2 秒重发 ✗。
## 其余口径与压力型探针完全一致 ✓，便于 before→candidate 比较 ✓。

const BUILDINGS := ["CommandCenter", "Barracks", "VehicleFactory", "AircraftFactory", "OreRefinery",
	"AntiGroundTurret", "AntiAirTurret", "MachineGunTurret"]
const UNITS := ["Tank", "Tank", "HeavyTank", "APC", "Worker", "Worker", "Scout", "Infantry", "Rocketeer", "Sniper"]
const UNIT_COUNT := 40
const STALL_S := 3.0
const LONG_STALL_S := 6.0
const RUN_SECONDS := 150.0
const REISSUE_AFTER_S := 20.0
const OUT_DIR_DEFAULT := "res://agent/runs/2026-10-02-crowd-realistic/"
# 【参数化 ✓】AIRTS_CROWD_LAYOUT=tight|grid ✓、AIRTS_CROWD_UNITS=n ✓、
# AIRTS_CROWD_MAP=res://…tscn ✓、AIRTS_CROWD_OUT=res://agent/runs/<dir>/ ✓（用于 RSI 各轮 ✓）
var _layout := OS.get_environment("AIRTS_CROWD_LAYOUT")
var _unit_count_override := OS.get_environment("AIRTS_CROWD_UNITS").to_int()
var _map_path := OS.get_environment("AIRTS_CROWD_MAP")
var OUT_DIR := OUT_DIR_DEFAULT

var _m: Node
var _human: Node
var _gateway: Node
var _units: Array = []
var _stall_events := 0
var _long_stalls := 0
var _max_stall := 0.0
var _reissued := 0
var _per_unit: Array = []
var _shots := 0
var _center := Vector3(120.0, 0.0, 120.0)


func _ready() -> void:
	# 暂停时普通节点连 _process 都不会被调用 ⇒ 必须 ALWAYS 才能解除暂停 ✓
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_process(true)
	get_tree().create_timer(400.0).timeout.connect(func() -> void:
		push_error("[REAL] 超时兜底退出")
		get_tree().quit(2))
	await _run()


## 【关键修正 2】窗口失焦时游戏会暂停场景树 ⇒ **任何** await physics_frame 都会永久挂住
## （暖机阶段也会 ✗）。因此在 _process 里**每帧**强制解除暂停 ⇒ 探针任何阶段都能推进 ✓。
func _process(_delta: float) -> void:
	if get_tree().paused:
		get_tree().paused = false


func _run() -> void:
	var settings = load("res://source/data-model/MatchSettings.gd").new()
	var hs = load("res://source/data-model/PlayerSettings.gd").new()
	hs.controller = Constants.PlayerType.HUMAN
	hs.color = Constants.Player.COLORS[0]
	settings.players.append(hs)
	settings.visible_player = 0
	if _layout == "":
		_layout = "grid"
	if _unit_count_override <= 0:
		_unit_count_override = UNIT_COUNT
	var out_env := OS.get_environment("AIRTS_CROWD_OUT")
	if out_env != "":
		OUT_DIR = out_env
	var map_path := _map_path if _map_path != "" else "res://source/match/maps/PlainAndSimple.tscn"
	_m = load("res://source/match/Match.tscn").instantiate()
	_m.settings = settings
	_m.map = load(map_path).instantiate()
	add_child(_m)
	get_tree().current_scene = _m
	for _f in range(160):
		await get_tree().physics_frame
	_human = _m.get_node("Players").get_children()[0]
	_gateway = _human.get_node("UnitCommandGateway")
	# ① 正常间距布局：3×3 网格、格距 16m（可通行的"街道" ✓）
	for i in range(BUILDINGS.size()):
		var pos: Vector3
		if _layout == "tight":
			var ang := TAU * float(i) / float(BUILDINGS.size())
			pos = _center + Vector3(cos(ang) * 9.0, 0.0, sin(ang) * 9.0)
		else:
			var gx := float(i % 3) - 1.0
			var gz := float(i / 3) - 1.0
			pos = _center + Vector3(gx * 16.0, 0.0, gz * 16.0)
		var b: Node3D = (load("res://source/match/units/" + BUILDINGS[i] + ".tscn") as PackedScene).instantiate()
		_m.call("_setup_and_spawn_unit", b, Transform3D(Basis.IDENTITY, pos), _human, false)
	for _f in range(90):
		await get_tree().physics_frame
	# ② 部队分布在外围
	for i in range(_unit_count_override):
		var ang := TAU * float(i) / float(_unit_count_override)
		var r := 34.0 + float(i % 3) * 3.0
		var pos := _center + Vector3(cos(ang) * r, 0.0, sin(ang) * r)
		var u: Node3D = (load("res://source/match/units/" + UNITS[i % UNITS.size()] + ".tscn") as PackedScene).instantiate()
		_m.call("_setup_and_spawn_unit", u, Transform3D(Basis.IDENTITY, pos), _human, false)
		_units.append({"node": u, "last_pos": Vector2(pos.x, pos.z), "stall_started": -1.0,
			"events": 0, "max_stall": 0.0, "order": "", "order_id": "", "last_order_t": 0.0, "done": false})
	for _f in range(120):
		await get_tree().physics_frame
	_hide_hud()
	var t0 := Time.get_ticks_msec()
	while float(Time.get_ticks_msec() - t0) / 1000.0 < RUN_SECONDS:
		# 【关键修正 ✓】窗口失焦时游戏会暂停场景树 ⇒ await physics_frame 永不返回 ✗
		# ⇒ 探针必须每帧强制解除暂停（仅测试进程内 ✓，不改产品 ✓）。
		get_tree().paused = false
		await get_tree().physics_frame
		var now := float(Time.get_ticks_msec() - t0) / 1000.0
		await _drive(now)
		_track(now)
		if _shots < 6 and now >= float(_shots + 1) * 25.0:
			_shots += 1
			await _shot("realistic-%02d.png" % _shots)
	_report()
	get_tree().quit(0)


func _hide_hud() -> void:
	var hud: Node = _m.get_node_or_null("HUD")
	if hud != null:
		hud.visible = false
	var fog: Node = _m.get_node_or_null("FogOfWar")
	if fog != null:
		fog.visible = false


## 玩家式命令：没有进行中的订单就给一条；卡住 >20s 才重点一次 ✓。
func _drive(now: float) -> void:
	for entry in _units:
		var u: Node3D = entry["node"]
		if u == null or not is_instance_valid(u):
			continue
		var oid: String = String(entry["order_id"])
		var state: String = ""
		if oid != "":
			state = String(_gateway.GetOrderState(oid))
		var terminal: bool = state in ["Arrived", "Unreachable", "Cancelled", "TargetLost", "UnitLost"]
		var stalled_long: bool = float(entry["stall_started"]) >= 0.0 and (now - float(entry["stall_started"])) > REISSUE_AFTER_S
		if oid == "" or terminal or stalled_long:
			if stalled_long:
				_reissued += 1
			var p: Vector3 = u.global_position
			var dir: Vector2 = Vector2(p.x - _center.x, p.z - _center.z)
			if dir.length() < 0.001:
				dir = Vector2.RIGHT
			var target: Vector3 = _center - Vector3(dir.normalized().x, 0.0, dir.normalized().y) * 30.0
			target.y = 0.0
			var res: Dictionary = _gateway.MoveUnits([u], target, _human)
			entry["order"] = String(res.get("status", ""))
			var rows: Array = res.get("unit_results", [])
			entry["order_id"] = String(rows[0].get("order_id", "")) if not rows.is_empty() else ""
			entry["last_order_t"] = now
			if stalled_long:
				entry["stall_started"] = now


func _track(now: float) -> void:
	for entry in _units:
		var u: Node3D = entry["node"]
		if u == null or not is_instance_valid(u):
			continue
		var p: Vector2 = Vector2(u.global_position.x, u.global_position.z)
		if p.distance_to(entry["last_pos"]) > 0.25:
			if entry["stall_started"] >= 0.0:
				var dur: float = now - float(entry["stall_started"])
				if dur >= STALL_S:
					_stall_events += 1
					entry["events"] = int(entry["events"]) + 1
					entry["max_stall"] = maxf(float(entry["max_stall"]), dur)
					_max_stall = maxf(_max_stall, dur)
					if dur >= LONG_STALL_S:
						_long_stalls += 1
						print("[REAL-STALL] unit=%s 停滞 %.1fs pos=(%.1f,%.1f)" % [u.name, dur, p.x, p.y])
				entry["stall_started"] = -1.0
			entry["last_pos"] = p
		else:
			if entry["stall_started"] < 0.0:
				entry["stall_started"] = now


func _shot(file_name: String) -> void:
	var cam: Camera3D = _m.get_node_or_null("Camera3D")
	if cam == null:
		cam = Camera3D.new()
		add_child(cam)
	cam.position = _center + Vector3(0.0, 62.0, 0.01)
	cam.rotation_degrees = Vector3(-90, 0, 0)
	cam.current = true
	for _f in range(4):
		await get_tree().process_frame
	var img: Image = get_viewport().get_texture().get_image()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR + "screenshots/"))
	var err := img.save_png(ProjectSettings.globalize_path(OUT_DIR + "screenshots/" + file_name))
	print("[REAL] 截图 %s err=%d" % [file_name, err])


func _report() -> void:
	for entry in _units:
		var u: Node3D = entry["node"]
		if u == null or not is_instance_valid(u):
			continue
		_per_unit.append({"unit": u.name, "events": entry["events"],
			"max_stall_s": snappedf(float(entry["max_stall"]), 0.01)})
	var payload := {
		"probe": "crowd-realistic",
		"layout": _layout + " (" + ("ring r=9m" if _layout == "tight" else "3x3 grid, spacing 16m") + ")",
		"map": (_map_path if _map_path != "" else "res://source/match/maps/PlainAndSimple.tscn"), "orders": "player-like (reissue after arrival; forced reissue after 20s stall)",
		"buildings": BUILDINGS.size(), "units": _units.size(), "run_seconds": RUN_SECONDS,
		"stall_threshold_s": STALL_S, "long_stall_threshold_s": LONG_STALL_S,
		"stall_events": _stall_events, "long_stalls": _long_stalls,
		"max_stall_s": snappedf(_max_stall, 0.01), "reissued": _reissued,
		"units_with_events": _per_unit.filter(func(e): return int(e["events"]) > 0).size(),
		"per_unit": _per_unit,
	}
	var f := FileAccess.open(ProjectSettings.globalize_path(OUT_DIR + "crowd-realistic.json"), FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(payload, "  "))
		f.close()
	print("[REAL] %s" % JSON.stringify({"stall_events": _stall_events, "long_stalls": _long_stalls,
		"max_stall_s": snappedf(_max_stall, 0.01), "reissued": _reissued}))
	print("Crowd realistic probe completed: %d long stall(s)" % _long_stalls)
