extends Node

## 同类建筑经济规则冒烟测试（2026-09-29 用户规则）。
##
## 覆盖三条新机制（比例来自 balance 的 sameTypeBonusPerExtraBuilding = 0.5）：
##   1. 一次只能建造一个建筑：工地在建时第二个 Place 必须被权威拒绝
##      （primary_issue == "ConstructionInProgress"）；完工/取消后立即可再建。
##   2. 同类建筑加速出兵：两座兵营完工后，各自 production_work_per_tick = 1.5，
##      且真实产兵耗时按 60 × (2/3) = 40 Tick 缩短（不是只看属性值）。
##   3. 主基地加速施工：第二座主基地完工后，下一个建筑施工从 100 Tick 缩到 ~67 Tick。
##      夹具图上主基地可能没有合法落点（车厂就曾全图无落点），落点缺失时显式 SKIP，
##      不静默放宽判据——该机制另有纯 C# 回归（ConstructionServiceTests.RatePortScalesAutomaticWork）。

const MatchScene = preload("res://tests/manual/TestAllUnits.tscn")
const BarracksScene = preload("res://source/match/units/Barracks.tscn")
const CommandCenterScene = preload("res://source/match/units/CommandCenter.tscn")
const InfantryScene = preload("res://source/match/units/Infantry.tscn")
const Warmup = preload("res://tests/automated/SmokeTestWarmup.gd")

## requiredWork=100（2026-10-12 统一 2 倍速，200 ÷ 2）/ automaticWorkPerTick=1 ⇒ 100 物理 Tick 完工。
## 上限仍留 1200：远距离部署的自动工效会被 DistanceScaledWorkPerTick 衰减到 1/5，最慢 500 Tick。
const CONSTRUCTION_TIMEOUT_FRAMES := 1200
## 步兵 requiredWork=60：基线 60 Tick，1.5 倍速应为 40 Tick；阈值取两者中点偏严。
const INFANTRY_BASELINE_FRAMES := 65
const INFANTRY_BONUS_LIMIT_FRAMES := 52
## 100 Tick 的建筑在 1.5 倍施工速率下 ≈67 Tick 完成；阈值必须能区分 67 与 100。
const CONSTRUCTION_RATE_LIMIT_FRAMES := 85
## 主基地完工超时（与其它建筑同 requiredWork 口径）。
const CC_TIMEOUT_FRAMES := 1200

var _failures := 0
var _finished := false
var _match: Node = null


