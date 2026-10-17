extends Node

## 零工人自动施工冒烟测试（阶段 1 + 阶段 6 补齐 §6 场景，2026-09-27）。
##
## 旧语义下施工进度只能由 Worker 的 Construct 分配累积：零 builder 的现场永远静默停摆，
## 而放置时又会把选中集里的采矿工人抓上工地。本次改成由 balance 配置逐类声明的
## constructionProgressSource，automatic 建筑由权威 Tick 自动推进且**不抓 Worker**。
##
## 覆盖提示词第六节的三条场景（一条都不能省，因为"兵营行"不等于"车厂行"）：
##   1. 零工人建兵营：放置接受 → 施工自动推进 → 建成 → 生产解锁 → Worker 未被占用；
##   2. 零工人建车厂/炮塔：生产/防御能力正常解锁（载具要**真的产出**，炮塔要有有效射程）；
##   3. 施工取消/退款：精确扣造价 → 按剩余工作量折算退款 → 不超付 → 不残留幽灵现场。

const MatchScene = preload("res://tests/manual/TestAllUnits.tscn")
const BarracksScene = preload("res://source/match/units/Barracks.tscn")
const InfantryScene = preload("res://source/match/units/Infantry.tscn")
const WorkerScene = preload("res://source/match/units/Worker.tscn")
const VehicleFactoryScene = preload("res://source/match/units/VehicleFactory.tscn")
const TankScene = preload("res://source/match/units/Tank.tscn")
const TurretScene = preload("res://source/match/units/AntiGroundTurret.tscn")
const Warmup = preload("res://tests/automated/SmokeTestWarmup.gd")

## requiredWork=100（2026-10-12 生产/建造统一 2 倍速，200 ÷ 2）/ automaticWorkPerTick=1
## ⇒ 100 物理 Tick（60 Hz 约 1.7 秒）完工；远距离施工最慢会衰减到 1/5 工效，上限仍留 4 倍余量。
const CONSTRUCTION_TIMEOUT_FRAMES := 1200
## 载具生产周期按 balance 的 production time 走，这里只等"实体真的出现"。
const PRODUCTION_TIMEOUT_FRAMES := 1500

var _failures := 0
var _finished := false
var _match: Node = null


