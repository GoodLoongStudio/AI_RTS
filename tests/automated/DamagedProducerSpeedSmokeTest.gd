extends Node

## 生产建筑受损：不影响生产速度，且 UI 不得再显示"受损"（回归测试，2026-10-10）
##
## 背景（用户提问 → 口径决定）：
##   ① 「车厂受损会有生产速度影响吗？」→ 答：**不影响**；
##   ② 用户随后明确：「那就不要这种UI显示啊，容易引起误导，我不希望有受损减速这种东西」
##      ⇒ 侧边栏的 `#受损` 徽标（`damaged` 状态）整条移除。
##
## 现状口径（本测试守住）：
##   · 产量 = `Unit.production_work_per_tick = maxf(0.1, growth_rate × same_type_rate)`
##     （`source/match/units/Unit.gd:152-155`），**不含 hp**；C# 每 tick 实时读它
##     （`GodotProductionProducerRegistry.WorkPerTickOf()`）。
##   · `ProductionCatalog.state_of()` **不再返回 `damaged`**，`STATES` 与
##     `ProductionTheme.STATE_TABLE` 里都不再有这个状态。
##
## 断言：
##  1) 满血 与 受损（30%）两种状态下，同一产品 completed_work 的推进速率一致（±5%）；
##  2) 受损车厂在队列空时状态是 `ready`（**不是 damaged**）；目录 STATES 与主题里都没有 damaged。

const MatchScene = preload("res://tests/manual/TestAllUnits.tscn")
const WorkerScene = preload("res://source/match/units/Worker.tscn")
const Catalog = preload("res://source/match/hud/production/ProductionCatalog.gd")
const ProdTheme = preload("res://source/match/hud/production/ProductionTheme.gd")

const MEASURE_SECONDS := 3.0
const RATE_TOLERANCE := 0.05
const DAMAGED_FRACTION := 0.30

var _failures := 0
var _match: Node = null


func _ready():
	_match = MatchScene.instantiate()
	add_child(_match)
	await get_tree().process_frame
	await get_tree().create_timer(0.5).timeout

	var human = _match.get_node_or_null("Players/Human")
	var factory = human.get_node_or_null("VehicleFactory") if human != null else null
	if human == null or factory == null:
		_fail("夹具缺 Players/Human/VehicleFactory")
		_finish()
		return
	var queue = factory.get("production_queue")
	if queue == null:
		queue = factory.find_child("ProductionQueue", true, false)
	_check(queue != null, "车厂应带 ProductionQueue")
	if queue == null:
		_finish()
		return

	# 等到账户可用并补足资金（生产会被 C# 拒绝/扣费，钱不够会污染测量）
	var deadline := Time.get_ticks_msec() + 10000
	while human.get("_economy_runtime") == null and Time.get_ticks_msec() < deadline:
		await get_tree().create_timer(0.1).timeout
	human.add_resources({"resource_a": 5000}, "ScriptedAdjustment")
	await get_tree().create_timer(0.2).timeout

	# ── ① 满血：测速率 ──
	var full_rate := await _measure_production_rate(queue, "满血")
	_check(full_rate > 0.0, "满血状态生产应真的推进（实测 %.3f work/s）" % full_rate)

	# ── ② 受损 30%：不得再出现"受损"状态（用户口径），速率应不变 ──
	factory.set_hp_without_damage(maxi(1, int(float(factory.hp_max) * DAMAGED_FRACTION)))
	await get_tree().create_timer(0.2).timeout
	_check(int(factory.hp) < int(factory.hp_max),
		"车厂应已受损（%s/%s）" % [factory.hp, factory.hp_max])

	var damaged_state = Catalog.state_of("worker", {
		"player": human,
		"producer": factory,
		"queue_items": 0,
	})
	var state := str(damaged_state.get("state", ""))
	var reason := str(damaged_state.get("reason", ""))
	print("  [info] 受损后目录返回: state=%s reason=%s" % [state, reason])
	_check(state != "damaged",
		"受损车厂不得再返回 damaged 状态（实际 %s）" % state)
	_check(state == "ready",
		"受损车厂在队列空时应是 ready（实际 %s）" % state)
	_check(not reason.contains("受损"),
		"受损车厂的 reason 不得再提受损（实际：%s）" % reason)
	_check(not Catalog.STATES.has("damaged"),
		"ProductionCatalog.STATES 不得再包含 damaged（实际 %s）" % str(Catalog.STATES))
	_check(not ProdTheme.STATE_TABLE.has("damaged"),
		"ProductionTheme.STATE_TABLE 不得再有 damaged 样式（那个 #受损 徽标）")

	var damaged_rate := await _measure_production_rate(queue, "受损30%")
	_check(damaged_rate > 0.0, "受损状态生产应仍在推进（实测 %.3f work/s）" % damaged_rate)

	var delta := absf(damaged_rate - full_rate)
	var rel := delta / maxf(full_rate, 0.0001)
	print("  [info] 速率对比: 满血=%.3f work/s  受损30%%=%.3f work/s  相对差=%.2f%%" % [
		full_rate, damaged_rate, rel * 100.0])
	_check(rel <= RATE_TOLERANCE,
		"受损不得改变生产速度（满血 %.3f vs 受损 %.3f work/s，相对差 %.2f%%，容差 %.0f%%）" % [
			full_rate, damaged_rate, rel * 100.0, RATE_TOLERANCE * 100.0])

	_finish()


