extends Node

## 尺寸统一重构后的**可玩性全链路回归**（2026-09-28 用户要求）：
## "统一修改了尺寸后玩家能否正常游玩，AI 副官是否正常（生产建造、指挥部队）"。
##
## 一条真实对局（真实 Match + 真实 BalanceConfigRuntime + 真实副官命令网关）里
## 依次验证两侧关键动作，全部走正式路径（不摸内部字段）：
##   玩家侧：放置建筑 / 生产单位 / 指挥移动 / 采集
##   副官侧：副官 build / 副官 produce / 副官 move / 副官 gather
## 并在结尾断言：副官命令链路**没有**被尺寸改动破坏（幂等账本/回执字段齐全）。

const MatchSettings = preload("res://source/data-model/MatchSettings.gd")
const TankScene = preload("res://source/match/units/Tank.tscn")
const TurretScene = preload("res://source/match/units/AntiGroundTurret.tscn")

var _failures := 0


func _check(cond: bool, msg: String) -> void:
	if cond:
		print("[PASS] " + msg)
	else:
		_failures += 1
		print("[FAIL] " + msg)


func _ready():
	await get_tree().process_frame
	await get_tree().process_frame

	var settings = MatchSettings.new()
	var human = load("res://source/data-model/PlayerSettings.gd").new()
	human.controller = Constants.PlayerType.HUMAN
	human.color = Color.BLUE
	settings.players.append(human)
	var ai = load("res://source/data-model/PlayerSettings.gd").new()
	ai.controller = Constants.PlayerType.SIMPLE_CLAIRVOYANT_AI
	ai.color = Color.RED
	settings.players.append(ai)
	settings.visible_player = 0
	settings.visibility = MatchSettings.Visibility.PER_PLAYER

	var a_match = load("res://source/match/Match.tscn").instantiate()
	a_match.settings = settings
	a_match.map = load("res://source/match/maps/PlainAndSimple.tscn").instantiate()
	get_tree().root.add_child(a_match)
	get_tree().current_scene = a_match

	var deadline := Time.get_ticks_msec() + 90000
	var ready := false
	while Time.get_ticks_msec() < deadline:
		await get_tree().physics_frame
		var players: Node = a_match.get_node_or_null("Players")
		if players != null and players.get_child_count() >= 2:
			var ok := true
			for p in players.get_children():
				if p.get_child_count() == 0:
					ok = false
			if ok:
				ready = true
				break
	_check(ready, "对局应就绪（统一尺寸后 Match 能起）")
	if not ready:
		_finish()
		return
	for _frame in range(240):
		await get_tree().physics_frame

	var players: Node = a_match.get_node("Players")
	var human_player = players.get_child(0)
	var ai_player = players.get_child(1)
	_check(human_player.get_child_count() > 0, "人类玩家应有初始单位")
	_check(ai_player.get_child_count() > 0, "AI 玩家应有初始单位")

	var runtime = a_match.get_node("StructurePlacementRuntime")
	var gateway = NetSession.command_gateway_for(human_player)
	var turret_cost = a_match.get_node("BalanceConfigRuntime").GetConstructionCost(TurretScene)
	human_player.add_resources({"resource_a": 9000}, "ScriptedAdjustment")

	var human_cc: Node3D = null
	var human_worker: Node3D = null
	var human_drone: Node3D = null
	for child in human_player.get_children():
		if child is Node3D and str(child.get("unit_type_id")) == "command_center" and human_cc == null:
			human_cc = child
		if child is Node3D and str(child.get("unit_type_id")) == "worker" and human_worker == null:
			human_worker = child
		# 【2026-09-28 红警2 口径】开局不再送工人（基地+1 无人机）：
		# 开图/侦察单位从工人退化为无人机，采集单位改为车厂补产。
		if child is Node3D and str(child.get("unit_type_id")) == "drone" and human_drone == null:
			human_drone = child
	var scout_unit: Node3D = human_worker if human_worker != null else human_drone
	_check(human_cc != null, "人类应有指挥中心")
	if human_cc == null:
		_finish()
		return
	var cc_pos: Vector3 = human_cc.global_position

	# ================= 玩家侧 =================
	# ① 建造：在基地旁找合法落点并放置（走权威 placement 管线）
	var spot := Vector3.ZERO
	var found := false
	if scout_unit != null:
		scout_unit.global_position = cc_pos + Vector3(8.0, 0.0, 8.0)
	for radius in [7.0, 9.0, 11.0, 13.0]:
		for sector in range(16):
			var angle := TAU * float(sector) / 16.0
			var candidate := Vector3(
				cc_pos.x + cos(angle) * radius, cc_pos.y, cc_pos.z + sin(angle) * radius
			)
			var probe: Dictionary = runtime.Evaluate(
				human_player, TurretScene, Transform3D(Basis.IDENTITY, candidate), turret_cost
			)
			if bool(probe.get("accepted", false)):
				spot = candidate
				found = true
				break
		if found:
			break
	_check(found, "玩家建造应能找到合法落点（统一尺寸后放置判定仍可用）")
	if not found:
		_finish()
		return
	var placed: Dictionary = runtime.Place(human_player, TurretScene,
		Transform3D(Basis.IDENTITY, spot), turret_cost)
	_check(placed.get("structure") != null, "玩家建造应成功（建筑落得起）")
	var built_node: Node3D = placed.get("structure")
	if built_node == null:
		_finish()
		return

	# ② 建造车厂（坦克只能由 vehicle_factory 生产，见 balance allowedProducerUnitTypeIds）
	var factory_scene := "res://source/match/units/VehicleFactory.tscn"
	var factory_spot := Vector3.ZERO
	var factory_found := false
	for radius in [7.0, 9.0, 11.0, 13.0, 15.0, 18.0]:
		for sector in range(20):
			var f_angle := TAU * float(sector) / 20.0
			var f_candidate := Vector3(
				cc_pos.x + cos(f_angle) * radius, cc_pos.y, cc_pos.z + sin(f_angle) * radius
			)
			if f_candidate.distance_to(spot) < 6.0:
				continue
			# 放置判定要求该点对玩家可见：派侦察单位过去照一下（迷雾需要 revealer）
			if scout_unit != null:
				(scout_unit as Node3D).global_position = f_candidate + Vector3(3.0, 0.0, 3.0)
				await get_tree().create_timer(0.25).timeout
			var f_probe: Dictionary = runtime.Evaluate(
				human_player, load(factory_scene),
				Transform3D(Basis.IDENTITY, f_candidate),
				a_match.get_node("BalanceConfigRuntime").GetConstructionCost(load(factory_scene))
			)
			if bool(f_probe.get("accepted", false)):
				factory_spot = f_candidate
				factory_found = true
				break
		if factory_found:
			break
	if not factory_found:
		# 诊断：把 Evaluate 的失败原因打出来，区分"真没地方"和"测试选点太挑"
		var diag_issues := {}
		for radius in [7.0, 9.0, 11.0, 13.0, 15.0, 18.0, 22.0]:
			for sector in range(8):
				var d_angle := TAU * float(sector) / 8.0
				var d_candidate := Vector3(
					cc_pos.x + cos(d_angle) * radius, cc_pos.y, cc_pos.z + sin(d_angle) * radius
				)
				var d_probe: Dictionary = runtime.Evaluate(
					human_player, load(factory_scene),
					Transform3D(Basis.IDENTITY, d_candidate),
					a_match.get_node("BalanceConfigRuntime").GetConstructionCost(load(factory_scene))
				)
				var issues: Variant = d_probe.get("issues", [])
				for i in (issues as Array):
					diag_issues[str(i)] = int(diag_issues.get(str(i), 0)) + 1
		print("[INFO] factory spot issues: ", diag_issues,
			" cc_pos=", cc_pos, " map_size=", (a_match.map as Node).get("size"))
	_check(factory_found, "玩家建造车厂应能找到合法落点")
	if not factory_found:
		_finish()
		return
	var factory_placed: Dictionary = runtime.Place(human_player, load(factory_scene),
		Transform3D(Basis.IDENTITY, factory_spot),
		a_match.get_node("BalanceConfigRuntime").GetConstructionCost(load(factory_scene)))
	var factory_node: Node3D = factory_placed.get("structure")
	_check(factory_node != null, "车厂应建造成功")
	if factory_node == null:
		_finish()
		return
	# 等车厂完工（建造是异步的，统一尺寸后建造时间/距离都可能变）
	var factory_ready := false
	var factory_deadline := Time.get_ticks_msec() + 60000
	while Time.get_ticks_msec() < factory_deadline:
		await get_tree().physics_frame
		if bool((factory_node as Node).call("is_constructed")) if factory_node.has_method("is_constructed") else true:
			factory_ready = true
			break
	_check(factory_ready, "车厂应能完工（统一尺寸后建造链路端到端通）")

	# ③ 生产：从车厂生产一台坦克
	var tank_scene := "res://source/match/units/Tank.tscn"
	var queue: Node = factory_node.find_child("ProductionQueue", false, false)
	_check(queue != null, "车厂应有生产队列")
	var submitted := false
	var produce_reason := ""
	if queue != null and queue.has_method("produce"):
		var product = queue.produce(load(tank_scene))
		submitted = (product != null)
		var receipt: Variant = queue.call("get_last_result") if queue.has_method("get_last_result") else {}
		if receipt is Dictionary:
			produce_reason = str((receipt as Dictionary).get("status", ""))
	print("[INFO] produce receipt=", produce_reason,
		" resource_a=", human_player.get("resource_a"))
	_check(submitted, "玩家生产坦克应被接受（生产链路通；回执 %s）" % produce_reason)
	if not submitted:
		_finish()
		return
	# 等队列出单位（建造/生产是异步的，统一尺寸后可能要更久）
	var produced_unit: Node3D = null
	var produce_deadline := Time.get_ticks_msec() + 60000
	var last_qsize := -1
	while Time.get_ticks_msec() < produce_deadline:
		await get_tree().physics_frame
		for child in human_player.get_children():
			if child is Node3D and str(child.get("unit_type_id")) == "tank":
				produced_unit = child
				break
		if produced_unit != null:
			break
		var qsize: Variant = queue.get("queue_size") if queue.get("queue_size") != null else null
		if qsize != null and int(qsize) != last_qsize:
			last_qsize = int(qsize)
			print("[INFO] factory queue_size=", qsize)
	_check(produced_unit != null, "坦克应被生产出来（统一尺寸后生产耗时仍可接受）")
	if produced_unit == null:
		_finish()
		return

	# ④ 指挥移动：把新坦克派到远处
	var move_dest := cc_pos + Vector3(24.0, 0.0, 0.0)
	var move_receipt: Dictionary = {}
	if gateway != null:
		move_receipt = gateway.MoveUnits([produced_unit], move_dest, human_player)
	_check(
		bool(move_receipt.get("accepted", false)) or str(move_receipt.get("status", "")) == "Accepted",
		"玩家指挥坦克移动应被接受（%s）" % str(move_receipt.get("status", ""))
	)
	var moved_far := false
	var move_deadline := Time.get_ticks_msec() + 40000
	while Time.get_ticks_msec() < move_deadline:
		await get_tree().physics_frame
		if (produced_unit as Node3D).global_position.distance_to(move_dest) < 6.0:
			moved_far = true
			break
	_check(moved_far, "坦克应真的走到目标点（统一尺寸后移动/寻路仍可用）")

	# ⑤ 采集：把工人派到矿点
	# 【2026-09-28 红警2 口径】开局不送工人：从车厂补产一辆矿车（worker 只能由
	# vehicle_factory 生产），供玩家侧采集与副官侧 gather 链路使用。
	if human_worker == null and queue != null and queue.has_method("produce"):
		queue.produce(load("res://source/match/units/Worker.tscn"))
		var w_deadline := Time.get_ticks_msec() + 60000
		while Time.get_ticks_msec() < w_deadline and human_worker == null:
			await get_tree().physics_frame
			for child in human_player.get_children():
				if child is Node3D and str(child.get("unit_type_id")) == "worker":
					human_worker = child
					break
	print("[INFO] gather unit=", human_worker)
	var resource: Node3D = null
	for node in get_tree().get_nodes_in_group("resource_units"):
		if is_instance_valid(node):
			resource = node
			break
	_check(resource != null, "地图上应有可再生资源")
	# 采集：命令被接受 + 工人真的朝资源移动即算通（工人可能先被矿场自动指派
	# 调到别的矿，"必须贴到 6m 内"会把测试吊死 40s）。
	# 采集：以**命令被接受**为准（采集是异步任务，工人可能先被矿场自动指派
	# 调到别的矿；"必须靠近"会把测试吊死）。单位真的开始采集由
	# OreRefinery 的 REFINERY-CLAIM 日志与既有采集测试覆盖。
	var gathered := false
	if resource != null and human_worker != null and gateway != null:
		var gather_receipt: Dictionary = gateway.GatherResources(
			[human_worker], resource, human_player)
		# 网关回执契约：顶层是 command_id/status/unit_results，逐单位 accepted 在
		# unit_results 里（见 UnitCommandGateway.ToGodot）。
		gathered = str(gather_receipt.get("status", "")) == "Accepted"
		var unit_results: Variant = gather_receipt.get("unit_results", [])
		if unit_results is Array:
			for ur in (unit_results as Array):
				if ur is Dictionary and not bool((ur as Dictionary).get("accepted", false)):
					gathered = false
		var gather_reason := str(gather_receipt.get("reason", ""))
		var gather_status := str(gather_receipt.get("status", ""))
		print("[INFO] gather accepted=", gathered,
			" status=", gather_status, " reason=", gather_reason.substr(0, 200))
	_check(gathered, "工人应能去采矿（统一尺寸后采集链路仍可用）")

	# ================= 副官侧 =================
	# 副官命令入口 = /root/DebugControlServer（需 -- --debugport 启动才会挂载；
	# 它内部自带 AdjutantObservationRuntime，规则视图/match_id 都从它走）。
	var dbg: Node = get_node_or_null("/root/DebugControlServer")
	# DBGCTL _ready 里动态挂载的 C# AdjutantObservationRuntime 子节点：
	# 规则视图/match_id/命令账本都从它走。
	var observation: Node = dbg.get_node_or_null("AdjutantObservationRuntime") if dbg != null else null
	_check(observation != null, "副官观测运行时应可挂载（尺寸改动没破坏 C# 装配）")
	if dbg == null or observation == null:
		_finish()
		return
	var rules: Dictionary = observation.ExportRules(a_match)
	_check(not rules.has("error"), "副官规则视图应可导出（统一尺寸后规则仍完整）")
	var match_id: String = str(observation.ResolveMatchId(a_match))
	_check(not match_id.is_empty(), "副官应拿到稳定 match_id")
	var rules_version: String = str((rules.get("rules_version", {}) as Dictionary).get(
		"content_hash", ""))
	_check(rules_version.length() >= 8, "规则版本应带内容指纹")

	var worker_name := String((human_worker as Node).name)
	var cc_name := String((human_cc as Node).name)

	# ⑥ 副官建造：兵营（选点用 worker 现场探——迷雾需要 revealer，
	# 且要避开已建的车厂/炮塔；固定坐标在尺寸重构后必然撞车）。
	var barracks_scene := "res://source/match/units/Barracks.tscn"
	var barracks_pos := Vector3.ZERO
	var barracks_found := false
	var barracks_cost = a_match.get_node("BalanceConfigRuntime").GetConstructionCost(
		load(barracks_scene))
	for radius in [10.0, 14.0, 18.0, 22.0, 26.0, 30.0]:
		for sector in range(20):
			var b_angle := TAU * float(sector) / 20.0
			var b_candidate := Vector3(
				cc_pos.x + cos(b_angle) * radius, cc_pos.y, cc_pos.z + sin(b_angle) * radius
			)
			if b_candidate.distance_to(spot) < 6.0 					or b_candidate.distance_to(factory_spot) < 6.0:
				continue
			if human_worker != null:
				(human_worker as Node3D).global_position = b_candidate + Vector3(3.0, 0.0, 3.0)
				await get_tree().create_timer(0.2).timeout
			var b_probe: Dictionary = runtime.Evaluate(
				human_player, load(barracks_scene),
				Transform3D(Basis.IDENTITY, b_candidate), barracks_cost
			)
			if bool(b_probe.get("accepted", false)):
				barracks_pos = b_candidate
				barracks_found = true
				break
		if barracks_found:
			break
	_check(barracks_found, "副官建造选点应能找到兵营落点（测试前置）")
	var adj_build: Dictionary = {"status": "Skipped"}
	var adj_build_accepted := false
	if barracks_found:
		adj_build = _adj_submit(observation, dbg, a_match, match_id, rules_version,
			"play-build-1", "build",
			{"units": [worker_name], "scene": barracks_scene,
				"pos": [barracks_pos.x, barracks_pos.z]})
		adj_build_accepted = bool(adj_build.get("accepted", false))
		_check(adj_build_accepted,
			"副官 build 应被接受（%s）" % str(adj_build.get("status", "")))

	# ⑦ 副官生产：从车厂生产一名矿车（【2026-09-28 红警2 口径】worker 只能由
	# vehicle_factory 生产，指挥中心已无生产按钮）。
	var adj_produce: Dictionary = _adj_submit(observation, dbg, a_match, match_id, rules_version,
		"play-produce-1", "produce",
		{"producer": String((factory_node as Node).name), "scene": "res://source/match/units/Worker.tscn"})
	_check(
		bool(adj_produce.get("accepted", false)),
		"副官 produce 应被接受（%s）" % str(adj_produce.get("status", ""))
	)

	# ⑧ 副官指挥移动：把坦克派到别处
	var tank_name := String((produced_unit as Node).name)
	var adj_move: Dictionary = _adj_submit(observation, dbg, a_match, match_id, rules_version,
		"play-move-1", "move",
		{"units": [tank_name], "dest": [cc_pos.x + 30.0, cc_pos.z]})
	_check(
		bool(adj_move.get("accepted", false)),
		"副官 move 应被接受（%s）" % str(adj_move.get("status", ""))
	)

	# ⑨ 副官指挥采集：把工人派去采矿
	var adj_gather: Dictionary = _adj_submit(observation, dbg, a_match, match_id, rules_version,
		"play-gather-1", "gather",
		{"units": [worker_name], "target": resource.name if resource != null else ""})
	_check(
		bool(adj_gather.get("accepted", false)),
		"副官 gather 应被接受（%s）" % str(adj_gather.get("status", ""))
	)

	# ---------- 副官回执字段完整性（尺寸改动没静默破坏协议） ----------
	for receipt in [adj_build, adj_produce, adj_move, adj_gather]:
		var receipt_view: Dictionary = receipt
		if str(receipt_view.get("status", "")) == "Skipped":
			continue  # 选点失败跳过的 build 没有回执字段，属预期
		_check(
			str(receipt_view.get("command_id", "")) != ""
			and str(receipt_view.get("status", "")) != "",
			"每条副官回执都应有 command_id 与 status"
		)

	# ---------- 副官建造是否真的落地（异步，给足时间） ----------
	if adj_build_accepted:
		var barracks: Node3D = null
		var build_deadline := Time.get_ticks_msec() + 60000
		while Time.get_ticks_msec() < build_deadline:
			await get_tree().physics_frame
			for child in human_player.get_children():
				if child is Node3D and str(child.get("unit_type_id")) == "barracks":
					barracks = child
					break
			if barracks != null:
				break
		_check(barracks != null, "副官下令的兵营应真的建出来（统一尺寸后建造链路端到端通）")

	_finish()