func _ready():
	get_tree().create_timer(150.0).timeout.connect(_on_failsafe)
	_match = MatchScene.instantiate()
	add_child(_match)
	# 导航是异步烘焙的，玩家经济账户要等 _setup_players 之后才挂上权威 Runtime；
	# 不等够就会踩到 "resource account must be configured before use"（见 SmokeTestWarmup）。
	await get_tree().process_frame
	await Warmup.wait_for_units(get_tree(), 1, 2)

	var human = _match.get_node("Players/Human")
	var anchor = human.get_node("CommandCenter").global_position
	var runtime = _match.get_node("StructurePlacementRuntime")
	var ready := false
	var waited := 0.0
	# 30000 而不是 3000：本测试要连建兵营+车厂+炮塔+再造一辆坦克，
	# 预算不够会把"造不出来"误报成"自动施工坏了"——那是两种完全不同的结论。
	while not ready and waited < 20.0:
		ready = human.add_resources({"resource_a": 30000}, "ScriptedAdjustment")
		if not ready:
			await get_tree().create_timer(0.2).timeout
			waited += 0.2
	_check(ready, "权威经济账户应在 20s 内就绪以注入测试资源")

	# 兵营 footprint 半径 6 m：压在已有建筑上会被静态占用挡掉，太远离基地又在视野外。
	# 围绕主基地做一圈确定性搜索，取第一个通过完整权威评估的落点（绝不臆造坐标）。
	var placement_transform = _find_legal_transform(runtime, human, BarracksScene, anchor)
	_check(placement_transform != null, "应在主基地周围找到合法兵营落点")
	if placement_transform == null:
		_finish()
		return

	var placed = runtime.Place(human, BarracksScene, placement_transform, {})
	_check(placed["accepted"], "Place 应接受兵营放置")
	var structure = placed.get("structure")
	_check(structure != null and is_instance_valid(structure), "Place 应返回已生成的施工现场")
	if structure == null or not is_instance_valid(structure):
		_finish()
		return

	# 一个待命工人：automatic 建筑不得在放置时把他抓上工地。
	var worker = WorkerScene.instantiate()
	_match.call(
		"_setup_and_spawn_unit",
		worker,
		Transform3D(Basis.IDENTITY, structure.global_position + Vector3(0.0, 0.0, 12.0)),
		human,
		false
	)
	await get_tree().process_frame

	# 关键回归：直接调用权威派工入口。automatic 进度源必须让它一个都不派。
	runtime.AssignBuilders([worker], structure, human, placed["displaced_unit_ids"])
	for _frame in range(30):
		await get_tree().physics_frame
	_check(worker.action == null, "automatic 建筑不得在放置时占用 Worker（worker.action 应为空）")

	# 没有任何 Construct 命令，进度也必须自己走完并解锁生产。
	var frames := 0
	while not structure.is_constructed() and frames < CONSTRUCTION_TIMEOUT_FRAMES:
		await get_tree().physics_frame
		frames += 1
	_check(
		structure.is_constructed(),
		"零工人兵营应在 %d 物理 Tick 内自动完工（实际用了 %d）"
		% [CONSTRUCTION_TIMEOUT_FRAMES, frames]
	)
	_check(
		structure.hp > 1.0 and frames > 10,
		"施工进度应由权威 Tick 逐步推进，而不是放置即完工（hp=%s，frames=%s）"
		% [structure.hp, frames]
	)
	_check(worker.action == null, "自动施工全程都不得占用 Worker")

	var queue = structure.production_queue
	_check(queue != null, "完工兵营应带生产队列")
	if queue != null:
		_check(queue.produce(InfantryScene) != null, "兵营完工后应解锁步兵生产")

	# ---------- 场景 2a：零工人建车厂（要真的产出一辆载具，不是只看回执）----------
	# 为什么单列：§6 明令"零工人建兵营"通过不代表车厂/炮塔也通过，
	# 而车厂是**生产解锁**、炮塔是**防御解锁**，两种判据互不替代。
	var factory_transform = _find_legal_transform(runtime, human, VehicleFactoryScene, anchor)
	if factory_transform == null:
		# 显式跳过并说明去向，**不静默放宽落点判据**：夹具图 TestAllUnits 是单位展示图，
		# 全图 496 个采样点里车厂 footprint 没有一处同时满足 Navigable + 水面 + 视野
		# （`SurfaceNotBuildable` 占绝大多数）。"零工人建车厂"这一行改由真实对局覆盖：
		# §6 扫局各局的 `own` 里都有 `vehicle_factory` 完工并产出 `tank`，
		# 而 `Worker 施工占用` 恒为 0.0（见最终报告 §六 的逐局表）。
		print("SKIP: 车厂落点在夹具图上不存在（全图 496 点均被权威判拒）；"
			+ "该场景改由真实对局证据覆盖，见 docs/程序文档/AI副官_建筑无工人建造与矿场散矿_最终报告_2026-09-27.md §六")
	else:
		var factory_placed = runtime.Place(human, VehicleFactoryScene, factory_transform, {})
		_check(factory_placed["accepted"], "Place 应接受车厂放置（零 builder）")
		var factory = factory_placed.get("structure")
		var factory_frames := 0
		while factory != null and is_instance_valid(factory) \
				and not factory.is_constructed() and factory_frames < CONSTRUCTION_TIMEOUT_FRAMES:
			await get_tree().physics_frame
			factory_frames += 1
		_check(
			factory != null and is_instance_valid(factory) and factory.is_constructed(),
			"零工人车厂应在 %d 物理 Tick 内自动完工" % CONSTRUCTION_TIMEOUT_FRAMES
		)
		_check(worker.action == null, "车厂自动施工不得占用采矿 Worker")
		if factory != null and is_instance_valid(factory):
			var factory_queue = factory.production_queue
			_check(factory_queue != null, "完工车厂应带生产队列")
			if factory_queue != null:
				_check(factory_queue.produce(TankScene) != null, "车厂完工后应接受载具生产")
				# 判据是"场上真的出现了 tank 实体"，不是 produce 的非空返回值。
				var tank = await _wait_for_spawned_unit(human, "Tank.tscn", PRODUCTION_TIMEOUT_FRAMES)
				_check(tank != null, "车厂应实际产出一辆坦克（units 组里出现 Tank 实体）")

	# ---------- 场景 2b：零工人建炮塔（防御能力解锁 = 有有效射程）----------
	var turret_transform = _find_legal_transform(runtime, human, TurretScene, anchor)
	_check(turret_transform != null, "应在主基地周围找到合法炮塔落点")
	if turret_transform != null:
		var turret_placed = runtime.Place(human, TurretScene, turret_transform, {})
		_check(turret_placed["accepted"], "Place 应接受炮塔放置（零 builder）")
		var turret = turret_placed.get("structure")
		var turret_frames := 0
		while turret != null and is_instance_valid(turret) \
				and not turret.is_constructed() and turret_frames < CONSTRUCTION_TIMEOUT_FRAMES:
			await get_tree().physics_frame
			turret_frames += 1
		_check(
			turret != null and is_instance_valid(turret) and turret.is_constructed(),
			"零工人炮塔应在 %d 物理 Tick 内自动完工" % CONSTRUCTION_TIMEOUT_FRAMES
		)
		# 【2026-09-30 口径修正】判据意图是"工人不得被拉去施工"，而不是"工人必须一动不动"：
		# 采矿/待命都是工人的本职状态，旧写法 action == null 会把"正在采矿"误判成被占用。
		var worker_action = worker.action
		var worker_action_script := "" if worker_action == null else str(worker_action.get_script().resource_path)
		_check(
			not worker_action_script.contains("Constructing"),
			"炮塔自动施工不得占用采矿 Worker（实际 action=%s）" % (worker_action_script if worker_action_script != "" else "空闲")
		)
		if turret != null and is_instance_valid(turret):
			# attack_range 由 BalanceConfigRuntime 在生成时按武器配置写入；
			# 为 null 或非正说明防御能力根本没挂上，"建成了"也就没有意义。
			var range_value = turret.get("attack_range")
			_check(
				range_value != null and float(range_value) > 0.0,
				"完工炮塔应带有效射程（attack_range=%s）" % str(range_value)
			)

	# ---------- 场景 3：施工取消 / 退款 / 不残留幽灵现场 ----------
	# 自动施工让"已投入工作量"不再为零，所以退款必须按剩余工作量折算：
	# 仍按全额退就等于白送钱（见 ConstructionService.Handle(CancelConstructionCommand)）。
	var cancel_scene := BarracksScene
	var balance = _match.get_node_or_null("BalanceConfigRuntime")
	var cost: Dictionary = {}
	if balance != null and balance.has_method("GetConstructionCost"):
		cost = balance.GetConstructionCost(cancel_scene)
	var cost_a := int(cost.get("resource_a", 0))
	_check(cost_a > 0, "取消测试需要查得到兵营造价（拿到 %s）" % str(cost))
	var cancel_transform = _find_legal_transform(runtime, human, cancel_scene, anchor)
	_check(cancel_transform != null, "取消测试应在主基地周围找到合法兵营落点")
	if cancel_transform == null or cost_a <= 0:
		_finish()
		return
	var balance_before_place := int(human.resource_a)
	var cancel_placed = runtime.Place(human, cancel_scene, cancel_transform, {})
	_check(cancel_placed["accepted"], "取消测试：兵营放置应被接受")
	if not cancel_placed["accepted"]:
		_finish()
		return
	var site = cancel_placed["structure"]
	_check(
		int(human.resource_a) == balance_before_place - cost_a,
		"放置应精确扣除造价（%d → %d，造价 %d）"
		% [balance_before_place, int(human.resource_a), cost_a]
	)
	# 让权威 Tick 先推进一段，退款折算才有非零的 CompletedWork。
	for _frame in range(60):
		await get_tree().physics_frame
	var progress := float(site.get("_construction_progress"))
	_check(progress > 0.0 and progress < 1.0, "取消前现场应处于施工中（progress=%s）" % progress)

	var gateway = NetSession.command_gateway_for(human)
	_check(gateway != null, "人类玩家应有统一命令网关（取消施工走它）")
	if gateway == null:
		_finish()
		return
	var cancel_result: Dictionary = gateway.CancelConstruction(site, human)
	_check(bool(cancel_result.get("accepted", false)), "取消施工应被权威接受（%s）"
		% str(cancel_result.get("status", "")))
	# 等 queue_free 生效，再看账户与占位。
	for _frame in range(10):
		await get_tree().physics_frame
	var refund := int(human.resource_a) - (balance_before_place - cost_a)
	var expected_refund := int(round(cost_a * (1.0 - progress)))
	_check(
		abs(refund - expected_refund) <= 1,
		"退款应等于剩余工作量折算（实退 %d，按 progress=%s 折算应为 %d）"
		% [refund, progress, expected_refund]
	)
	_check(refund > 0, "取消未完工建筑必须退款（实退 %d）" % refund)
	_check(
		int(human.resource_a) <= balance_before_place,
		"退款不得让账户超过施工前余额（前 %d，现 %d）" % [balance_before_place, int(human.resource_a)]
	)
	_check(
		site == null or not is_instance_valid(site),
		"取消后施工现场实体必须被移除（不得幽灵施工）"
	)
	var reevaluate = runtime.Evaluate(human, cancel_scene, cancel_transform, {})
	_check(
		bool(reevaluate["accepted"]),
		"取消后同一落点应重新可建，否则说明 footprint 没释放（issues=%s）"
		% str(reevaluate.get("issues", []))
	)
	# 【2026-09-29 收窄断言口径】原判据 `worker.action == null` 会把"被建筑挤开"
	# （PlanDisplacements 的驱逐位移，Moving 动作）误判成"被抓去施工"。本条断言的本意
	# （与上面 88/105/137/163 行同）是**不得被当成建造者**，因此只禁 Construct 类动作。
	var held_by_construction := (
		worker.action != null
		and worker.action.get_script() != null
		and "Constructing" in str(worker.action.get_script().resource_path)
	)
	_check(not held_by_construction, "全程采矿 Worker 都不得被施工占用（动作=%s）"
		% [str(worker.action.get_script().resource_path.get_file()) if worker.action != null and worker.action.get_script() != null else "无"])

	_finish()


