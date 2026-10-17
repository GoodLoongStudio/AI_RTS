extends Node

## 矿场完工赠送矿车冒烟测试（2026-09-28 红警2 口径）：
##   1. 开局零矿车：真实 Match.tscn 出生链路（主基地+无人机）不再送工人/矿车；
##   2. 零单位可放矿场：蓝图放置不再要求任何建造者（automatic 进度源）；
##   3. 矿场自动施工完工 → 权威端**恰好赠送一辆**矿车（Worker）给本方。
## 用真实 Match.tscn 而非 TestAllUnits 夹具：夹具自带 Worker 节点，
## 断言不了"开局没有矿车"这条。

const MatchSettings = preload("res://source/data-model/MatchSettings.gd")
const MatchScene = preload("res://source/match/Match.tscn")
const RefineryScene = preload("res://source/match/units/OreRefinery.tscn")
const WorkerScene = preload("res://source/match/units/Worker.tscn")

## requiredWork=100（2026-10-12 统一 2 倍速，200 ÷ 2）/ automaticWorkPerTick=1 ⇒ 约 1.7s 完工；给足余量。
const CONSTRUCTION_TIMEOUT_SECONDS := 40.0
const MINER_TIMEOUT_SECONDS := 10.0

var _failures := 0
var _finished := false
var _match: Node = null


func _ready():
	get_tree().create_timer(180.0).timeout.connect(_on_failsafe)
	# 主场景自身的 _ready 期间 root 正在装子节点，直接 add_child 会被拒
	# （实测 "Parent node is busy setting up children"），先让出两帧。
	await get_tree().process_frame
	await get_tree().process_frame
	var settings = MatchSettings.new()
	var human_settings = load("res://source/data-model/PlayerSettings.gd").new()
	human_settings.controller = Constants.PlayerType.HUMAN
	human_settings.color = Color.BLUE
	settings.players.append(human_settings)
	var ai = load("res://source/data-model/PlayerSettings.gd").new()
	ai.controller = Constants.PlayerType.SIMPLE_CLAIRVOYANT_AI
	ai.color = Color.RED
	settings.players.append(ai)
	settings.visible_player = 0
	# FULL：本测的是"放置→自动施工→赠车"，不是迷雾；PER_PLAYER 下零单位视野
	# 会让 FindAutoSpot 全程 NotVisible（实测 160 评估全拒），与被测行为无关。
	settings.visibility = MatchSettings.Visibility.FULL

	_match = MatchScene.instantiate()
	_match.settings = settings
	_match.map = load("res://source/match/maps/PlainAndSimple.tscn").instantiate()
	get_tree().root.add_child(_match)

	# 等对局就绪（本地玩家 + 权威经济账户）。
	var deadline := Time.get_ticks_msec() + 30000
	while Time.get_ticks_msec() < deadline and _match.get_local_player() == null:
		await get_tree().process_frame
	# get_local_player() 返回无类型 Variant，不能用 `:=`（实测解析报错）。
	var human = _match.get_local_player()
	_check(human != null, "对局应就绪并拿到本地玩家")
	if human == null:
		_finish()
		return
	while human.get("_economy_runtime") == null and Time.get_ticks_msec() < deadline:
		await get_tree().create_timer(0.2).timeout
	var resources_ready: bool = human.add_resources({"resource_a": 5000}, "ScriptedAdjustment")
	_check(resources_ready, "权威经济账户应在就绪后接受测试注资")

	# ---- ① 开局零矿车 ----
	var initial_miners := _count_miners(human)
	_check(initial_miners == 0, "开局不应有任何矿车/工人（实际 %d）" % initial_miners)

	# ---- ② 零单位放矿场（放置不再要求建造者）----
	# 选址走 AI/副官同款的权威 FindAutoSpot（base 模式贴主基地搜合法点）：
	# 手写 Evaluate 环带会撞上视野判定（零矿车时视野只有基地+无人机），
	# 而 FindAutoSpot 就是"基地周围找第一个合法落点"的权威实现。
	var runtime = _match.get_node("StructurePlacementRuntime")
	var reply: Variant = runtime.FindAutoSpot(human, RefineryScene, "base", Vector3.INF, 0.0)
	var placement = null
	if reply is Dictionary and bool(reply.get("found", false)):
		var pos: Vector3 = reply.get("pos", Vector3.ZERO)
		if _match.has_method("_sample_generated_height"):
			pos.y = float(_match._sample_generated_height(pos))
		placement = Transform3D(Basis.IDENTITY, pos)
	_check(placement != null, "FindAutoSpot 应在主基地周围找到合法矿场落点（零矿车）")
	if placement == null:
		_finish()
		return
	var placed: Dictionary = runtime.Place(human, RefineryScene, placement, {})
	_check(placed.get("accepted", false), "放置矿场应被接受（不需要任何单位）")
	var structure = placed.get("structure")
	_check(structure != null and is_instance_valid(structure), "放置应返回施工现场")
	if not placed.get("accepted", false) or structure == null:
		_finish()
		return

	# ---- ③ 自动施工完工 → 恰好赠送一辆矿车 ----
	deadline = Time.get_ticks_msec() + int(CONSTRUCTION_TIMEOUT_SECONDS * 1000.0)
	while Time.get_ticks_msec() < deadline and not structure.is_constructed():
		await get_tree().create_timer(0.2).timeout
	_check(structure.is_constructed(), "矿场应在 %.0fs 内自动施工完工" % CONSTRUCTION_TIMEOUT_SECONDS)

	deadline = Time.get_ticks_msec() + int(MINER_TIMEOUT_SECONDS * 1000.0)
	var miners := _count_miners(human)
	while Time.get_ticks_msec() < deadline and miners < 1:
		await get_tree().create_timer(0.2).timeout
		miners = _count_miners(human)
	_check(miners == 1, "矿场完工应恰好赠送 1 辆矿车（实际 %d）" % miners)
	_check(bool(structure.get("_free_miner_granted")), "矿场赠车标记应已置位")
	for miner in _miners(human):
		_check(
			str(miner.scene_file_path) == WorkerScene.resource_path,
			"赠送的单位应是矿车（Worker 场景）"
		)
		_check(miner.get_parent() == human, "赠送的矿车应归属放置矿场的玩家")

	_finish()


func _miners(player) -> Array:
	var out: Array = []
	if player == null:
		return out
	for child in player.get_children():
		if is_instance_valid(child) and str(child.scene_file_path) == WorkerScene.resource_path:
			out.append(child)
	return out


func _count_miners(player) -> int:
	return _miners(player).size()


func _check(condition: bool, message: String):
	if condition:
		return
	_failures += 1
	print("FAIL: %s" % message)
	push_error("Refinery free miner assertion failed: %s" % message)


func _finish():
	if _finished:
		return
	_finished = true
	print("Refinery free miner smoke test completed: %d failure(s)" % _failures)
	if _match != null and is_instance_valid(_match):
		_match.queue_free()
		await get_tree().process_frame
	SmokeTestExit.request(get_tree(), 0 if _failures == 0 else 1)


func _on_failsafe():
	if _finished:
		return
	print("FAIL: 看门狗超时——测试协程中断未收尾")
	_finish()
