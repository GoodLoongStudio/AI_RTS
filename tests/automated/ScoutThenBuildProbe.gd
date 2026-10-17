extends Node

## 一次性验证探针（2026-09-28）：开局只有"基地 + 1 架无人机"时，
## **先用无人机开图**能否把整条链路走通（建造 → 生产矿车 → 指挥移动 → 采集）。
##
## 背景：2026-09-27 单位/建筑整体放大后 footprint 半径涨到 6.25~9.8m，
## 2026-09-28 开局改动又拿掉了 2 个工人（唯一能走路开图的单位）。
## 基地视野 10m(+2m 补偿)，而车厂 footprint 6.65m 要求圆心离基地 ≥ ~11.5m
## 才落在 navmesh 上 —— 两个约束几乎不相交，所以"不开图就造不了大建筑"。
## 本探针要回答的是：**开了图之后到底通不通**（区分"设计如此"与"链路真断了"）。
##
## 全程走正式接口（runtime.Evaluate/Place、queue.produce、gateway.MoveUnits/
## GatherResources），不摸内部字段。

const MatchSettings = preload("res://source/data-model/MatchSettings.gd")
const PlayerSettings = preload("res://source/data-model/PlayerSettings.gd")
const FactoryScene = preload("res://source/match/units/VehicleFactory.tscn")
const WorkerScene = preload("res://source/match/units/Worker.tscn")

var _failures := 0


func _check(cond: bool, msg: String) -> void:
	if cond:
		print("[PASS] " + msg)
	else:
		_failures += 1
		print("[FAIL] " + msg)