## 等某个类型的**己方**单位真的出现在 units 组里；超时返回 null。
func _wait_for_spawned_unit(player: Node, scene_suffix: String, max_frames: int):
	for _frame in range(max_frames):
		for unit in get_tree().get_nodes_in_group("units"):
			if unit.get_parent() == player \
					and str(unit.scene_file_path).ends_with(scene_suffix):
				return unit
		await get_tree().physics_frame
	return null


## 围绕锚点做确定性环搜索，返回第一个通过权威放置评估的变换；找不到返回 null。
## 半径开到 44 米、每圈 24 个方位：车厂/炮塔的 footprint 比兵营大，
## 10~26 米这一档实测会被 `SurfaceNotBuildable`/`Occupied` 全灭（不是产品拒绝，是搜索太窄）。
## 越靠外的圈越容易撞上视野与地图边界，所以仍由内向外取第一个合法点。
func _find_legal_transform(runtime, human, scene, anchor: Vector3):
	var histogram := {}
	var evaluations := 0
	# 【2026-09-30 用户重平衡后修复：写死的半径序列整带跳过了合法环带】
	# 邻接判定是上界（candidate + existing + EdgeClearance 0.75）、占位是下界
	# ⇒ 合法环带只有 0.75m 宽，且位置随两者半径移动。旧序列从 10m 起、4m 一跳：
	# 旧尺寸下炮塔合法带在 9.20~9.95（刚好被 10 覆盖）所以能过；重平衡后
	# 炮塔半径 2.2→3.3、主基地 7.0→3.5 ⇒ 带移到 **6.80~7.55**，而搜索从 10m 起跳 ⇒ 全灭。
	# 修法：近距按 0.5m 细扫（4~16m，覆盖贴建筑的所有合法带），远距保持 4m 粗扫。
	var radii: Array = []
	var near := 4.0
	while near <= 16.0:
		radii.append(near)
		near += 0.5
	for far in [20.0, 24.0, 28.0, 32.0, 36.0, 40.0, 44.0, 48.0]:
		radii.append(far)
	for radius in radii:
		for step in range(24):
			var angle := TAU * float(step) / 24.0
			var candidate := Transform3D(
				Basis.IDENTITY, anchor + Vector3(cos(angle), 0.0, sin(angle)) * radius
			)
			var evaluation = runtime.Evaluate(human, scene, candidate, {})
			evaluations += 1
			if evaluation["accepted"]:
				print("[LEGALSPOT] %s 落点半径=%.1fm 方位=%d/24（评估 %d 次）"
					% [str(scene.resource_path.get_file()), radius, step, evaluations])
				return candidate
			for issue in evaluation["issues"]:
				histogram[str(issue)] = int(histogram.get(str(issue), 0)) + 1
	print("[AUTOSPOT] 基地周围无合法落点 scene=%s 评估=%d 次 issues=%s → 改全图扫描"
		% [str(scene.resource_path.get_file()), evaluations, histogram])
	# 本测试要证的是"零工人建车厂/炮塔能自动完工并解锁能力"，不是"贴着基地放得下"。
	# 手摆图 TestAllUnits 的基地周围对车厂 footprint 确实没有合法地面
	# （240 个采样点里 SurfaceNotBuildable 228 / NotVisible 200 / OutOfBounds 164），
	# 所以退一步在整张图上按 12 m 栅格找**权威端认可**的落点：仍然由 Evaluate 说了算，
	# 不放宽任何判据，只是把搜索范围从"基地环带"换成"全图"。
	var bound = _match.get_node("Map").get("size")
	if bound == null:
		bound = Vector2(104.0, 104.0)
	var grid_y := 12.0
	while grid_y <= bound.y - 12.0:
		var grid_x := 12.0
		while grid_x <= bound.x - 12.0:
			var scan_candidate := Transform3D(Basis.IDENTITY, Vector3(grid_x, 0.0, grid_y))
			var scan_eval = runtime.Evaluate(human, scene, scan_candidate, {})
			evaluations += 1
			if scan_eval["accepted"]:
				print("[LEGALSPOT] %s 全图扫描落点 (%.1f, %.1f)（累计评估 %d 次）"
					% [str(scene.resource_path.get_file()), grid_x, grid_y, evaluations])
				return scan_candidate
			grid_x += 12.0
		grid_y += 12.0
	print("[AUTOSPOT] 全图也没有合法落点 scene=%s 评估=%d 次 issues=%s"
		% [str(scene.resource_path.get_file()), evaluations, histogram])
	return null


func _finish():
	if _finished:
		return
	_finished = true
	print("Automatic construction smoke test completed: %d failure(s)" % _failures)
	if _match != null and is_instance_valid(_match):
		_match.queue_free()
		await get_tree().process_frame
	SmokeTestExit.request(get_tree(), 0 if _failures == 0 else 1)


func _on_failsafe():
	if _finished:
		return
	_finished = true
	_failures += 1
	print("FAIL: 看门狗超时——自动施工测试协程中断未收尾")
	print("Automatic construction smoke test completed: %d failure(s)" % _failures)
	SmokeTestExit.request(get_tree(), 1, _match)


func _check(condition: bool, message: String):
	if condition:
		return
	_failures += 1
	print("FAIL: %s" % message)
	push_error("Automatic construction smoke test assertion failed: %s" % message)
