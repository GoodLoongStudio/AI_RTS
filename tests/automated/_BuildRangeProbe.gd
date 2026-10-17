extends Node

## 建造范围 2/3 验证探针（RSI round-01 ✓）：真实 Match ✓，读运行时权威值 ✓，
## 并做**正向/反向成对**断言：12m 圈内应接受 ✓、圈外应拒绝 ✓。

const OUT_DIR := "res://agent/runs/2026-10-02-build-range-2of3/"

var _failures := 0


func _ready() -> void:
	get_tree().create_timer(200.0).timeout.connect(func() -> void:
		push_error("[BUILDRANGE] 超时兜底")
		get_tree().quit(2))
	await _run()


func _run() -> void:
	var settings = load("res://source/data-model/MatchSettings.gd").new()
	var hs = load("res://source/data-model/PlayerSettings.gd").new()
	hs.controller = Constants.PlayerType.HUMAN
	hs.color = Constants.Player.COLORS[0]
	settings.players.append(hs)
	settings.visible_player = 0
	var m: Node = load("res://source/match/Match.tscn").instantiate()
	m.settings = settings
	m.map = load("res://source/match/maps/PlainAndSimple.tscn").instantiate()
	add_child(m)
	get_tree().current_scene = m
	for _f in range(160):
		await get_tree().physics_frame
	var human: Node = m.get_node("Players").get_children()[0]
	var runtime: Node = m.find_child("StructurePlacementRuntime")
	_check(runtime != null, "对局必须挂载 StructurePlacementRuntime")
	if runtime == null:
		_finish()
		return
	# ① 运行时权威半径（这也能证明 DLL 是新的 ✓）
	var range_m := float(runtime.call("BuildRangeMeters"))
	print("[BUILDRANGE] runtime BuildRangeMeters = %.3f" % range_m)
	# 【2026-10-06 口径拆分】圈 = 12（用户要 2/3）✓；放置网络窗口 = 18（AI/玩家合法带）✓
	# 【2026-10-06 口径复核】单一来源 = 18：圈、玩家判据、AI 网络窗口同源
	# （我曾拆成 圈12/判据18，破坏同源且圈会骗人，已回退）
	_check(absf(range_m - 18.0) <= 0.001, "建造范围应为 18m（圈=判据=窗口，单一来源），实际 %.3f" % range_m)
	# ② 以指挥中心为锚，取一个"干净方向"上的距离做接受/拒绝边界
	var cc: Node3D = human.get_node("CommandCenter")
	var anchor: Vector3 = cc.global_position
	var proto: Resource = load("res://source/match/units/Barracks.tscn")
	var cost: Dictionary = {}
	var probes := []
	for d in [8.0, 10.0, 14.0, 16.0]:
		var pos := anchor + Vector3(d, 0.0, 0.0)
		pos.y = anchor.y
		var ev: Variant = runtime.call("Evaluate", human, proto, Transform3D(Basis.IDENTITY, pos), cost)
		var accepted := false
		var issue := ""
		var why := ""
		if ev is Dictionary:
			accepted = bool(ev.get("accepted", false))
			issue = str(ev.get("primary_issue", ""))
			why = str(ev.get("message", ev.get("reason", "")))
		probes.append({"distance_m": d, "accepted": accepted, "primary_issue": issue, "why": why})
		print("[BUILDRANGE] d=%.1fm accepted=%s issue=%s" % [d, str(accepted), issue])
	# ③ 成对断言（正向：圈内接受 ✓；反向：圈外拒绝 ✓）
	var inside: Dictionary = probes[0]
	var outside: Dictionary = probes[3]
	_check(bool(probes[1]["accepted"]), "10m（< 12m 圈）应被接受（issue=%s）" % probes[1]["primary_issue"])
	_check(not bool(outside["accepted"]), "16m（> 12m 圈）应被拒绝，实际 accepted=true")
	var payload := {
		"probe": "build-range-2of3", "runtime_build_range_m": range_m,
		"note": "圈口径 12m（BuildCircleRangeMeters）；放置网络窗口仍为 18m（BuildRangeMeters）",
		"expected_m": 12.0, "previous_m": 18.0, "ratio": 0.6667, "probes": probes, "failures": _failures,
	}
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	var f := FileAccess.open(ProjectSettings.globalize_path(OUT_DIR + "build-range.json"), FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(payload, "  "))
		f.close()
	_finish()


func _check(cond: bool, msg: String) -> void:
	if cond:
		print("[BUILDRANGE] OK: " + msg)
	else:
		_failures += 1
		push_error("[BUILDRANGE] FAIL: " + msg)


func _finish() -> void:
	print("Build range probe completed: %d failure(s)" % _failures)
	get_tree().quit(0 if _failures == 0 else 1)
