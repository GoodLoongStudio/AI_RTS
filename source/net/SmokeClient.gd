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
			await _rts_chain_test()
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


## 阶段链 BUILD→PRODUCE_WORKER→PRODUCE_TANK→ATTACK：完整 RTS 循环端到端实测。
func _rts_chain_test() -> void:
	var tree := get_tree()
	var match_node := tree.current_scene
	var player = match_node.get_local_player()
	var sync = match_node.get_node_or_null("NetSync")
	var gateway = NetSession.command_gateway_for(player)
	if gateway == null:
		_log("SMOKE_SUITE CHAIN=FAIL (无命令代理)")
		return

	var own_cc = null
	var own_worker = null
	for unit in tree.get_nodes_in_group("units"):
		if unit.get_parent() != player:
			continue
		if unit.find_child("ProductionQueue", false, false) != null and own_cc == null:
			own_cc = unit
		elif (
			unit.find_child("Movement", false, false) != null
			and unit.has_method("request_legacy_construct")
			and own_worker == null
		):
			own_worker = unit
	if own_cc == null or own_worker == null:
		_log("SMOKE_SUITE CHAIN=FAIL (基地=%s 工人=%s)" % [str(own_cc != null), str(own_worker != null)])
		return

	# GATHER：先派全部工人去最近资源点采矿，攒够兵工厂造价（6A）再放置。
	var workers: Array = []
	for unit in tree.get_nodes_in_group("controlled_units"):
		if (
			unit.get_parent() == player
			and unit.find_child("Movement", false, false) != null
			and unit.has_method("request_legacy_construct")
		):
			workers.append(unit)
	var nearest_resource = null
	var nearest_distance := 1e12
	for resource in tree.get_nodes_in_group("resource_units"):
		var distance: float = resource.global_position.distance_to(own_cc.global_position)
		if distance < nearest_distance:
			nearest_distance = distance
			nearest_resource = resource
	if nearest_resource != null and not workers.is_empty():
		# 只派真正能采集的工人（resources_max>0），逐个下发——无人机等混入会整批被拒。
		for worker in workers:
			if "resources_max" in worker and int(worker.get("resources_max")) > 0:
				var gather_result: Dictionary = gateway.GatherResources(
					[worker], nearest_resource, player
				)
				_log("SMOKE_SUITE GATHER=SUBMITTED %s -> %s" % [
					worker.name, str(gather_result.get("status", gather_result))
				])
	# 等待余额够工厂造价（6A）。工人采集由快照同步的余额反映。
	# 资源点采空会导致工人闲置——停滞 20s 就换下一个资源点重新派采（AI 同款策略）。
	var factory_cost := 6.0
	var affordable := false
	var resource_candidates := tree.get_nodes_in_group("resource_units")
	var resource_index := 0
	var last_balance := -1
	var stall_ticks := 0
	for i in range(240):
		await tree.create_timer(2.5).timeout
		if player.get("resource_a") != null and float(player.resource_a) >= factory_cost:
			affordable = true
			_log("SMOKE_SUITE GATHER=PASS (resource_a=%d, %ds)" % [
				int(player.resource_a), int((i + 1) * 2.5)
			])
			break
		var balance := int(player.resource_a)
		if i % 4 == 3:
			var positions := []
			for w in workers:
				if is_instance_valid(w):
					positions.append(str(w.global_position))
			_log("SMOKE_SUITE GATHER=采矿中 %ds, resource_a=%s 工人位置=%s" % [
				int((i + 1) * 2.5), str(balance), str(positions)
			])
		if balance == last_balance:
			stall_ticks += 1
			if stall_ticks >= 8 and not resource_candidates.is_empty():
				stall_ticks = 0
				resource_index += 1
				var pick = resource_candidates[resource_index % resource_candidates.size()]
				for worker in workers:
					if is_instance_valid(worker) and "resources_max" in worker and int(worker.get("resources_max")) > 0:
						gateway.GatherResources([worker], pick, player)
				_log("SMOKE_SUITE GATHER=换矿 %s" % pick.name)
		else:
			stall_ticks = 0
		last_balance = balance
	if not affordable:
		_log("SMOKE_SUITE GATHER=FAIL (600s 未攒够 %s)" % str(factory_cost))
		return

	# BUILD：工人放置兵工厂（与玩家放建筑完全同一条转发路径）。
	var factory_position: Vector3 = own_cc.global_position + Vector3(5.0, 0.0, 5.0)
	sync.forward_command(
		"place_structure",
		workers,
		factory_position,
		null,
		player,
		"res://source/match/units/VehicleFactory.tscn"
	)
	_log("SMOKE_SUITE BUILD=SUBMITTED")
	var factory = null
	for i in range(12):
		await tree.create_timer(2.5).timeout
		for unit in tree.get_nodes_in_group("units"):
			if (
				unit.get_parent() == player
				and unit.find_child("ProductionQueue", false, false) != null
				and unit != own_cc
			):
				factory = unit
				break
		if factory != null:
			break
	if factory == null:
		_log("SMOKE_SUITE BUILD=FAIL (30s 内未出现工厂蓝图——余额不足或被拒)")
		return
	_log("SMOKE_SUITE BUILD=SPAWNED (等待竣工)")
	for i in range(120):
		await tree.create_timer(2.5).timeout
		if not is_instance_valid(factory):
			_log("SMOKE_SUITE BUILD=FAIL (工厂消失)")
			return
		if "is_constructed" in factory and bool(factory.is_constructed()):
			_log("SMOKE_SUITE BUILD=PASS (%ds 竣工)" % int((i + 1) * 2.5))
			break
		if i % 8 == 7:
			_log("SMOKE_SUITE BUILD=施工中 %ds" % int((i + 1) * 2.5))
	if not ("is_constructed" in factory and bool(factory.is_constructed())):
		_log("SMOKE_SUITE BUILD=FAIL (300s 未竣工)")
		return

	# PRODUCE_WORKER：指挥中心生产 1 个工人。
	var units_before: int = tree.get_nodes_in_group("units").size()
	own_cc.find_child("ProductionQueue", false, false).produce(
		load("res://source/match/units/Worker.tscn")
	)
	_log("SMOKE_SUITE PRODUCE_WORKER=SUBMITTED")
	var worker_ok := false
	for i in range(36):
		await tree.create_timer(2.5).timeout
		if tree.get_nodes_in_group("units").size() > units_before:
			_log("SMOKE_SUITE PRODUCE_WORKER=PASS (%ds)" % int((i + 1) * 2.5))
			worker_ok = true
			break
	if not worker_ok:
		_log("SMOKE_SUITE PRODUCE_WORKER=FAIL (90s 未出货)")
		return

	# PRODUCE_TANK：兵工厂生产 1 辆坦克。
	units_before = tree.get_nodes_in_group("units").size()
	factory.find_child("ProductionQueue", false, false).produce(
		load("res://source/match/units/Tank.tscn")
	)
	_log("SMOKE_SUITE PRODUCE_TANK=SUBMITTED")
	var tank = null
	for i in range(72):
		await tree.create_timer(2.5).timeout
		for unit in tree.get_nodes_in_group("units"):
			if (
				unit.get_parent() == player
				and unit.find_child("Movement", false, false) != null
				and str(unit.get_script().resource_path).contains("Tank")
			):
				tank = unit
				break
		if tank != null:
			_log("SMOKE_SUITE PRODUCE_TANK=PASS (%ds)" % int((i + 1) * 2.5))
			break
		if i % 8 == 7:
			_log("SMOKE_SUITE PRODUCE_TANK=等待 %ds units=%d" % [int((i + 1) * 2.5), tree.get_nodes_in_group("units").size()])
	if tank == null:
		_log("SMOKE_SUITE PRODUCE_TANK=FAIL (180s 未出货)")
		return

	# ATTACK：坦克攻击敌方基地（移动+交战）。
	var enemy_cc = null
	for unit in tree.get_nodes_in_group("units"):
		if (
			unit.get_parent() != player
			and unit.get_parent().get_parent() == match_node.get_node("Players")
			and unit.find_child("ProductionQueue", false, false) != null
			and unit.find_child("Movement", false, false) == null
		):
			enemy_cc = unit
			break
	if enemy_cc == null:
		_log("SMOKE_SUITE ATTACK=FAIL (找不到敌方基地)")
		return
	var before: Vector3 = tank.global_position
	var result: Dictionary = gateway.AttackUnits([tank], enemy_cc, player)
	var accepted := false
	if result.get("unit_results", []) is Array:
		for item in result.get("unit_results", []):
			if bool(item.get("accepted", false)):
				accepted = true
	_log("SMOKE_SUITE ATTACK=SUBMITTED accepted=%s" % str(accepted))
	for i in range(24):
		await tree.create_timer(2.5).timeout
		if not is_instance_valid(tank):
			_log("SMOKE_SUITE ATTACK=PASS (坦克阵亡=已交战至死)")
			return
		var drift: float = tank.global_position.distance_to(before)
		if drift > 10.0:
			_log("SMOKE_SUITE ATTACK=PASS (drift=%.0fm, %ds)" % [drift, int((i + 1) * 2.5)])
			return
		if i % 4 == 3:
			_log("SMOKE_SUITE ATTACK=推进中 %ds drift=%.0fm" % [int((i + 1) * 2.5), drift])
	_log("SMOKE_SUITE ATTACK=FAIL (60s 未推进)")

	_log("SMOKE_SUITE 全链路完成")
