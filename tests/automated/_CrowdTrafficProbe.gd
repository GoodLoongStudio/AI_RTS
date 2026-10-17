extends Node

## 实机人群交通探针（用户要求 ✓）：真实 Match、建齐建筑、几十个单位在建筑间**反复穿梭**，
## 逐单位统计"**无进展时长**"（有订单但位置长时间不变）⇒ 回答"会不会持续长时间卡住" ✓。
## 一进程一场景 ✓、自带超时兜底 ✓、定时出截图 ✓（需窗口模式才有画面 ✓）。

const BUILDINGS := ["CommandCenter", "Barracks", "VehicleFactory", "AircraftFactory", "OreRefinery",
	"AntiGroundTurret", "AntiAirTurret", "MachineGunTurret"]
const UNITS := ["Tank", "Tank", "HeavyTank", "APC", "Worker", "Worker", "Scout", "Infantry", "Rocketeer", "Sniper"]
const UNIT_COUNT := 40
const STALL_S := 3.0          # 连续 3 秒无有效位移 = 一次"卡住"
const LONG_STALL_S := 6.0     # 连续 6 秒 = 明显卡住（重点观察对象）
const RUN_SECONDS := 150.0
const OUT_DIR := "res://agent/runs/2026-10-02-crowd-traffic/"

var _m: Node
var _human: Node
var _gateway: Node
var _units: Array = []
var _stall_events := 0
var _long_stalls := 0
var _max_stall := 0.0
var _per_unit: Array = []
var _shots := 0


func _ready() -> void:
	get_tree().create_timer(400.0).timeout.connect(func() -> void:
		push_error("[CROWD] 超时兜底退出")
		get_tree().quit(2))
	await _run()


func _run() -> void:
	var settings = load("res://source/data-model/MatchSettings.gd").new()
	var hs = load("res://source/data-model/PlayerSettings.gd").new()
	hs.controller = Constants.PlayerType.HUMAN
	hs.color = Constants.Player.COLORS[0]
	settings.players.append(hs)
	settings.visible_player = 0
	_m = load("res://source/match/Match.tscn").instantiate()
	_m.settings = settings
	_m.map = load("res://source/match/maps/PlainAndSimple.tscn").instantiate()
	add_child(_m)
	get_tree().current_scene = _m
	for _f in range(160):
		await get_tree().physics_frame
	_human = _m.get_node("Players").get_children()[0]
	_gateway = _human.get_node("UnitCommandGateway")
	# 远离地图自带基地，避免初始基地干扰（此前踩过的坑 ✓）
	var base := Vector3(120.0, 0.0, 120.0)
	var placed: Array = []
	var ring := 9.0
	for i in range(BUILDINGS.size()):
		var ang := TAU * float(i) / float(BUILDINGS.size())
		var pos := base + Vector3(cos(ang) * ring, 0.0, sin(ang) * ring)
		var b: Node3D = (load("res://source/match/units/" + BUILDINGS[i] + ".tscn") as PackedScene).instantiate()
		_m.call("_setup_and_spawn_unit", b, Transform3D(Basis.IDENTITY, pos), _human, false)
		placed.append(b)
	for _f in range(90):
		await get_tree().physics_frame
	# 部队：环绕在建筑群外围
	for i in range(UNIT_COUNT):
		var ang := TAU * float(i) / float(UNIT_COUNT)
		var r := 22.0 + float(i % 3) * 3.0
		var pos := base + Vector3(cos(ang) * r, 0.0, sin(ang) * r)
		var u: Node3D = (load("res://source/match/units/" + UNITS[i % UNITS.size()] + ".tscn") as PackedScene).instantiate()
		_m.call("_setup_and_spawn_unit", u, Transform3D(Basis.IDENTITY, pos), _human, false)
		_units.append({"node": u, "last_move_t": 0.0, "stall_started": -1.0, "last_pos": Vector2(pos.x, pos.z),
			"events": 0, "max_stall": 0.0, "order": ""})
		if u.get_node_or_null("Movement") != null:
			var mv: Node = u.get_node("Movement")
			if mv.has_method("set"):
				mv.set("domain", mv.get("domain"))
	for _f in range(120):
		await get_tree().physics_frame
	_hide_hud()
	# 反复下达"穿过建筑群到对侧"的命令
	var t0 := Time.get_ticks_msec()
	var last_order := -1.0
	while float(Time.get_ticks_msec() - t0) / 1000.0 < RUN_SECONDS:
		await get_tree().physics_frame
		var now := float(Time.get_ticks_msec() - t0) / 1000.0
		if now - last_order > 2.0:
			last_order = now
			_issue_cross_orders(base, now)
		_track(now)
		if int(now) % 20 == 0 and now - float(_shots) * 20.0 >= 0.0 and _shots < 6:
			_shots += 1
			await _shot("crowd-%02d.png" % _shots)
	_report()
	get_tree().quit(0)