func _ready() -> void:
	await get_tree().process_frame
	await get_tree().process_frame

	var settings = MatchSettings.new()
	var human = PlayerSettings.new()
	human.controller = Constants.PlayerType.HUMAN
	human.color = Color.BLUE
	settings.players.append(human)
	var ai = PlayerSettings.new()
	ai.controller = Constants.PlayerType.SIMPLE_CLAIRVOYANT_AI
	ai.color = Color.RED
	settings.players.append(ai)
	settings.visible_player = 0
	settings.visibility = MatchSettings.Visibility.PER_PLAYER

	var a_match: Node = load("res://source/match/Match.tscn").instantiate()
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
	_check(ready, "对局应就绪")
	if not ready:
		_finish()
		return
	for _frame in range(240):
		await get_tree().physics_frame

	var players: Node = a_match.get_node("Players")
	var human_player: Node = players.get_child(0)
	var runtime: Node = a_match.get_node("StructurePlacementRuntime")
	var balance: Node = a_match.get_node("BalanceConfigRuntime")
	var gateway = NetSession.command_gateway_for(human_player)
	human_player.add_resources({"resource_a": 20000}, "ScriptedAdjustment")

	var cc: Node3D = null
	var drone: Node3D = null
	for child in human_player.get_children():
		if not (child is Node3D):
			continue
		var type_id := str(child.get("unit_type_id"))
		if type_id == "command_center" and cc == null:
			cc = child
		elif type_id == "drone" and drone == null:
			drone = child
	_check(cc != null, "人类应有指挥中心")
	if cc == null:
		_finish()
		return
	var cc_pos: Vector3 = cc.global_position
	print("[INFO] 基地=", cc_pos, " 无人机=", drone.global_position if drone != null else "无",
		" 基地视野=", cc.get("sight_range"), " 无人机视野=",
		drone.get("sight_range") if drone != null else "n/a")

	# ---------- ① 未开图：基地旁直接找车厂落点（记录基线） ----------
	var factory_cost: Dictionary = balance.GetConstructionCost(FactoryScene)
	var before := _find_spot(runtime, human_player, FactoryScene, factory_cost, cc_pos,
		[7.0, 9.0, 11.0, 13.0, 15.0, 18.0])
	print("[INFO] 未开图时车厂落点=", before)

	# ---------- ② 用无人机开图（沿外圈逐步跳，每跳等迷雾落账） ----------
	if drone != null:
		for hop in 24:
			var angle := TAU * float(hop) / 24.0
			for ring in [16.0, 26.0, 36.0]:
				drone.global_position = cc_pos + Vector3(
					cos(angle) * ring, 0.0, sin(angle) * ring)
				for _f in range(6):
					await get_tree().physics_frame
	print("[INFO] 开图完成，重新搜索车厂落点")

	# ---------- ③ 开图后：车厂应能落地 ----------
	var radii := [7.0, 9.0, 11.0, 13.0, 15.0, 18.0, 22.0, 26.0, 30.0]
	var spot: Vector3 = _find_spot(runtime, human_player, FactoryScene, factory_cost, cc_pos, radii)
	var found := spot != Vector3.ZERO
	if not found:
		var diag := {}
		for radius in radii:
			for sector in 12:
				var angle := TAU * float(sector) / 12.0
				var candidate := cc_pos + Vector3(cos(angle) * radius, 0.0, sin(angle) * radius)
				var probe: Dictionary = runtime.Evaluate(human_player, FactoryScene,
					Transform3D(Basis.IDENTITY, candidate), factory_cost)
				for issue in (probe.get("issues", []) as Array):
					diag[str(issue)] = int(diag.get(str(issue), 0)) + 1
		print("[INFO] 开图后仍无落点，问题分布=", diag)
	_check(found, "开图后车厂应能找到合法落点")
	if not found:
		_finish()
		return
	print("[INFO] 车厂落点=", spot, " 距基地=%.1fm" % spot.distance_to(cc_pos))
	var placed: Dictionary = runtime.Place(human_player, FactoryScene,
		Transform3D(Basis.IDENTITY, spot), factory_cost)
	var factory: Node3D = placed.get("structure")
	_check(factory != null, "车厂应建造成功（Place 被接受）")
	if factory == null:
		print("[INFO] Place 结果=", placed)
		_finish()
		return

	var built := false
	var build_deadline := Time.get_ticks_msec() + 90000
	while Time.get_ticks_msec() < build_deadline:
		await get_tree().physics_frame
		if not factory.has_method("is_constructed") or factory.call("is_constructed"):
			built = true
			break
	_check(built, "车厂应能自动施工至完工（无矿车也应完工）")

	# ---------- ④ 车厂生产矿车 ----------
	var queue: Node = factory.find_child("ProductionQueue", false, false)
	_check(queue != null, "车厂应有生产队列")
	var miner: Node3D = null
	if queue != null and queue.has_method("produce"):
		var product = queue.produce(WorkerScene)
		_check(product != null, "车厂应能排产矿车（balance: worker 只能由 vehicle_factory 生产）")
		var produce_deadline := Time.get_ticks_msec() + 90000
		while Time.get_ticks_msec() < produce_deadline:
			await get_tree().physics_frame
			for child in human_player.get_children():
				if child is Node3D and str(child.get("unit_type_id")) == "worker":
					miner = child
					break
			if miner != null:
				break
	_check(miner != null, "矿车应被生产出来")
	if miner == null:
		_finish()
		return

	# ---------- ⑤ 指挥移动 ----------
	var move_dest := miner.global_position + Vector3(20.0, 0.0, 0.0)
	var move_receipt: Dictionary = gateway.MoveUnits([miner], move_dest, human_player)
	var move_accepted := str(move_receipt.get("status", "")) == "Accepted"
	_check(move_accepted, "指挥矿车移动应被接受（status=%s）" % str(move_receipt.get("status", "")))
	var moved := false
	var move_deadline := Time.get_ticks_msec() + 45000
	var start_pos: Vector3 = miner.global_position
	while Time.get_ticks_msec() < move_deadline:
		await get_tree().physics_frame
		if miner.global_position.distance_to(start_pos) > 8.0:
			moved = true
			break
	_check(moved, "矿车应真的动起来（位移 > 8m）")

	# ---------- ⑥ 采集 ----------
	var resource: Node3D = null
	var best := 1e9
	for node in get_tree().get_nodes_in_group("resource_units"):
		if not (node is Node3D) or not is_instance_valid(node):
			continue
		var d: float = (node as Node3D).global_position.distance_to(miner.global_position)
		if d < best:
			best = d
			resource = node
	_check(resource != null, "地图上应有可采资源")
	if resource != null and gateway != null:
		var gather_receipt: Dictionary = gateway.GatherResources([miner], resource, human_player)
		var gathered := str(gather_receipt.get("status", "")) == "Accepted"
		var unit_results: Variant = gather_receipt.get("unit_results", [])
		if unit_results is Array:
			for ur in (unit_results as Array):
				if ur is Dictionary and not bool((ur as Dictionary).get("accepted", false)):
					gathered = false
		print("[INFO] gather status=", gather_receipt.get("status", ""),
			" reason=", str(gather_receipt.get("reason", "")).substr(0, 160))
		_check(gathered, "矿车应能被派去采矿")

	_finish()


## 在若干半径 × 20 个扇区上找第一个被权威放置层接受的落点；找不到返回 ZERO。
func _find_spot(runtime: Node, player: Node, scene, cost: Dictionary,
		origin: Vector3, radii: Array) -> Vector3:
	for radius in radii:
		for sector in 20:
			var angle := TAU * float(sector) / 20.0
			var candidate := origin + Vector3(cos(angle) * radius, 0.0, sin(angle) * radius)
			var probe: Dictionary = runtime.Evaluate(player, scene,
				Transform3D(Basis.IDENTITY, candidate), cost)
			if bool(probe.get("accepted", false)):
				return candidate
	return Vector3.ZERO


func _finish() -> void:
	print("Scout-then-build probe: %d failure(s)" % _failures)
	get_tree().quit(0 if _failures == 0 else 1)
