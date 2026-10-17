extends Node
## 副官真实客户端 × 真实 DCS 端到端回归（2026-10-11 P1b corrective）。
##
## 新开无头真实 Match（tests/manual/TestPlayerVsAI.tscn，2 实体小局），通过
## **真实客户端方法**（source/ui/AdjutantButton.gd::_tcp_json，与面板生产路径
## 同一实现）调用本进程真实 DCS（--debugport 启动），验证：
##   1) status（大响应）经真实客户端返回且 schema 正确，对局就绪后有真实单位；
##   2) rules（大帧）经真实客户端返回；
##   3) adjutant_leases 可查询；
##   4) 一条旧功能轨迹：对真实单位下 move 且被权威受理；
##   5) 小帧路径回归（旧实现本就正确，长度帧修复不得破坏）。
## 不用 TestAllUnits：该场景谱系在退出时有 115 ObjectDB/17 resources/RID 泄漏
## （command-protocol/rules-export 同源未归因项）；observation 套在
## TestPlayerVsAI 上严格绿，本测试聚焦客户端-DCS 链路，不需要全单位阵容。
## 收尾走 SmokeTestExit 规范退出。

const MatchScene = preload("res://tests/manual/TestPlayerVsAI.tscn")

var _failures := 0
var _match: Node = null


func _check(cond: bool, msg: String) -> void:
	if cond:
		print("[PASS] " + msg)
	else:
		_failures += 1
		print("[FAIL] " + msg)


func _ready() -> void:
	var dbg := get_node_or_null("/root/DebugControlServer")
	if dbg == null:
		print("[FAIL] DebugControlServer autoload 未挂载：请用 -- --debugport <port> 启动本测试")
		SmokeTestExit.request(get_tree(), 1)
		return
	var args := OS.get_cmdline_user_args()
	var port_index := args.find("--debugport")
	var port := 0
	if port_index >= 0 and port_index + 1 < args.size():
		port = int(args[port_index + 1])
	_check(port > 0, "--debugport 已提供（%d）" % port)
	if port <= 0:
		SmokeTestExit.request(get_tree(), 1)
		return

	_match = MatchScene.instantiate()
	# DCS 按 tree.current_scene 找对局（DebugControlServer.gd L428），且
	# current_scene 要求节点直接挂在 root 下；_ready 期间 root busy，
	# add_child 必须 call_deferred（2026-10-11 实测）。
	get_tree().root.add_child.call_deferred(_match)
	await get_tree().process_frame
	get_tree().current_scene = _match
	# 就绪判据与 command-protocol 同源：Match._ready 首个 await 是导航烘焙，
	# 资源账户建立才算就绪；不能只靠固定时长。
	var economy = _match.get_node_or_null("EconomyRuntime")
	var waited := 0.0
	while waited < 30.0:
		var human = _match.get_node_or_null("Players/Human")
		if human != null and economy != null \
				and not economy.GetSnapshot(human).is_empty():
			break
		await get_tree().create_timer(0.1).timeout
		waited += 0.1
	_check(waited < 30.0, "对局就绪（Players/Human + EconomyRuntime，等待 %.1fs）" % waited)

	var btn: Node = load("res://source/ui/AdjutantButton.gd").new()
	btn.name = "RealDcsProbeButton"
	add_child(btn)

	# 1) status（非 lite + full_vision：headless 无渲染相机，视野过滤会清空 units）
	var t0 := Time.get_ticks_msec()
	var status: Dictionary = await btn._tcp_json(port, {"op": "status", "full_vision": true})
	var dt := Time.get_ticks_msec() - t0
	_check(not status.is_empty() and not status.has("error"),
		"真实 DCS status 经真实客户端返回（%dms）" % dt)
	_check(bool(status.get("match", false)), "status schema：match=true（对局可见）")

	var units: Array = status.get("units", [])
	var wait_deadline := Time.get_ticks_msec() + 10000
	while units.is_empty() and Time.get_ticks_msec() < wait_deadline:
		await get_tree().create_timer(0.5).timeout
		status = await btn._tcp_json(port, {"op": "status", "full_vision": true})
		units = status.get("units", [])
	_check(units.size() > 0, "status.units 有真实单位（%d 个）" % units.size())

	# 2) rules（大帧）
	var rules: Dictionary = await btn._tcp_json(port, {"op": "rules"})
	_check(not rules.is_empty() and not rules.has("error"), "rules（大帧）经真实客户端返回")
	if rules.has("error"):
		print("[DBG] rules error=", str(rules.get("error")))

	# 3) 租约
	var leases: Dictionary = await btn._tcp_json(port, {"op": "adjutant_leases", "all": true})
	_check(not leases.is_empty(), "adjutant_leases 返回（ok=%s）" % str(leases.get("ok")))

	# 4) 旧功能轨迹：己方可移动单位 move（_op_move 只受理 as_player 己方单位）
	if units.size() > 0:
		var own_name := str(status.get("local_player_name", ""))
		if own_name.is_empty():
			for p in status.get("players", []):
				if bool(p.get("human")):
					own_name = str(p.get("name"))
					break
		var unit: Dictionary = {}
		for u in units:
			if bool(u.get("mine")) and bool(u.get("movement")):
				unit = u
				break
		if unit.is_empty():
			for u in units:
				if str(u.get("name")).contains("Worker"):
					unit = u
					break
		if unit.is_empty():
			unit = units[0]
		var pos: Array = unit.get("pos", [0.0, 0.0, 0.0])
		var move: Dictionary = await btn._tcp_json(port, {
			"op": "move", "as_player": own_name, "units": [unit.get("name")],
			"dest": [float(pos[0]) + 10.0, float(pos[2]) + 10.0]})
		_check(bool(move.get("accepted")),
			"旧功能轨迹：move 被权威受理（status=%s reason=%s unit=%s）"
				% [str(move.get("status")), str(move.get("reason")), str(unit.get("name"))])
	else:
		_failures += 1
		print("[FAIL] 旧功能轨迹：无单位可下命令")

	print("Adjutant real client DCS test completed: %d failure(s)" % _failures)
	if _match != null and is_instance_valid(_match):
		get_tree().current_scene = null
		_match.queue_free()
		await get_tree().process_frame
	SmokeTestExit.request(get_tree(), 1 if _failures > 0 else 0)