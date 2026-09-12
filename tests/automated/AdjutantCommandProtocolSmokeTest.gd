extends Node

## 副官双层改造第一阶段：统一命令协议冒烟测试。
## 需要以 -- --debugport <port> 启动使 DebugControlServer autoload 保持挂载。
## 验证：身份与版本校验、过期、幂等（同 ID 同参数重放/同 ID 异参数拒绝）、
## 玩家优先权（手动命令取消租约 + reacquire 显式授权）、动态生产关系校验、
## 受信任场景映射、逐条批次非原子、幂等账本背压。

const MatchScene = preload("res://tests/manual/TestAllUnits.tscn")

var _failures := 0
var _dbg: Node = null
var _match: Node = null
var _rules: Dictionary = {}
var _rules_version := ""
var _match_id := ""
var _tick := 0


func _ready():
	print("[ADJ-CMD] test start")
	_dbg = get_node_or_null("/root/DebugControlServer")
	if _dbg == null:
		push_error("Adjutant command fatal: DebugControlServer 未挂载，请用 -- --debugport 启动")
		SmokeTestExit.request(get_tree(), 1)
		return
	_match = MatchScene.instantiate()
	add_child(_match)
	await get_tree().create_timer(0.7).timeout

	var human = _match.get_node("Players/Human")
	human.add_resources({"resource_a": 10000, "resource_b": 10000}, "ScriptedAdjustment")
	_load_context()

	# ---------- 身份与授权 ----------
	_expect_reject(_submit_probe(_command({"command_id": ""})),
		"InvalidCommand", "缺 command_id 必须拒绝")
	_expect_reject(_submit_probe(_command({"match_id": ""})),
		"InvalidCommand", "缺 match_id 必须拒绝")
	_expect_reject(_submit_probe(_command({"player_id": "Ghost"})),
		"PlayerNotFound", "未知玩家必须拒绝")

	_expect_reject(_submit_probe(_command({"match_id": "00000000-0000-0000-0000-000000000000"})),
		"MatchMismatch", "错误对局身份必须拒绝")

	_expect_reject(_submit_probe(_command({"rules_version": "stale-version"})),
		"RulesVersionStale", "旧规则版本的新提交必须保守拒绝")

	_expect_reject(_submit_probe(_command({"expires_tick": 0})),
		"Expired", "非法/已过 expires_tick 的命令必须拒绝（服务器 tick 为准）")

	_expect_reject(_submit_probe(_command({"based_on_snapshot": 999999})),
		"SnapshotInFuture", "基于未来快照的命令必须拒绝")

	# ---------- move + 幂等 + 玩家优先权 ----------
	var worker = _find_unit(human, "Worker")
	_check(worker != null, "场景应有 Human Worker")
	var worker_name := str(worker.name)
	var move_params := {"units": [worker_name], "dest": [10.0, 10.0]}
	var first := _submit("move-cmd-1", "move", move_params)
	_expect_accept(first, "副官 move 应被权威接受")
	var replay := _submit("move-cmd-1", "move", move_params)
	_check(
		bool(replay.get("idempotent_replay", false))
		and str(replay.get("status", "")) == str(first.get("status", "")),
		"同 ID 同参数重放应返回原回执且不重复执行"
	)
	_expect_reject(_submit("move-cmd-1", "move", {"units": [worker_name], "dest": [99.0, 99.0]}),
		"DuplicateConflict", "同 ID 不同参数必须明确拒绝")

	# 玩家手动命令（旧 op 路径 = 绕过协调器）→ 立即取消副官租约。
	_dbg._op_move(_match, {"as_player": "Human", "units": [worker_name], "dest": [20.0, 20.0]})
	_expect_reject(_submit("move-cmd-2", "move", move_params),
		"PlayerOverride", "玩家手动接管后副官再动同一单位必须拒绝")
	var reacquired := _submit("move-cmd-3", "move",
		{"units": [worker_name], "dest": [12.0, 12.0], "reacquire": true})
	_expect_accept(reacquired, "带显式 reacquire 授权的重新接管应被接受并记录")

	# ---------- 动态生产关系与受信任场景 ----------
	var tank_scene := _scene_of_type("tank")
	_check(not tank_scene.is_empty(), "规则视图应提供 tank 受信任场景")
	_expect_reject(_submit("produce-bad-producer", "produce",
		{"producer": "CommandCenter", "scene": tank_scene}),
		"InvalidProducer", "按动态生产关系 CommandCenter 不能生产 tank")
	_expect_reject(_submit("produce-bad-scene", "produce",
		{"producer": "VehicleFactory", "scene": "res://user_evil_path.tscn"}),
		"UntrustedScene", "模型构造的任意场景路径必须拒绝")

	var produce := _submit("produce-tank-1", "produce",
		{"producer": "VehicleFactory", "scene": tank_scene})
	_expect_accept(produce, "VehicleFactory 生产 tank 应被接受（成本从当前账本扣除）")

	var factory_scene := _scene_of_type("vehicle_factory")
	# 测试准备：直接传送 worker 到开阔建造点（不经过命令路径，避免触发玩家接管语义）。
	var worker_node: Variant = _find_unit(human, worker_name)
	if worker_node != null:
		(worker_node as Node3D).global_position = Vector3(30.0, 0.0, 30.0)
		await get_tree().create_timer(0.5).timeout
	var build := _submit("build-vf-1", "build",
		{"units": [worker_name], "scene": factory_scene, "pos": [30.0, 30.0]})
	_expect_accept(build, "副官 build（服务器直执行）应被接受")

	# ---------- 逐条批次：非原子，逐条校验 ----------
	var batch: Dictionary = _dbg._op_adjutant_batch(_match, {"commands": [
		_command_body("batch-1-ok", "move", {"units": [worker_name], "dest": [11.0, 11.0]}),
		_command_body("batch-2-bad", "produce",
			{"producer": "CommandCenter", "scene": tank_scene}),
	]})
	_check(
		str(batch.get("status", "")) == "PartiallyAccepted"
		and int(batch.get("accepted_count", 0)) == 1
		and int(batch.get("rejected_count", 0)) == 1,
		"批次必须逐条接受并逐条回执（明确非原子）"
	)
	var receipts: Array = batch.get("receipts", [])
	_check(receipts.size() == 2, "批次应为每条命令返回回执")

	# ---------- 幂等账本背压：满时**显式淘汰**，绝不永久锁死指挥链 ----------
	#
	# 【2026-09-12 实机实测修正】原先这里断言"洪水必须触发 LedgerFull"。
	# 但 command_id 形如 `<match>|<intent_id>|<attempt>`、intent_id 必须带 tick，
	# 一局里只增不减；账本又是**进程级、跨对局不重建**，于是跑满 256 条后
	# **所有**后续命令一律 LedgerFull（实测同局 273/275 条回执都是 LedgerFull、0 接受，
	# 副官从此一条命令都落不了地，看起来"在跑"其实完全失效）。
	# 新契约：满时按"①先丢终态、②再丢在途"淘汰一条并在日志留痕（不静默遗忘），
	# 背压只在**实在淘汰不掉**时才作为最后手段。
	var locked_out := false
	var evicted_seen := false
	for index in range(400):
		var receipt := _submit("flood-%d" % index, "move",
			{"units": [worker_name], "dest": [13.0, 13.0], "seq": index})
		var status := str(receipt.get("status", ""))
		if status == "LedgerFull":
			evicted_seen = true          # 允许瞬时背压（同名冲突/在途保护），但不能永久
			locked_out = true
		elif status != "PendingAuthority" and not bool(receipt.get("ok", false)):
			locked_out = true
	_check(_dbg._adjutant_ledger_size() <= 256,
		"幂等账本容量必须有界（≤256），实测淘汰后应保持有界")
	# 洪水 400 条之后**仍然必须能下命令**：这才是"不锁死指挥链"的验收点。
	var tail := _submit("flood-tail", "move",
		{"units": [worker_name], "dest": [13.0, 13.0], "seq": 999})
	var tail_status := str(tail.get("status", ""))
	_check(tail_status != "LedgerFull",
		"洪水之后命令仍应被接受（实测淘汰生效；若为 LedgerFull 说明又回到永久锁死）")
	if evicted_seen:
		print("[diagnostic] 洪水期间出现过瞬时 LedgerFull（允许，未永久锁死）")
	_check(not locked_out or tail_status != "LedgerFull",
		"账本背压不得锁死指挥链")

	print("Adjutant command protocol smoke test completed: %d failure(s)" % _failures)
	_match.queue_free()
	await get_tree().process_frame
	SmokeTestExit.request(get_tree(), 0 if _failures == 0 else 1)