## 取消现有队列 → 重新排产一个矿车 → 高频采样 completed_work，算出推进速率（work/s）。
## ⚠️ 不能固定采样一次：本夹具里产品完工可能快于窗口（首版就踩到"窗口内元素消失"）。
## 这里逐 50ms 采样，直到元素出队或到达上限；速率取"首次 → 末次"采样（至少要有 2 个不同进度）。
func _measure_production_rate(queue, tag: String) -> float:
	queue.cancel_all()
	await get_tree().create_timer(0.4).timeout
	var produced = queue.produce(WorkerScene)
	print("  [info] %s：排队结果=%s" % [tag, str(produced)])
	await get_tree().create_timer(0.1).timeout

	var t0 := Time.get_ticks_msec()
	var first_work := -1
	var first_t := 0.0
	var last_work := -1
	var last_t := 0.0
	var required := -1
	var vanished_at := -1.0
	while true:
		var elapsed := float(Time.get_ticks_msec() - t0) / 1000.0
		var element = _first_element(queue)
		if element == null:
			vanished_at = elapsed
			break
		required = int(element.required_work)
		var work := int(element.completed_work)
		if first_work < 0:
			first_work = work
			first_t = elapsed
		elif work != last_work:
			last_work = work
			last_t = elapsed
		if elapsed >= 6.0:
			break
		await get_tree().create_timer(0.05).timeout

	if first_work < 0:
		_fail("%s：排队后拿不到队列元素" % tag)
		return 0.0
	var end_work := last_work if last_work >= 0 else first_work
	var end_t := last_t if last_work >= 0 else first_t
	var span := end_t - first_t
	print("  [info] %s：required=%d 采样 %d→%d work（%.2fs→%.2fs，出队时刻 %s）" % [
		tag, required, first_work, end_work, first_t, end_t,
		("%.2fs" % vanished_at) if vanished_at >= 0.0 else "未出队"])
	if span <= 0.001 or end_work == first_work:
		_fail("%s：采样窗口内看不到进度推进（first=%d last=%d span=%.3fs）" % [
			tag, first_work, end_work, span])
		return 0.0
	return float(end_work - first_work) / span


func _first_element(queue):
	var elements: Array = queue.get_elements()
	return elements[0] if not elements.is_empty() else null


func _check(condition: bool, message: String):
	if condition:
		print("  ok: %s" % message)
		return
	_fail(message)


func _fail(message: String):
	_failures += 1
	print("FAIL: %s" % message)
	push_error("Damaged producer speed assertion failed: %s" % message)


func _finish():
	print("Damaged producer speed smoke test completed: %d failure(s)" % _failures)
	SmokeTestExit.request(get_tree(), 0 if _failures == 0 else 1, _match)
