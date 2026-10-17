extends Node

## R12：对账 Performance.TIME_PHYSICS_PROCESS 与**墙钟**（非侵入 ✓）
## 逐渲染帧记录：墙钟帧间隔、physics_frame 信号次数、TIME_PHYSICS_PROCESS、TIME_PROCESS ✓

const SECONDS := 8.0
var _match: Node
var _phys_ticks := 0
var _frames := 0


func _process(_d: float) -> void:
	if get_tree().paused:
		get_tree().paused = false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	get_tree().create_timer(280.0).timeout.connect(func() -> void: get_tree().quit(3))
	await _run()


func _run() -> void:
	var settings = load("res://source/data-model/MatchSettings.gd").new()
	var human = load("res://source/data-model/PlayerSettings.gd").new()
	human.controller = Constants.PlayerType.HUMAN
	human.color = Constants.Player.COLORS[0]
	settings.players.append(human)
	settings.visible_player = 0
	_match = load("res://source/match/Match.tscn").instantiate()
	_match.settings = settings
	_match.map = load("res://source/match/maps/PlainAndSimple.tscn").instantiate()
	add_child(_match)
	get_tree().current_scene = _match
	for _f in range(160):
		await get_tree().physics_frame
	print("[SYNC] physics_ticks_per_second=", Engine.physics_ticks_per_second, " max_fps=", Engine.max_fps)
	var wall: Array = []       # 渲染帧墙钟间隔 ms
	var mon_phys: Array = []   # TIME_PHYSICS_PROCESS ms
	var mon_proc: Array = []   # TIME_PROCESS ms
	var ticks_per_frame: Array = []
	var last_phys := 0
	var last_t := Time.get_ticks_usec()
	var start := last_t
	while float(Time.get_ticks_usec() - start) / 1000000.0 < SECONDS:
		await get_tree().process_frame
		var now := Time.get_ticks_usec()
		wall.append(float(now - last_t) / 1000.0)
		last_t = now
		var pf := Engine.get_physics_frames()
		ticks_per_frame.append(pf - last_phys)
		last_phys = pf
		mon_phys.append(Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0)
		mon_proc.append(Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0)
	wall.sort(); mon_phys.sort(); mon_proc.sort(); ticks_per_frame.sort()
	var n := wall.size()
	print("[SYNC] 渲染帧数=%d 墙钟帧 p50=%.2fms p95=%.2fms" % [n, wall[n / 2], wall[int(n * 0.95)]])
	print("[SYNC] 每渲染帧物理 tick 数 p50=%d p95=%d" % [ticks_per_frame[n / 2], ticks_per_frame[int(n * 0.95)]])
	print("[SYNC] TIME_PHYSICS_PROCESS p50=%.2fms p95=%.2fms | TIME_PROCESS p50=%.2fms" % [
		mon_phys[n / 2], mon_phys[int(n * 0.95)], mon_proc[n / 2]])
	var fps := float(n) / (float(Time.get_ticks_usec() - start) / 1000000.0)
	print("[SYNC] 实测渲染 FPS=%.1f ⇒ 墙钟 %.2f ms/帧" % [fps, 1000.0 / maxf(0.001, fps)])
	print("[SYNC] 判定：若 TIME_PHYSICS_PROCESS ≈ 1000/physics_ticks（%.1fms）⇒ 它是**tick 间隔**而非耗时 ✗" % (1000.0 / float(Engine.physics_ticks_per_second)))
	get_tree().quit(0)
