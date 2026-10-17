extends Node

## 矿场指不到人复现探针 v9（2026-10-07）：生成图上量化
##   ① 矿点到矿场的距离 vs 运行时服务半径（balance 注入值）；
##   ② has_serviceable_ore() / 在册指派数 / 领取诊断；
##   ③ 赠送矿车满载后是否 NoDropOff 站桩；
##   ④ 把 service_radius_m 调到 46 后交付是否恢复（验证根因的 A/B）。

const MatchSettings = preload("res://source/data-model/MatchSettings.gd")
const MatchScene = preload("res://source/match/Match.tscn")
const WorkerScript = preload("res://source/match/units/Worker.gd")
const RefineryScene = preload("res://source/match/units/OreRefinery.tscn")
const GeneratedMapScene = preload(
	"res://source/match/maps/generated/47-903520021-767a002977/map_47-903520021-767a002977.tscn"
)

var _match: Node = null
var _refinery: Node = null


func _ready() -> void:
	get_tree().create_timer(260.0).timeout.connect(func(): get_tree().quit(3))
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
	var resources := get_tree().get_nodes_in_group("resource_units")
	print("[PROBE] resources=", resources.size())

	var spot_runtime = _match.get_node("StructurePlacementRuntime")
	var reply: Variant = spot_runtime.FindAutoSpot(human, RefineryScene, "base", Vector3.INF, 0.0)
	var pos: Vector3 = reply.get("pos", Vector3.ZERO) if reply is Dictionary else Vector3.ZERO
	pos.y = 0.6
	var placed: Dictionary = spot_runtime.Place(human, RefineryScene, Transform3D(Basis.IDENTITY, pos), {})
	_refinery = placed.get("structure")
	print("[PROBE] refinery accepted=", bool(placed.get("accepted", false)), " at=", str(_refinery.global_position if _refinery != null else Vector3.ZERO))
	deadline = Time.get_ticks_msec() + 40000
	while Time.get_ticks_msec() < deadline and not _refinery.is_constructed():
		await get_tree().create_timer(0.2).timeout
	print("[PROBE] constructed=", _refinery.is_constructed(), " service_radius_m=", _refinery.service_radius_m)

	# ① 矿点到矿场的距离分布（只列有矿的）。
	var r_pos: Vector3 = _refinery.global_position
	var within_30 := 0
	var within_46 := 0
	var nearest := INF
	var nearest_name := ""
	for r in resources:
		if not _ore_available(r):
			continue
		var d: float = (r.global_position * Vector3(1, 0, 1)).distance_to(r_pos * Vector3(1, 0, 1))
		nearest = minf(nearest, d)
		if d < nearest:
			nearest = d
			nearest_name = r.name
		if d <= 30.0:
			within_30 += 1
		if d <= 46.0:
			within_46 += 1
	print("[PROBE] 距离分布：≤30m 的矿=%d，≤46m 的矿=%d，最近=%s(%.1fm)" % [
		within_30, within_46, nearest_name, nearest])

	# 等赠送矿车。
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
	print("[PROBE] gifted=", gifted.name, " at=", str(gifted.global_position))
	gifted.request_legacy_start_auto_gather()

	# ②③ 周期采样：指派状态 + has_serviceable + cargo + action + position。
	for step in range(600):
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
		var full_cargo := int(gifted.resource_a) + int(gifted.resource_b)
		var stuck_no_action := gifted.action == null and full_cargo > 0
		if step % 10 == 0:
			var claimable_note := ""
			var nearest_ore: Node = _refinery.call("_nearest_ore", _refinery.global_position)
			claimable_note = "has_serviceable=%s assigned=%d nearest_ore=%s(%.1fm) meta=%s" % [
				str(_refinery.has_serviceable_ore()),
				_refinery.assigned_workers().size(),
				nearest_ore.name if nearest_ore != null else "<null>",
				(nearest_ore.global_position.distance_to(r_pos)) if nearest_ore != null else -1.0,
				str(gifted.has_meta("ore_refinery_assignment"))]
			print("[PROBE] t=%5.1f cargo=%4d act=%s stuck=%s | %s" % [
				step * 0.2, full_cargo, _action_name(gifted), str(stuck_no_action), claimable_note])
		# ④ 满载站桩判定出现后，把服务半径调到 46（模拟平衡配置修复）继续观测。
		if stuck_no_action and _refinery.service_radius_m < 46.0:
			_refinery.service_radius_m = 46.0
			print("[PROBE] ★ 把 service_radius_m 调为 46（A/B：模拟修复）t=%.1f" % (step * 0.2))
			for wait_i in range(120):
				await get_tree().create_timer(0.2).timeout
				if not is_instance_valid(gifted):
					break
				var cargo_now := int(gifted.resource_a) + int(gifted.resource_b)
				if wait_i % 10 == 0:
					print("[PROBE]   [修复后] t=%+5.1f cargo=%d act=%s meta=%s pos=(%.1f,%.1f)" % [
						wait_i * 0.2, cargo_now, _action_name(gifted),
						str(gifted.has_meta("ore_refinery_assignment")),
						gifted.global_position.x, gifted.global_position.z])
				if cargo_now == 0:
					print("[PROBE] ★ 修复后交付完成，cargo 清零（t=%+5.1f）" % (wait_i * 0.2))
					break
			break
	print("[PROBE] 终态 cargo=%d act=%s" % [
		int(gifted.resource_a) + int(gifted.resource_b) if is_instance_valid(gifted) else -1,
		_action_name(gifted) if is_instance_valid(gifted) else "<freed>"])


func _ore_available(ore) -> bool:
	if not is_instance_valid(ore) or not ore.is_inside_tree():
		return false
	if "resource_a" in ore:
		return int(ore.resource_a) > 0
	if "resource_b" in ore:
		return int(ore.resource_b) > 0
	return false


func _action_name(worker) -> String:
	if worker.action != null and worker.action.get_script() != null:
		return str(worker.action.get_script().resource_path.get_file())
	return ""


func _settle(frames: int) -> void:
	for _i in range(frames):
		await get_tree().process_frame
