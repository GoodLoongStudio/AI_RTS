extends Node

## 零工人自动施工冒烟测试（阶段 1，2026-09-27）。
##
## 旧语义下施工进度只能由 Worker 的 Construct 分配累积：零 builder 的现场永远静默停摆，
## 而放置时又会把选中集里的采矿工人抓上工地。本次改成由 balance 配置逐类声明的
## constructionProgressSource，automatic 建筑由权威 Tick 自动推进且**不抓 Worker**。
## 这里跑真实对局链路验证四件事：放置接受、无人施工也自动完工、生产解锁、采矿工人不被占用。

const MatchScene = preload("res://tests/manual/TestAllUnits.tscn")
const BarracksScene = preload("res://source/match/units/Barracks.tscn")
const InfantryScene = preload("res://source/match/units/Infantry.tscn")
const WorkerScene = preload("res://source/match/units/Worker.tscn")
const Warmup = preload("res://tests/automated/SmokeTestWarmup.gd")

## requiredWork=200 / automaticWorkPerTick=1 ⇒ 200 物理 Tick（60 Hz 约 3.3 秒）完工。
## 给 4 倍余量吸收导航烘焙与首帧抖动。
const CONSTRUCTION_TIMEOUT_FRAMES := 1200

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
	while not ready and waited < 20.0:
		ready = human.add_resources({"resource_a": 3000}, "ScriptedAdjustment")
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

	_finish()


## 围绕锚点做确定性环搜索，返回第一个通过权威放置评估的变换；找不到返回 null。
func _find_legal_transform(runtime, human, scene, anchor: Vector3):
	var issues_seen := {}
	for radius in [10.0, 14.0, 18.0, 22.0, 26.0]:
		for step in range(12):
			var angle := TAU * float(step) / 12.0
			var candidate := Transform3D(
				Basis.IDENTITY, anchor + Vector3(cos(angle), 0.0, sin(angle)) * radius
			)
			var evaluation = runtime.Evaluate(human, scene, candidate, {})
			if evaluation["accepted"]:
				return candidate
			issues_seen[str(evaluation["issues"])] = true
	print("[AUTOSPOT] 无合法落点，收集到的 issues=", issues_seen.keys())
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
