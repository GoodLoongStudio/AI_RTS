extends Node

## 表现同步冒烟测试（2026-09-11）。
##
## ## 为什么需要这个测试
##
## 联机客户端是**傀儡**：`Unit._set_action` 主动丢弃 action（Unit.gd:529-532），
## 快照也只带 pos/yaw/hp/stance/fire_policy。于是下列**纯表现**在客户端全部缺失，
## 玩家看到的就是"建筑一出现就是完工样、看不到建造动画、听不到看不到交火、
## 工人采矿没有火花、HUD 没有生产进度"：
##
## - 施工外观/进度：客户端 `NetSync._spawn_unit` 从不调用 `mark_as_under_construction`；
## - 开火动画与音效：`attack_fired` 只在权威端由 ProjectileRuntime 发（真实创建投射物时）；
## - 采集/施工火花：由本地 Action 驱动（CollectingResourcesWhileInRange 等），傀儡不跑 Action；
## - 生产队列：C# 生产服务在客户端被门控，`on_authoritative_item_*` 回调永不发生。
##
## 本测试逐条验证**消费侧入口**真的能产生表现（服务器侧的发送点见 NetSync 快照与
## `broadcast_presentation`）。这样即使以后有人把某个 `present_*` 删掉/改坏，也会立刻红。

const MatchScene = preload("res://tests/manual/TestAllUnits.tscn")
const BarracksScene = preload("res://source/match/units/Barracks.tscn")
const InfantryScene = preload("res://source/match/units/Infantry.tscn")
const WorkerScene = preload("res://source/match/units/Worker.tscn")
const CombatSfx = preload("res://source/match/units/traits/CombatSfx.gd")
const UNDER_CONSTRUCTION_MATERIAL = preload(
	"res://source/match/resources/materials/structure_under_construction.material.tres"
)
const CONSTRUCTING_ACTION = "res://source/match/units/actions/Constructing.gd"

var _failures := 0
var _finished := false
var _constructed_fired := 0
var _fired_signal_count := 0