func _ready():
	get_tree().create_timer(240.0).timeout.connect(_on_failsafe)
	_match = MatchScene.instantiate()
	add_child(_match)
	await get_tree().process_frame
	await Warmup.wait_for_units(get_tree(), 1, 2)

	var human = _match.get_node("Players/Human")
	var anchor = human.get_node("CommandCenter").global_position
	var runtime = _match.get_node("StructurePlacementRuntime")
	var ready := false
	var waited := 0.0
	while not ready and waited < 20.0:
		ready = human.add_resources({"resource_a": 60000}, "ScriptedAdjustment")
		if not ready:
			await get_tree().create_timer(0.2).timeout
			waited += 0.2
	_check(ready, "权威经济账户应在 20s 内就绪以注入测试资源")

	# ---------- 场景 1：一次只能建造一个建筑 ----------
	var barracks1_transform = _find_legal_transform(runtime, human, BarracksScene, anchor)
	_check(barracks1_transform != null, "应找到第一座兵营的合法落点")
	if barracks1_transform == null:
		_finish()
		return
	var placed1 = runtime.Place(human, BarracksScene, barracks1_transform, {})
	_check(placed1["accepted"], "第一座兵营应被接受")
	var barracks1 = placed1.get("structure")

	# 工地在建期间，第二个放置必须被权威拒绝。
	var barracks2_transform = _find_legal_transform(runtime, human, BarracksScene, anchor)
	var rejected = runtime.Place(human, BarracksScene, barracks2_transform, {})
	_check(
		not bool(rejected.get("accepted", true))
		and str(rejected.get("primary_issue", "")) == "ConstructionInProgress",
		"在建期间第二个放置应被拒绝且 primary_issue=ConstructionInProgress（实际 %s）"
			% str(rejected.get("primary_issue", ""))
	)

	var frames1: int = await _wait_constructed(barracks1)
	_check(barracks1 != null and is_instance_valid(barracks1) and barracks1.is_constructed(),
		"第一座兵营应在超时前自动完工（frames=%d）" % frames1)

	# 完工后并发额度立即释放。落点重新搜索：刚才的候选在兵营完工（占位/导航变化）
	# 后可能不再满足世界层判据，这属于正常选址行为，不代表并发规则没释放。
	var busy_after: bool = runtime.HasActiveConstructionSite(human)
	_check(not busy_after, "第一座完工后 HasActiveConstructionSite 应立即为 false")
	var placed2 = null
	var barracks2 = null
	for attempt in range(3):
		var fresh_transform = _find_legal_transform(runtime, human, BarracksScene, anchor)
		if fresh_transform == null:
			break
		placed2 = runtime.Place(human, BarracksScene, fresh_transform, {})
		if bool(placed2.get("accepted", false)):
			barracks2 = placed2.get("structure")
			break
		print("[DIAG] 落点完工后失效被拒（预期内的选址重试）：%s"
			% str(placed2.get("primary_issue", "")))
	_check(placed2 != null and bool(placed2.get("accepted", false)),
		"第一座完工后应能立刻开始第二座兵营（并发额度已释放）")
	var frames2: int = 0
	if barracks2 != null:
		frames2 = await _wait_constructed(barracks2)
		_check(barracks2.is_constructed(),
			"第二座兵营应在超时前自动完工（frames=%d）" % frames2)

	# ---------- 场景 2：同类建筑加速出兵（×1.5）----------
	if barracks1 != null and is_instance_valid(barracks1) and barracks2 != null \
			and is_instance_valid(barracks2):
		var rate1 := float(barracks1.get("production_work_per_tick"))
		var rate2 := float(barracks2.get("production_work_per_tick"))
		_check(absf(rate1 - 1.5) < 0.01 and absf(rate2 - 1.5) < 0.01,
			"两座完工兵营的 production_work_per_tick 都应是 1.5（实际 %s / %s）"
				% [str(rate1), str(rate2)])
		# 真实生产计时：60 工作量 ÷ 1.5 = 40 Tick，明显快于基线 60。
		# 判据用"队首工作量打满"而不是"实体出现"：部署要过导航找位，会踩到
		# 并行会话在飞的导航改动（NavigationAgent3D 报错），与生产速度无关。
		var queue1 = barracks1.production_queue
		_check(queue1 != null and queue1.produce(InfantryScene) != null, "兵营应接受步兵生产")
		var full_frames: int = await _wait_queue_head_full(queue1, INFANTRY_BASELINE_FRAMES + 60)
		_check(full_frames >= 0 and full_frames <= INFANTRY_BONUS_LIMIT_FRAMES,
			"1.5 倍出兵速度下 60 工作量应在 %d Tick 内打满（实际 %s；基线 %d）"
				% [INFANTRY_BONUS_LIMIT_FRAMES, str(full_frames), INFANTRY_BASELINE_FRAMES])

	# ---------- 场景 3：主基地加速施工 ----------
	var cc2_transform = _find_legal_transform(runtime, human, CommandCenterScene, anchor)
	if cc2_transform == null:
		# 显式跳过：夹具图可能没有第二座主基地的合法落点（同车厂先例）。
		# 该机制另有纯 C# 回归：ConstructionServiceTests.RatePortScalesAutomaticWork。
		print("SKIP: 夹具图上无第二座主基地落点，施工加速场景由 C# 回归覆盖")
	else:
		var cc_placed = runtime.Place(human, CommandCenterScene, cc2_transform, {})
		_check(cc_placed["accepted"], "第二座主基地应被接受")
		var cc2 = cc_placed.get("structure")
		var cc_frames: int = await _wait_constructed(cc2)
		_check(cc2 != null and is_instance_valid(cc2) and cc2.is_constructed(),
			"第二座主基地应在超时前完工（frames=%d）" % cc_frames)

		var barracks3_transform = _find_legal_transform(runtime, human, BarracksScene, anchor)
		_check(barracks3_transform != null, "应找到第三座兵营的合法落点")
		if barracks3_transform != null:
			# 两座主基地完工 → 施工速率 1.5：100 工作量应 ~67 Tick 完成（基线 100）。
			var rate_frames: int = await _timed_place(runtime, human, BarracksScene, barracks3_transform)
			_check(
				rate_frames > 0 and rate_frames <= CONSTRUCTION_RATE_LIMIT_FRAMES,
				"两座主基地完工后建筑施工应明显加速（实际 %d Tick，阈值 %d；基线 100）"
					% [rate_frames, CONSTRUCTION_RATE_LIMIT_FRAMES]
			)
			# 主基地不参与出兵加速：兵营倍率不变，主基地自身倍率恒 1（当前无产品）。
			if barracks1 != null and is_instance_valid(barracks1):
				# 此时场上已有 3 座完工兵营 → 倍率应为 1 + 0.5×2 = 2.0；
				# 多出来的主基地只加速施工，不改出兵倍率口径。
				var rate_after := float(barracks1.get("production_work_per_tick"))
				_check(absf(rate_after - 2.0) < 0.01,
					"三座兵营的出兵倍率应为 2.0（实际 %s）" % str(rate_after))

	_finish()