## 以当前对局上下文构造基础命令包。
func _command(overrides: Dictionary) -> Dictionary:
	var body := _command_body(
		str(overrides.get("command_id", "probe-%d" % randi())),
		str(overrides.get("action", "move")),
		overrides.get("params", {"units": [], "dest": [0.0, 0.0]}))
	for key in overrides.keys():
		if key in ["match_id", "player_id", "rules_version", "expires_tick", "based_on_snapshot"]:
			body[key] = overrides[key]
	return body


func _command_body(command_id: String, action: String, params: Dictionary) -> Dictionary:
	return {
		"command_id": command_id,
		"request_id": "req-%s" % command_id,
		"match_id": _match_id,
		"player_id": "Human",
		"rules_version": _rules_version,
		"based_on_snapshot": -1,
		"issued_tick": _tick,
		"expires_tick": _tick + 60000,
		"action": action,
		"params": params,
	}


func _submit(command_id: String, action: String, params: Dictionary) -> Dictionary:
	_tick = int(_dbg._adjutant_observation.CurrentServerTick())
	var body := _command_body(command_id, action, params)
	return _dbg._op_adjutant_command(_match, body)


## 提交一个已构造好的探测命令包（用于校验失败路径）。
func _submit_probe(body: Dictionary) -> Dictionary:
	return _dbg._op_adjutant_command(_match, body)


