extends Node

## 双进程联机冒烟监控节点。由 Online.gd 在 --smokeclient 时挂到 root 下——
## 挂在 root 而不是当前场景，因此场景切换（Online→Loading→Match）不会释放它，
## 协程全程存活，规避「lambda/方法在实例释放后静默失效」的坑。

var _log_fa: FileAccess = null
var _deadline := 0
var _port := 24599
var _host := "127.0.0.1"


func _log(msg: String) -> void:
	print(msg)
	if _log_fa == null:
		_log_fa = FileAccess.open("user://smoke_client.log", FileAccess.WRITE)
	if _log_fa != null:
		_log_fa.store_line("%d %s" % [Time.get_ticks_msec(), msg])
		_log_fa.flush()


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	_port = NetSession.DEFAULT_PORT
	var pi := args.find("--smokeport")
	if pi >= 0 and pi + 1 < args.size():
		_port = int(args[pi + 1])
	var host := "127.0.0.1"
	pi = args.find("--smokehost")
	if pi >= 0 and pi + 1 < args.size():
		host = args[pi + 1]
	_host = host
	_deadline = Time.get_ticks_msec() + 420_000
	_run()


func _run() -> void:
	var tree := get_tree()
	_log("SMOKE: client start, target %s:%d" % [_host, _port])
	var err := NetSession.join(_host, _port)
	_log("SMOKE: join err=%d" % err)
	if err != OK:
		_log("SMOKE_FAIL join")
		tree.quit(1)
		return
	# 等连接+槽位（槽位分配后状态直接跳"已分配阵营槽位"，两种都要认）。
	var waited := 0
	while Time.get_ticks_msec() < _deadline:
		await tree.create_timer(0.5).timeout
		waited += 1
		var st := NetSession.get_status()
		if st.begins_with("已连接") or st.begins_with("已分配阵营槽位"):
			break
		if waited % 10 == 0:
			_log("SMOKE: 等连接 %ds, status=%s" % [waited, st])
	if not NetSession.is_networked():
		_log("SMOKE_FAIL connect")
		tree.quit(1)
		return
	_log("SMOKE: connected, status=%s" % NetSession.get_status())
	await tree.create_timer(1.0).timeout
	NetSession.start_solo()
	_log("SMOKE: solo start requested")
	# 等客户端 Match 场景加载出 NetSync。
	var sync: Node = null
	waited = 0
	while Time.get_ticks_msec() < _deadline:
		await tree.create_timer(1.0).timeout
		waited += 1
		sync = tree.root.find_child("NetSync", true, false)
		if sync != null:
			_log("SMOKE: NetSync 出现于等待 %ds" % waited)
			break
		if waited % 10 == 0:
			_log("SMOKE: 等 NetSync %ds, scene=%s" % [
				waited, tree.current_scene.name if tree.current_scene else "null"])
	if sync == null:
		_log("SMOKE_FAIL no NetSync (Match 未加载)")
		tree.quit(1)
		return
	# 等 go-live 后首个快照写入插值目标。
	waited = 0
	while Time.get_ticks_msec() < _deadline:
		await tree.create_timer(1.0).timeout
		waited += 1
		if not NetSession.is_networked():
			_log("SMOKE_FAIL 会话已断开（等待 %ds）" % waited)
			tree.quit(1)
			return
		var targets: Dictionary = sync.get("_interp_target") if sync.get("_interp_target") is Dictionary else {}
		var units := tree.get_nodes_in_group("units").size()
		if targets.size() > 0:
			_log("SMOKE_OK units=%d interp_targets=%d" % [units, targets.size()])
			await _command_round_trip(sync)
			tree.quit(0)
			return
		if waited % 10 == 0:
			_log("SMOKE: 等快照 %ds, units=%d, live=%s" % [
				waited, units, str(sync.get("_live"))])
	_log("SMOKE_FAIL timeout")
	tree.quit(1)


## 人类命令回路实测：选己方单位 → 经命令代理下发真实移动 → 看它是否真的动了。
## 与玩家右键完全同一条代码路径（NetCommandProxy.forward_command → 服务器 _rpc_command）。
func _command_round_trip(sync: Node) -> void:
	var tree := get_tree()
	var match_node := tree.current_scene
	if match_node == null or not match_node.has_method("get_local_player"):
		_log("SMOKE_CMD_FAIL no match scene")
		return
	var player = match_node.get_local_player()
	if player == null:
		_log("SMOKE_CMD_FAIL no local player")
		return
	var my_units := tree.get_nodes_in_group("units").filter(
		func(unit): return unit.get_parent() == player
	)
	if my_units.is_empty():
		_log("SMOKE_CMD_FAIL no own units (total=%d)" % tree.get_nodes_in_group("units").size())
		return
	# 与服务器 C# CanMove 判定完全同口径：存在名为 "Movement" 的子节点。
	var movable := tree.get_nodes_in_group("controlled_units").filter(
		func(unit):
			return (
				unit.get_parent() == player
				and unit.find_child("Movement", false, false) != null
			)
	)
	# 逐单位跑 HUD 三重过滤模拟 + 分类型移动实测（无人机=Unit_1, 工人=Unit_2/3）。
	var moved_count: int = 0
	for unit in movable:
		var in_controlled: bool = unit.is_in_group("controlled_units")
		var domain = unit.get("movement_domain")
		var applicable = load("res://source/match/units/actions/Moving.gd").is_applicable(unit)
		_log(
			"SMOKE_CMD: HUD 过滤 %s controlled=%s domain=%s applicable=%s" % [
				unit.name, in_controlled, str(domain), str(applicable)
			]
		)
	if movable.is_empty():
		_log("SMOKE_CMD_FAIL no movable units")
		return
	var gateway = NetSession.command_gateway_for(player)
	if gateway == null:
		_log("SMOKE_CMD_FAIL no gateway (puppet without NetSync?)")
		return
	# 对每个可移动单位（无人机+2 工人）各自下发移动并独立验证位移。
	var befores := {}
	for unit in movable:
		befores[unit.name] = unit.global_position
		var destination: Vector3 = unit.global_position + Vector3(25.0, 0.0, 0.0)
		var result: Dictionary = gateway.MoveUnits([unit], destination, player)
		_log("SMOKE_CMD: %s MoveUnits -> %s" % [unit.name, str(result.get("status", result))])
	for i in range(16):
		await tree.create_timer(0.5).timeout
		moved_count = 0
		for unit in movable:
			if not is_instance_valid(unit):
				moved_count += 1
				continue
			var before: Vector3 = befores[unit.name]
			if unit.global_position.distance_to(before) > 5.0:
				moved_count += 1
		if moved_count == movable.size():
			_log("SMOKE_CMD_MOVED %d/%d units all moved >5m after %ds" % [
				moved_count, movable.size(), (i + 1) * 5
			])
			return
		if i % 4 == 3:
			_log("SMOKE_CMD: waiting %ds, moved=%d/%d" % [(i + 1) * 5, moved_count, movable.size()])
	_log("SMOKE_CMD_FAIL 8s 后 moved=%d/%d" % [moved_count, movable.size()])