func _wait_constructed(structure) -> int:
	var frames := 0
	while structure != null and is_instance_valid(structure) \
			and not structure.is_constructed() and frames < CONSTRUCTION_TIMEOUT_FRAMES:
		await get_tree().physics_frame
		frames += 1
	return frames


## 放置并计时到完工；被拒或超时返回 -1。
func _timed_place(runtime, human, scene, transform) -> int:
	var placed = runtime.Place(human, scene, transform, {})
	if not bool(placed.get("accepted", false)):
		print("FAIL: 计时放置被拒绝：%s" % str(placed.get("primary_issue", "")))
		_failures += 1
		return -1
	return await _wait_constructed(placed.get("structure"))


## 等队首项目工作量打满（生产完成，不含部署）；返回耗时帧数，超时返回 -1。
func _wait_queue_head_full(queue, max_frames: int) -> int:
	for frame in range(max_frames):
		var elements: Array = queue.get_elements()
		if elements.is_empty():
			return frame
		var head = elements[0]
		if int(head.completed_work) >= int(head.required_work):
			return frame
		await get_tree().physics_frame
	return -1


## 等某个类型的己方单位真的出现在 units 组里；返回耗时帧数，超时返回 -1。
func _wait_for_spawned_unit(player: Node, scene_suffix: String, max_frames: int) -> int:
	for frame in range(max_frames):
		for unit in get_tree().get_nodes_in_group("units"):
			if unit.get_parent() == player \
					and str(unit.scene_file_path).ends_with(scene_suffix):
				return frame
		await get_tree().physics_frame
	return -1


## 与 AutomaticConstructionSmokeTest 相同的确定性落点搜索（环带 + 全图栅格兜底）。
func _find_legal_transform(runtime, human, scene, anchor: Vector3):
	var evaluations := 0
	var histogram := {}
	for radius in [10.0, 14.0, 18.0, 22.0, 26.0, 30.0, 34.0, 38.0, 42.0, 46.0]:
		for step in range(24):
			var angle := TAU * float(step) / 24.0
			var candidate := Transform3D(
				Basis.IDENTITY, anchor + Vector3(cos(angle), 0.0, sin(angle)) * radius
			)
			var evaluation = runtime.Evaluate(human, scene, candidate, {})
			evaluations += 1
			if evaluation["accepted"]:
				return candidate
			for issue in evaluation["issues"]:
				histogram[str(issue)] = int(histogram.get(str(issue), 0)) + 1
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
				return scan_candidate
			grid_x += 12.0
		grid_y += 12.0
	print("[AUTOSPOT] 全图无合法落点 scene=%s 评估=%d 次 issues=%s"
		% [str(scene.resource_path.get_file()), evaluations, histogram])
	return null


func _finish():
	if _finished:
		return
	_finished = true
	print("Same-type economy rules smoke test completed: %d failure(s)" % _failures)
	if _match != null and is_instance_valid(_match):
		_match.queue_free()
		await get_tree().process_frame
	SmokeTestExit.request(get_tree(), 0 if _failures == 0 else 1)


func _on_failsafe():
	if _finished:
		return
	_finished = true
	_failures += 1
	print("FAIL: 看门狗超时——同类经济规则测试协程中断未收尾")
	print("Same-type economy rules smoke test completed: %d failure(s)" % _failures)
	SmokeTestExit.request(get_tree(), 1, _match)


func _check(condition: bool, message: String):
	if condition:
		return
	_failures += 1
	print("FAIL: %s" % message)
	push_error("Same-type economy rules smoke test assertion failed: %s" % message)
