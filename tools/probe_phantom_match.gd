extends Node

## 幻影采矿对局级复现探针 v11（2026-10-07）：
## 真实 Match + 生成图（BalanceConfigRuntime 在，A 矿再生 enabled、90s 窗口）
## → 把 gifted 矿车派去采一颗被压到 10 存量的矿 → 采样 45s。
## 判据：矿车 cargo 是否超过矿点存量 10（幻影灌矿）；矿点是否保持 depleted 不删除；
## 账户入账是否 ≤ 10；任务是否以 Completed 收尾而不是对空矿往返。

const MatchSettings = preload("res://source/data-model/MatchSettings.gd")
const MatchScene = preload("res://source/match/Match.tscn")
const WorkerScript = preload("res://source/match/units/Worker.gd")
const RefineryScene = preload("res://source/match/units/OreRefinery.tscn")
const GeneratedMapScene = preload(
	"res://source/match/maps/generated/47-903520021-767a002977/map_47-903520021-767a002977.tscn"
)

const ORE_AMOUNT := 10

var _match: Node = null


func _ready() -> void:
	get_tree().create_timer(200.0).timeout.connect(func(): get_tree().quit(3))
	await _run()
	get_tree().quit(0)


func _run() -> void:
	var settings = MatchSettings.new()
	var human_settings = load("res://source/data-model/PlayerSettings.gd").new()
	human_settings.controller = Constants.PlayerType.HUMAN
	human_settings.color = Color.BLUE
	settings.players.append(human_settings)
	settings.visible_player = 0
	settings.visibility = MatchSettings.Visibility.FULL

	_match = MatchScene.instantiate()
	_match.settings = settings
	_match.map = GeneratedMapScene.instantiate()
	await get_tree().process_frame
	await get_tree().process_frame
	get_tree().root.add_child(_match)

	var deadline := Time.get_ticks_msec() + 30000
	while Time.get_ticks_msec() < deadline and _match.get_local_player() == null:
		await get_tree().process_frame
	var human = _match.get_local_player()
	if human == null:
		print("[PROBE] FAIL no local player")
		return
	await _settle(120)
	var runtime = _match.get_node_or_null("AugmentRuntime")

	# 矿场贴基地放，让 gifted 矿车能被指派（交付链路闭环，便于观察账户）。
	var spot_runtime = _match.get_node("StructurePlacementRuntime")
	var reply: Variant = spot_runtime.FindAutoSpot(human, RefineryScene, "base", Vector3.INF, 0.0)
	var pos: Vector3 = reply.get("pos", Vector3.ZERO) if reply is Dictionary else Vector3.ZERO
	pos.y = 0.6
	var placed: Dictionary = spot_runtime.Place(human, RefineryScene, Transform3D(Basis.IDENTITY, pos), {})
	var refinery = placed.get("structure")
	deadline = Time.get_ticks_msec() + 40000
	while Time.get_ticks_msec() < deadline and refinery != null and not refinery.is_constructed():
		await get_tree().create_timer(0.2).timeout
	print("[PROBE] refinery constructed=", refinery.is_constructed() if refinery != null else false)

	# gifted 矿车。
	var gifted = null
	deadline = Time.get_ticks_msec() + 15000
	while Time.get_ticks_msec() < deadline and gifted == null:
		for unit in get_tree().get_nodes_in_group("units"):
			if unit.get("player") == human and unit.get_script() == WorkerScript:
				gifted = unit
		if gifted == null:
			await get_tree().create_timer(0.2).timeout
	if gifted == null:
		print("[PROBE] FAIL no gifted miner")
		return

	# 选一颗矿场服务半径内的矿，把存量压到 10。
	var ore = null
	if refinery != null:
		var best := INF
		for r in get_tree().get_nodes_in_group("resource_units"):
			if not _ore_available(r):
				continue
			var d: float = (r.global_position * Vector3(1, 0, 1)).distance_to(refinery.global_position * Vector3(1, 0, 1))
			if d < best and d <= refinery.service_radius_m:
				best = d
				ore = r
	if ore == null:
		print("[PROBE] FAIL no ore in service radius")
		return
	var prop := "resource_a" if "resource_a" in ore else "resource_b"
	ore.set(prop, ORE_AMOUNT)
	print("[PROBE] ore=%s prop=%s 存量=%d → 压到 %d（服务半径内）" % [ore.name, prop, int(ore.ore_capacity), ORE_AMOUNT])

	var gateway = human.get_node_or_null("UnitCommandGateway")
	var reply2: Variant = gateway.GatherResources([gifted], ore, human) if gateway != null else {}
	print("[PROBE] 下单=", str(reply2).substr(0, 60))

	var player_before: int = int(human.get(prop))
	var max_cargo := 0
	var phantom_at := -1.0
	var depleted_at := -1.0
	var node_freed := false
	for step in range(225):
		await get_tree().create_timer(0.2).timeout
		if runtime != null and get_tree().paused:
			var state: Dictionary = runtime.call("_state_of", human)
			var first := ""
			for item in state.get("offer", []):
				if item is Dictionary:
					first = str(item.get("id", ""))
					break
			if not first.is_empty():
				runtime.pick(human, first, "probe_auto")
		if not is_instance_valid(gifted):
			break
		var cargo := int(gifted.resource_a) + int(gifted.resource_b)
		max_cargo = maxi(max_cargo, cargo)
		if depleted_at < 0.0 and is_instance_valid(ore) and bool(ore.depleted):
			depleted_at = step * 0.2
		# 只在"当前采集目标就是那颗被压空的矿"时判定幻影——自动采集换矿是合法行为。
		var target: Variant = _current_target(gifted)
		var on_tracked: bool = target != null and is_instance_valid(ore) and target == ore
		if on_tracked and cargo > ORE_AMOUNT and phantom_at < 0.0:
			phantom_at = step * 0.2
			print("[PROBE] ★ 幻影灌矿：对着已耗尽的 %s 采集，cargo=%d 超过存量 %d（t=%.1f）" % [ore.name, cargo, ORE_AMOUNT, phantom_at])
		if on_tracked and is_instance_valid(ore) and int(ore.get(prop)) <= 0 and cargo > 0 and step % 5 == 0:
			print("[PROBE] · 仍在对耗尽矿采集中：cargo=%d（t=%.1f）" % [cargo, step * 0.2])
		if not node_freed and not is_instance_valid(ore):
			node_freed = true
			print("[PROBE] ★ 矿点实体被移除（t=%.1f）" % (step * 0.2))
		var player_now: int = int(human.get(prop))
		if player_now != player_before:
			print("[PROBE] ★ 账户 +%d（t=%.1f）" % [player_now - player_before, step * 0.2])
			player_before = player_now
		if step % 10 == 0:
			var act := ""
			if gifted.action != null and gifted.action.get_script() != null:
				act = str(gifted.action.get_script().resource_path.get_file())
			print("[PROBE] t=%5.1f cargo=%3d ore_left=%s depleted=%s act=%s" % [
				step * 0.2, cargo,
				str(int(ore.get(prop))) if is_instance_valid(ore) else "<freed>",
				str(bool(ore.depleted)) if is_instance_valid(ore) else "<freed>", act])
	print("[PROBE] 结果：max_cargo=%d 幻影出现 t=%s 耗尽 t=%s 实体被移除=%s" % [
		max_cargo, str(phantom_at), str(depleted_at), str(node_freed)])


## 当前采集组合 Action 的资源目标（用于区分"对空矿采"与"换了颗矿采"）。
func _current_target(worker):
	if worker.action == null:
		return null
	if worker.action.has_method("get_resource_unit"):
		return worker.action.get_resource_unit()
	return null


func _ore_available(ore) -> bool:
	if not is_instance_valid(ore) or not ore.is_inside_tree():
		return false
	if "resource_a" in ore:
		return int(ore.resource_a) > 0
	if "resource_b" in ore:
		return int(ore.resource_b) > 0
	return false


func _settle(frames: int) -> void:
	for _i in range(frames):
		await get_tree().process_frame