func _ready():
	get_tree().create_timer(60.0).timeout.connect(_on_failsafe)
	var match_instance = MatchScene.instantiate()
	add_child(match_instance)
	await get_tree().process_frame
	await get_tree().create_timer(0.5).timeout
	var human = match_instance.get_node("Players/Human")

	# ---- 1) 施工：客户端表现入口必须能"从完工样切到施工中，再回到完工" ----
	var site = BarracksScene.instantiate()
	MatchSignals.setup_and_spawn_unit.emit(
		site, Transform3D(Basis.IDENTITY, Vector3(20, 0, 20)), human, false
	)
	await get_tree().process_frame
	site.constructed.connect(func(): _constructed_fired += 1)

	_check(site.is_constructed(), "刚生成的建筑（未标记施工）应视为已完工")
	site.present_construction(0, 100)
	_check(site.is_under_construction(), "present_construction(0/100) 后应进入施工中")
	_check(_geometry_material(site) == UNDER_CONSTRUCTION_MATERIAL,
		"施工中应套用施工半透明材质")
	var hp_before = site.hp
	site.present_construction(50, 100)
	_check(absf(float(site.get("_construction_progress")) - 0.5) < 0.001,
		"进度应镜像权威值 0.5")
	_check(site.hp == hp_before, "表现层不得改写 hp（客户端 hp 由快照结算）")
	site.present_construction(100, 100)
	_check(site.is_constructed(), "present_construction(100/100) 后应完工")
	# 完工后 `Structure._finish_construction()` 会清施工材质并让 SyntyMaterialBinder
	# 重新套图集材质 —— 所以断言是"不再是施工材质"，而不是"材质为 null"。
	_check(_geometry_material(site) != UNDER_CONSTRUCTION_MATERIAL,
		"完工后应清掉施工半透明材质（恢复图集外观）")
	_check(_constructed_fired == 1, "完工应发一次 constructed 信号")

	# ---- 2) 权威侧上报：NetSync 快照据此下发 ----
	_check(site.construction_progress_report() == [100, 100],
		"完工后仍应能上报权威进度（客户端靠它收敛）")

	# ---- 3) 开火：present_fired 必须驱动既有动画/音效订阅者 ----
	var soldier = InfantryScene.instantiate()
	MatchSignals.setup_and_spawn_unit.emit(
		soldier, Transform3D(Basis.IDENTITY, Vector3(6, 0, 2)), human, false
	)
	await get_tree().process_frame
	soldier.attack_fired.connect(func(): _fired_signal_count += 1)
	CombatSfx.clear_played_log()
	soldier.present_fired()
	await get_tree().process_frame
	_check(_fired_signal_count == 1, "present_fired 应补发一次 attack_fired（动画驱动靠它播 Fire）")
	_check("rifle_fire" in CombatSfx.played_log, "present_fired 应触发步兵开火音效")

	# ---- 4) 采集火花 ----
	var worker = WorkerScene.instantiate()
	MatchSignals.setup_and_spawn_unit.emit(
		worker, Transform3D(Basis.IDENTITY, Vector3(8, 0, 8)), human, false
	)
	await get_tree().process_frame
	var sparkling = worker.get_node_or_null("Sparkling")
	_check(sparkling != null, "工人应有 Sparkling 节点")
	if sparkling != null:
		worker.present_gather(true)
		_check(sparkling.is_active(), "present_gather(true) 应开启采集火花")
		worker.present_gather(false)
		_check(not sparkling.is_active(), "present_gather(false) 应关闭采集火花")

	# ---- 5) 生产队列镜像（客户端 HUD 的排队/进度）----
	var producer = _find_producer(match_instance, human)
	_check(producer != null, "测试场景里应存在带生产队列的建筑")
	if producer != null:
		var queue = producer.get("production_queue")
		queue.apply_presentation_snapshot([{
			"item_id": "i-mirror",
			"scene_path": "res://source/match/units/Worker.tscn",
			"state": "Queued",
			"required_work": 600,
			"completed_work": 0,
		}])
		_check(queue.size() == 1, "队列镜像应新增 1 项")
		var element = queue.get_elements()[0] if queue.size() == 1 else null
		if element != null:
			_check(element.required_work == 600, "镜像应带权威工作量")
		queue.apply_presentation_snapshot([{
			"item_id": "i-mirror",
			"scene_path": "res://source/match/units/Worker.tscn",
			"state": "InProgress",
			"required_work": 600,
			"completed_work": 300,
		}])
		_check(queue.size() == 1, "同一 item_id 不应重复新增")
		if element != null:
			_check(element.completed_work == 300, "镜像应随快照推进进度")
		queue.apply_presentation_snapshot([])
		_check(queue.size() == 0, "空快照应收敛掉已消失的项目")

	# ---- 6) 动作镜像：傀儡端 UI 据此判断"在建造" ----
	var idle_unit = WorkerScene.instantiate()
	MatchSignals.setup_and_spawn_unit.emit(
		idle_unit, Transform3D(Basis.IDENTITY, Vector3(12, 0, 12)), human, false
	)
	await get_tree().process_frame
	idle_unit.apply_presentation_action(CONSTRUCTING_ACTION)
	_check(idle_unit.presentation_action_name() == CONSTRUCTING_ACTION,
		"客户端动作镜像应可读（建造预览据此避开建造中的工人）")

	_finish()


func _find_producer(match_instance, human):
	for child in human.get_children():
		if "production_queue" in child and child.production_queue != null:
			return child
	return null


func _geometry_material(unit):
	var geometry = unit.get_node_or_null("Geometry")
	if geometry == null:
		return null
	for child in geometry.find_children("*"):
		if "material_override" in child:
			return child.material_override
	return null


func _on_failsafe():
	if _finished:
		return
	print("FAIL: 看门狗超时——测试协程中断未收尾")
	_finish()


func _finish():
	if _finished:
		return
	_finished = true
	print("Presentation sync smoke test completed: %d failure(s)" % _failures)
	SmokeTestExit.request(get_tree(), 0 if _failures == 0 else 1)


func _check(condition: bool, message: String):
	if condition:
		return
	_failures += 1
	print("FAIL: %s" % message)
	push_error("Presentation sync assertion failed: %s" % message)