func _hide_hud() -> void:
	var hud: Node = _m.get_node_or_null("HUD")
	if hud != null:
		hud.visible = false
	var fog: Node = _m.get_node_or_null("FogOfWar")
	if fog != null:
		fog.visible = false


func _issue_cross_orders(base: Vector3, now: float) -> void:
	# 每个单位：朝"当前所在侧的对面"走；到达或超时就再下一条 ⇒ 反复穿越建筑群 ✓
	for entry in _units:
		var u: Node3D = entry["node"]
		if u == null or not is_instance_valid(u):
			continue
		var p: Vector3 = u.global_position
		var dir := Vector2(p.x - base.x, p.z - base.z)
		if dir.length() < 0.001:
			dir = Vector2.RIGHT
		var target := base - Vector3(dir.normalized().x, 0.0, dir.normalized().y) * 26.0
		target.y = 0.0
		var res: Dictionary = _gateway.MoveUnits([u], target, _human)
		entry["order"] = String(res.get("status", ""))


func _track(now: float) -> void:
	for entry in _units:
		var u: Node3D = entry["node"]
		if u == null or not is_instance_valid(u):
			continue
		var p: Vector2 = Vector2(u.global_position.x, u.global_position.z)
		var moved: float = p.distance_to(entry["last_pos"])
		if moved > 0.25:
			# 有效位移 ⇒ 结束当前停滞窗口
			if entry["stall_started"] >= 0.0:
				var dur: float = now - float(entry["stall_started"])
				if dur >= STALL_S:
					_stall_events += 1
					entry["events"] = int(entry["events"]) + 1
					entry["max_stall"] = maxf(float(entry["max_stall"]), dur)
					_max_stall = maxf(_max_stall, dur)
					if dur >= LONG_STALL_S:
						_long_stalls += 1
						print("[CROWD-STALL] unit=%s 停滞 %.1fs pos=(%.1f,%.1f) order=%s" % [
							u.name, dur, p.x, p.y, entry["order"]])
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
	cam.position = Vector3(120.0, 60.0, 120.0)
	cam.rotation_degrees = Vector3(-90, 0, 0)
	cam.current = true
	for _f in range(4):
		await get_tree().process_frame
	var img: Image = get_viewport().get_texture().get_image()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR + "screenshots/"))
	var err := img.save_png(ProjectSettings.globalize_path(OUT_DIR + "screenshots/" + file_name))
	print("[CROWD] 截图 %s err=%d" % [file_name, err])


func _report() -> void:
	for entry in _units:
		var u: Node3D = entry["node"]
		if u == null or not is_instance_valid(u):
			continue
		_per_unit.append({
			"unit": u.name, "events": entry["events"], "max_stall_s": snappedf(float(entry["max_stall"]), 0.01),
		})
	var payload := {
		"probe": "crowd-traffic",
		"buildings": BUILDINGS.size(), "units": _units.size(),
		"run_seconds": RUN_SECONDS, "stall_threshold_s": STALL_S, "long_stall_threshold_s": LONG_STALL_S,
		"stall_events": _stall_events, "long_stalls": _long_stalls, "max_stall_s": snappedf(_max_stall, 0.01),
		"units_with_events": _per_unit.filter(func(e): return int(e["events"]) > 0).size(),
		"per_unit": _per_unit,
	}
	var f := FileAccess.open(ProjectSettings.globalize_path(OUT_DIR + "crowd-traffic.json"), FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(payload, "  "))
		f.close()
	print("[CROWD] %s" % JSON.stringify({"stall_events": _stall_events, "long_stalls": _long_stalls,
		"max_stall_s": snappedf(_max_stall, 0.01), "units": _units.size()}))
	print("Crowd traffic probe completed: %d long stall(s)" % _long_stalls)
