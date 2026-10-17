extends Node

## 幻影采矿纯净 A/B 探针 v12（2026-10-07）：真实 Match + 生成图（再生规则在），
## 不建矿场（排除指派/交付竞争）→ 自产矿车 → 只对"存量压到 10 的矿"下一张采集单
## → 采样 40s。判据只看一件事：矿车 cargo 是否超过该矿点存量 10。
## 预期：修复前 cargo 持续上涨（每 120ms +1 直到满载）；修复后停在 10 并收尾。

const MatchSettings = preload("res://source/data-model/MatchSettings.gd")
const MatchScene = preload("res://source/match/Match.tscn")
const WorkerScene = preload("res://source/match/units/Worker.tscn")
const GeneratedMapScene = preload(
	"res://source/match/maps/generated/47-903520021-767a002977/map_47-903520021-767a002977.tscn"
)

const ORE_AMOUNT := 10

var _match: Node = null


func _ready() -> void:
	get_tree().create_timer(150.0).timeout.connect(func(): get_tree().quit(3))
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

	# 找一颗矿，把存量压到 10。
	var ore = null
	for r in get_tree().get_nodes_in_group("resource_units"):
		if _ore_available(r):
			ore = r
			break
	if ore == null:
		print("[PROBE] FAIL no ore")
		return
	var prop := "resource_a" if "resource_a" in ore else "resource_b"
	ore.set(prop, ORE_AMOUNT)
	print("[PROBE] 目标矿=%s prop=%s 存量=%d" % [ore.name, prop, ORE_AMOUNT])

	# 自产矿车，贴着矿点放。
	var worker = WorkerScene.instantiate()
	worker.name = "PhantomMiner"
	_match.call("_setup_and_spawn_unit", worker,
		Transform3D(Basis.IDENTITY, ore.global_position + Vector3(2.0, 0.6, 0.0)), human, false)
	await _settle(20)

	var gateway = human.get_node_or_null("UnitCommandGateway")
	var reply: Variant = gateway.GatherResources([worker], ore, human) if gateway != null else {}
	print("[PROBE] 下单=", str(reply).substr(0, 50))

	var max_cargo := 0
	var phantom_at := -1.0
	var depleted_at := -1.0
	for step in range(200):
		await get_tree().create_timer(0.2).timeout
		if not is_instance_valid(worker):
			break
		var cargo := int(worker.resource_a) + int(worker.resource_b)
		max_cargo = maxi(max_cargo, cargo)
		if depleted_at < 0.0 and is_instance_valid(ore) and bool(ore.depleted):
			depleted_at = step * 0.2
			print("[PROBE] 矿点耗尽（depleted，t=%.1f，剩余=%d）" % [depleted_at, int(ore.get(prop))])
		if cargo > ORE_AMOUNT and phantom_at < 0.0:
			phantom_at = step * 0.2
			print("[PROBE] ★ 幻影灌矿：cargo=%d 超过矿点存量 %d（t=%.1f，矿点 depleted=%s）" % [
				cargo, ORE_AMOUNT, phantom_at, str(bool(ore.depleted)) if is_instance_valid(ore) else "<freed>"])
		if step % 10 == 0:
			var act := ""
			if worker.action != null and worker.action.get_script() != null:
				act = str(worker.action.get_script().resource_path.get_file())
			print("[PROBE] t=%5.1f cargo=%3d ore_left=%s act=%s" % [
				step * 0.2, cargo,
				str(int(ore.get(prop))) if is_instance_valid(ore) else "<freed>", act])
	print("[PROBE] 结果：max_cargo=%d（存量=%d）幻影出现 t=%s 耗尽 t=%s 终态货=%d" % [
		max_cargo, ORE_AMOUNT, str(phantom_at), str(depleted_at),
		(int(worker.resource_a) + int(worker.resource_b)) if is_instance_valid(worker) else -1])


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