func _load_context() -> void:
	_rules = _dbg._op_rules(_match)
	_match_id = str(_rules.get("match_id", ""))
	var rules_version: Dictionary = _rules.get("rules_version", {})
	_rules_version = str(rules_version.get("content_hash", ""))
	_tick = int(_dbg._adjutant_observation.CurrentServerTick())
	_check(not _match_id.is_empty() and not _rules_version.is_empty(),
		"规则视图应提供对局身份与版本")


func _scene_of_type(type_id: String) -> String:
	for unit_type in _rules.get("unit_types", []):
		var entry := unit_type as Dictionary
		if str(entry.get("id", "")) == type_id:
			return str(entry.get("scene_path", ""))
	return ""


func _expect_accept(receipt: Dictionary, message: String) -> void:
	_check(
		bool(receipt.get("accepted", false))
		and str(receipt.get("status", "")) == "Accepted",
		"%s（实际 status=%s reason=%s）" % [
			message, str(receipt.get("status", "")), str(receipt.get("reason", ""))]
	)


func _expect_reject(receipt: Dictionary, expected_status: String, message: String) -> void:
	if not _check(
		not bool(receipt.get("accepted", true))
		and str(receipt.get("status", "")) == expected_status,
		"%s（实际 status=%s）" % [message, str(receipt.get("status", ""))]
	):
		print("[ADJ-CMD-DEBUG] receipt=", JSON.stringify(receipt))


func _find_unit(player, unit_name: String) -> Variant:
	for unit in get_tree().get_nodes_in_group("units"):
		if unit.get_parent() == player and str(unit.name) == unit_name:
			return unit
	return null


func _check(condition: bool, message: String) -> bool:
	if condition:
		return true
	_failures += 1
	push_error("Adjutant command assertion failed: %s" % message)
	return false
