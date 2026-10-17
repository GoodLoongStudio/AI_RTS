extends Node

## 完整采集链路绕路探针 v4（2026-10-07）：生成图 + 真实 Match + 矿场（FindAutoSpot
## 贴基地放置）→ 完工赠送矿车 → 自动采集 → 全程 5Hz 轨迹 + 每秒打印逻辑路径航点，
## 复刻用户截图场景（矿场已建、矿车在基地边、去采旁边的矿）。

const MatchSettings = preload("res://source/data-model/MatchSettings.gd")
const MatchScene = preload("res://source/match/Match.tscn")
const RefineryScene = preload("res://source/match/units/OreRefinery.tscn")
const WorkerScript = preload("res://source/match/units/Worker.gd")
const GeneratedMapScene = preload(
	"res://source/match/maps/generated/47-903520021-767a002977/map_47-903520021-767a002977.tscn"
)

var _match: Node = null


func _ready() -> void:
	get_tree().create_timer(280.0).timeout.connect(func(): get_tree().quit(3))
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
	var resources := get_tree().get_nodes_in_group("resource_units")
	print("[PROBE] resource count=", resources.size())
	while human.get("_economy_runtime") == null and Time.get_ticks_msec() < deadline:
		await get_tree().create_timer(0.2).timeout
	human.add_resources({"resource_a": 5000}, "ScriptedAdjustment")

	# 找到主基地位置。
	var base_pos := Vector3.ZERO
	for unit in get_tree().get_nodes_in_group("units"):
		if unit.get("player") == human and unit.get("is_constructed") != null and unit.is_constructed():
			base_pos = unit.global_position
			break
	print("[PROBE] base at ", str(base_pos))

	# 矿场贴基地放（AI/副官同款权威选址）。
	var runtime = _match.get_node("StructurePlacementRuntime")
	var reply: Variant = runtime.FindAutoSpot(human, RefineryScene, "base", Vector3.INF, 0.0)
	var placement = null
	if reply is Dictionary and bool(reply.get("found", false)):
		var pos: Vector3 = reply.get("pos", Vector3.ZERO)
		if _match.has_method("_sample_generated_height"):
			pos.y = float(_match._sample_generated_height(pos))
		placement = Transform3D(Basis.IDENTITY, pos)
	if placement == null:
		print("[PROBE] FAIL no refinery spot")
		return
	var placed: Dictionary = runtime.Place(human, RefineryScene, placement, {})
	var structure = placed.get("structure")
	print("[PROBE] refinery placed=", bool(placed.get("accepted", false)), " at ", str(structure.global_position if structure != null else Vector3.ZERO))
	deadline = Time.get_ticks_msec() + 40000
	while Time.get_ticks_msec() < deadline and structure != null and is_instance_valid(structure) and not structure.is_constructed():
		await get_tree().create_timer(0.2).timeout
	print("[PROBE] refinery constructed=", structure.is_constructed() if structure != null else false)

	# 等赠送的矿车出现。
	deadline = Time.get_ticks_msec() + 10000
	var miner = null
	while Time.get_ticks_msec() < deadline and miner == null:
		for unit in get_tree().get_nodes_in_group("units"):
			if unit.get("player") == human and unit.get_script() == WorkerScript:
				miner = unit
		if miner == null:
			await get_tree().create_timer(0.2).timeout
	if miner == null:
		print("[PROBE] FAIL no gifted miner")
		return
	print("[PROBE] miner=", miner.name, " at ", str(miner.global_position))
	miner.request_legacy_start_auto_gather()

	# 全程追踪 90s：0.2s 采样，1s 打印一行（位置/距最近矿/目标/恢复模式/路径航点数）。
	var mv = miner.find_child("Movement", false, false)
	var trace := []
	var frozen_frames := 0
	var last_pos := Vector3.ZERO
	for step in range(450):
		await get_tree().create_timer(0.2).timeout
		if not is_instance_valid(miner):
			break
		var pos: Vector3 = miner.global_position
		if pos.distance_to(last_pos) < 0.05:
			frozen_frames += 1
		else:
			frozen_frames = 0
		last_pos = pos
		# 冻结超过 2s：深度倒出逻辑寻路内部状态。
		if frozen_frames == 10 and mv != null:
			print("[PROBE][FREEZE] t=%.1f pos=%s" % [step * 0.2, str(pos)])
			print("[PROBE][FREEZE] committed=%s raw=%s" % [str(mv.get("_committed_target")), str(mv.get("_raw_target"))])
			var lp: PackedVector3Array = mv.get("_logic_path")
			var lpi := int(mv.get("_logic_path_i"))
			print("[PROBE][FREEZE] logic_path size=%d i=%d remaining=%s" % [lp.size(), lpi, str(lp.slice(mini(lpi, lp.size())))])
			print("[PROBE][FREEZE] stuck=%s repath_attempts=%s repath_cd=%s unstick_cd=%s pending=%s" % [
				str(mv.get("_logic_stuck")), str(mv.get("_logic_repath_attempts")),
				str(mv.get("_logic_repath_cd")), str(mv.get("_logic_unstick_cd")),
				str(mv.get("_logic_path_pending"))])
			print("[PROBE][FREEZE] tree.paused=%s frames=%d" % [str(get_tree().paused), Engine.get_physics_frames()])
			print("[PROBE][FREEZE] mv.is_physics_processing=%s mv.process_mode=%s worker.process_mode=%s skip_nav=%s puppet=%s" % [
				str(mv.is_physics_processing()), str(mv.process_mode), str(miner.process_mode),
				str(mv.call("_skip_navigation_server")), str(NetSession.is_client_puppet())])
			var map_node: Node = _match.get_node_or_null("Map")
			if map_node != null and map_node.has_meta("water_occupancy"):
				var occ: Node = map_node.get_meta("water_occupancy")
				print("[PROBE][FREEZE] blocked(here)=%s blocked(wp0)=%s" % [
					str(occ.call("is_ground_blocked", pos)),
					str(occ.call("is_ground_blocked", lp[lpi] if lpi < lp.size() else pos))])
		var nearest_ore := INF
		var nearest_ore_pos := Vector3.ZERO
		for r in resources:
			if not _ore_available(r):
				continue
			var d: float = pos.distance_to(r.global_position)
			if d < nearest_ore:
				nearest_ore = d
				nearest_ore_pos = r.global_position
		var action_name := _action_name(miner)
		trace.append({"t": step * 0.2, "pos": pos, "d_ore": nearest_ore, "act": action_name})
		if step % 5 == 0 and mv != null:
			var committed: Variant = mv.get("_committed_target")
			var wp_count := -1
			if mv.get("_uses_logic_terrain_move").call():
				wp_count = int(mv.get("_logic_path").size()) - int(mv.get("_logic_path_i"))
			print("[PROBE] t=%5.1f p=(%6.1f,%6.1f) dOre=%5.2f act=%s rec=%s wp=%d tgt=%s" % [
				step * 0.2, pos.x, pos.z, nearest_ore, action_name,
				str(mv.get("_recovery_mode")), wp_count,
				str(committed)])
	# 汇总：相邻采样方向翻转次数（绕圈/振荡指标）。
	var flips := 0
	for i in range(2, trace.size()):
		var d0: Vector3 = (trace[i - 1]["pos"] - trace[i - 2]["pos"]) * Vector3(1, 0, 1)
		var d1: Vector3 = (trace[i]["pos"] - trace[i - 1]["pos"]) * Vector3(1, 0, 1)
		if d0.length() > 0.1 and d1.length() > 0.1 and d0.normalized().dot(d1.normalized()) < -0.3:
			flips += 1
	print("[PROBE] 方向翻转总数=", flips, " 采样数=", trace.size())


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
