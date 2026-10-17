extends Node

## 生产/施工工期实测探针（2026-10-12，统一 2 倍速验收用）。
##
## 为什么单独写：现有冒烟只在**失败**时打印帧数，判据是"超时上限"而不是实测值，
## 拿不到"改动前 N Tick ⇒ 改动后 M Tick"的可比数字。本探针只做一件事：
## 在真实 Match 里量四段权威工期并打印 `[PACE] ...`，前后各跑一次即可对账。
##
## 口径：duration(tick) = requiredWork / workPerTick，物理 60Hz（权威见
## config/balance/demo.balance.v1.json 与 ConstructionService/ProductionService.Advance）。
## 施工取"放置到 is_constructed()"的物理帧；生产取"入队到队首 completed_work 打满"的物理帧。

const MatchScene = preload("res://tests/manual/TestAllUnits.tscn")
const BarracksScene = preload("res://source/match/units/Barracks.tscn")
const InfantryScene = preload("res://source/match/units/Infantry.tscn")
const WorkerScene = preload("res://source/match/units/Worker.tscn")
const MgTurretScene = preload("res://source/match/units/MachineGunTurret.tscn")
const Warmup = preload("res://tests/automated/SmokeTestWarmup.gd")

const CONSTRUCTION_LIMIT := 1200
const PRODUCTION_LIMIT := 1500

var _match: Node = null
var _timed_structure = null


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
	if not ready:
		print("[PACE] abort=account_not_ready")
		get_tree().quit(1)
		return

	# ---------- 生产者白名单（不是工期项）----------
	# Worker 的合法生产者是 vehicle_factory（balance productions[worker].allowedProducerUnitTypeIds），
	# 主基地入队必须被拒；这里当作"允许生产者判据没被改坏"的旁证，不参与工期对账。
	await _time_production(human.get_node("CommandCenter").production_queue,
		WorkerScene, "produce_worker_at_cc")

	# ---------- 施工：兵营 ----------
	var frames := await _place_and_time(runtime, human, BarracksScene, anchor)
	print("[PACE] construct_barracks frames=%d" % frames)

	# ---------- 生产：兵营产步兵 ----------
	if _timed_structure != null and is_instance_valid(_timed_structure):
		await _time_production(_timed_structure.production_queue, InfantryScene,
			"produce_infantry")

	# ---------- 施工：机枪塔（requiredWork 与兵营不同，用来验证加速是统一的）----------
	var turret_frames := await _place_and_time(runtime, human, MgTurretScene, anchor)
	print("[PACE] construct_mg_turret frames=%d" % turret_frames)

	print("[PACE] done")
	get_tree().quit(0)


## 入队并计时到队首工作量打满；同时打印权威 required_work，便于对账 balance。
func _time_production(queue, product_scene, label: String):
	if queue == null:
		print("[PACE] %s skipped=no_queue" % label)
		return
	queue.cancel_all()
	await get_tree().create_timer(0.2).timeout
	if queue.produce(product_scene) == null:
		print("[PACE] %s rejected status=%s" % [
			label, str(queue.get("_last_result").get("status", ""))])
		return
	var required := 0
	var elements: Array = queue.get_elements()
	if not elements.is_empty():
		required = int(elements[0].required_work)
	var frames := await _wait_queue_head_full(queue, PRODUCTION_LIMIT)
	print("[PACE] %s frames=%d required=%d" % [label, frames, required])


## 放置并计时到完工，被拒返回 -1；结构体留在 _timed_structure。
func _place_and_time(runtime, human, scene, anchor) -> int:
	_timed_structure = null
	var transform = _find_legal_transform(runtime, human, scene, anchor)
	if transform == null:
		return -1
	var placed = runtime.Place(human, scene, transform, {})
	if not bool(placed.get("accepted", false)):
		print("[PACE] place_rejected scene=%s issue=%s"
			% [str(scene.resource_path.get_file()), str(placed.get("primary_issue", ""))])
		return -1
	_timed_structure = placed.get("structure")
	var frames := 0
	while _timed_structure != null and is_instance_valid(_timed_structure) \
			and not _timed_structure.is_constructed() and frames < CONSTRUCTION_LIMIT:
		await get_tree().physics_frame
		frames += 1
	return frames


func _wait_queue_head_full(queue, max_frames: int) -> int:
	for frame in range(max_frames):
		var elements: Array = queue.get_elements()
		if elements.is_empty():
			return frame
		if int(elements[0].completed_work) >= int(elements[0].required_work):
			return frame
		await get_tree().physics_frame
	return -1


## 与既有冒烟一致的确定性环带落点搜索（绝不臆造坐标）。
func _find_legal_transform(runtime, human, scene, anchor: Vector3):
	for radius in [10.0, 14.0, 18.0, 22.0, 26.0, 30.0, 34.0, 38.0, 42.0, 46.0]:
		for step in range(24):
			var angle := TAU * float(step) / 24.0
			var candidate := Transform3D(
				Basis.IDENTITY, anchor + Vector3(cos(angle), 0.0, sin(angle)) * radius
			)
			if runtime.Evaluate(human, scene, candidate, {})["accepted"]:
				return candidate
	return null


func _on_failsafe():
	print("[PACE] abort=failsafe_timeout")
	get_tree().quit(1)