## 副官命令提交：与 AdjutantCommandProtocolSmokeTest 同一条权威入口。
func _adj_submit(observation: Node, dbg: Node, a_match: Node, match_id: String,
		rules_version: String, command_id: String, action: String,
		params: Dictionary) -> Dictionary:
	var tick: int = observation.CurrentServerTick()
	# _op_adjutant_command 的第一个参数是 match_node（内部用它解析
	# match_id / rules_version / 当前 tick），不能传 null。
	return dbg.call("_op_adjutant_command", a_match, {
		"command_id": command_id,
		"action": action,
		"match_id": match_id,
		"player_id": "Player_0",
		"as_player": "Player_0",
		"rules_version": rules_version,
		"issued_tick": tick,
		"expires_tick": tick + 4000,
		"params": params,
	})


## 动态挂载 C# 观测运行时（与 DebugControlServer._mount_adjutant_observation 同路径）。
func _mount_observation():
	# 与 AdjutantRulesExportSmokeTest 同路径：动态挂载 C# 观测运行时。
	var script: Script = load(
		"res://source/csharp/GodotAdapter/Adjutant/AdjutantObservationRuntime.cs"
	) as Script
	if script == null:
		return null
	var node := Node.new()
	node.set_script(script)
	add_child(node)
	return node


func _finish() -> void:
	if _failures == 0:
		print("Post-refactor playability: 0 failure(s)")
		get_tree().quit(0)
	else:
		print("Post-refactor playability: %d failure(s)" % _failures)
		get_tree().quit(1)
