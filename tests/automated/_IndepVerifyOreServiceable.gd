extends Node

## 独立验证探针（本轮新增，只读）：真实对局里矿场为什么 `has_ore=False`。
##
## 背景（实测）：`eco-r1` 真局里副官**已经建成** `ore_refinery`（§9 报告），但权威观测一直报
## `refinery.has_ore=false / delivered_count=0 / first_delivery_ms=-1`，而场上有 16 颗矿点、
## 362000 存量。`OreRefinery._claim_tick()` 的第一行门槛是
## `if not has_serviceable_ore(): _release_all(); return` —— 只要这条为假，矿场永远 0 在册、0 交付。
##
## `has_serviceable_ore()` = `_nearest_ore(global_position) != null`，
## 而 `_ore_is_serviceable` 是**三条与**：① 有矿量 ② `is_ore_reachable`（矿点自己在网格上且贴得住）
## ③ `_player_can_see_ore`（战争迷雾看得见）。本探针逐颗把三条的实测值打出来，
## 直接指出是哪一条把所有矿点判否，不再靠猜。

const MAP_SCENE := "res://source/match/maps/PlainAndSimple.tscn"
const REFINERY := "res://source/match/units/OreRefinery.tscn"


func _ready():
	var settings = load("res://source/data-model/MatchSettings.gd").new()
	var hs = load("res://source/data-model/PlayerSettings.gd").new()
	hs.controller = Constants.PlayerType.HUMAN
	hs.color = Constants.Player.COLORS[0]
	settings.players.append(hs)
	settings.visible_player = 0
	var match_node = load("res://source/match/Match.tscn").instantiate()
	match_node.settings = settings
	match_node.map = load(MAP_SCENE).instantiate()
	add_child(match_node)
	get_tree().current_scene = match_node
	var terrain_map: RID = match_node.navigation.get_navigation_map_rid_by_domain(
		Constants.Match.Navigation.Domain.TERRAIN)
	var deadline := Time.get_ticks_msec() + 25000
	var cc: Node3D = null
	while Time.get_ticks_msec() < deadline:
		await get_tree().physics_frame
		var players: Node = match_node.get_node_or_null("Players")
		if players == null or players.get_child_count() < 1:
			continue
		for sub in players.get_child(0).get_children():
			if sub is Node3D and sub.get_script() != null \
					and "CommandCenter" in str(sub.get_script().resource_path):
				cc = sub
		if cc != null and NavigationServer3D.map_get_closest_point_owner(
				terrain_map, cc.global_position).is_valid():
			break
	if cc == null:
		print("[IVOS] 对局未就绪")
		get_tree().quit(0)
		return
	var human: Node = match_node.get_node("Players").get_children()[0]

	var nodes := []
	for node in get_tree().get_nodes_in_group("resource_units"):
		if is_instance_valid(node):
			nodes.append(node)
	print("[IVOS] 场上矿点=%d" % nodes.size())

	# 三种摆放都测：贴脸（AI 首矿的真实语义）、离基地 26m、离基地 60m。
	# 关键：还要测"矿场摆在**最近矿点旁 9.2m**"——那才是真局 AUTOSPOT 的实际落点，
	# 上面三种"离基地多远"的摆法离矿都 34~103m，看不见矿是**应该**的，不能用来归因。
	for offset in [6.0, 26.0, 60.0]:
		var refinery: Node3D = load(REFINERY).instantiate()
		match_node.call("_setup_and_spawn_unit", refinery,
			Transform3D(Basis.IDENTITY, cc.global_position + Vector3(0.0, 0.0, offset)),
			human, false)
		await get_tree().physics_frame
		var nav_map: RID = refinery.call("_navigation_map")
		var slack := 2.0
		print("=== [IVOS] 矿场摆在基地外 %.0fm，中心=%s ===" % [
			offset, str(refinery.global_position)])
		print("  has_serviceable_ore=%s service_radius=%s" % [
			str(refinery.call("has_serviceable_ore")), str(refinery.get("service_radius"))])
		var ranked := []
		for node in nodes:
			if is_instance_valid(node):
				ranked.append([(refinery.global_position - node.global_position).length(), node])
		ranked.sort()
		var shown := 0
		for pair in ranked:
			var node = pair[1]
			if not is_instance_valid(node) or shown >= 4:
				continue
			shown += 1
			var amount_a = node.get("resource_a")
			var clearance := 0.0
			if node.get_script() != null:
				clearance = float(Utils.Match.Unit.Movement.carve_clearance_of(node))
			var off_mesh := 1e9
			if nav_map.is_valid():
				off_mesh = float(refinery.call("_off_mesh_xz", node.global_position, nav_map))
			print("    %s dist=%.2f ore_a=%s off_mesh=%.2f 阈值=%.2f reachable=%s visible=%s serviceable=%s" % [
				str(node.name),
				(refinery.global_position - node.global_position).length(),
				str(amount_a), off_mesh, clearance + slack,
				str(refinery.call("is_ore_reachable", node)),
				str(refinery.call("_player_can_see_ore", node)),
				str(refinery.call("_ore_is_serviceable", node)),
			])
		refinery.queue_free()
		await get_tree().physics_frame
	# 真局复现：矿场落在"最近矿点旁 9.2m、背向基地"——与 eco-r1 的
	# `[AUTOSPOT] anchor=(98.5,68.9) → FOUND-ADJACENT (107.7,68.9)` 同一几何。
	var nearest = null
	var nearest_dist := INF
	for node in nodes:
		if not is_instance_valid(node):
			continue
		var d: float = (node.global_position - cc.global_position).length()
		if d < nearest_dist:
			nearest_dist = d
			nearest = node
	if nearest == null:
		print("[IVOS] 场上没有矿点，跳过真局复现")
	else:
		var away: Vector3 = nearest.global_position - cc.global_position
		away.y = 0.0
		away = away.normalized() if away.length() > 0.01 else Vector3(0, 0, 1)
		var real_spot: Vector3 = nearest.global_position + away * 9.2
		var refinery2: Node3D = load(REFINERY).instantiate()
		match_node.call("_setup_and_spawn_unit", refinery2,
			Transform3D(Basis.IDENTITY, real_spot), human, false)
		for _i in 120:
			await get_tree().physics_frame
		# 导航图要等**首次同步**才可查询；先空跑一次把同步触发掉。
		if terrain_map.is_valid():
			NavigationServer3D.map_force_update(terrain_map)
			NavigationServer3D.map_get_closest_point(terrain_map, nearest.global_position)
		print("=== [IVOS] 真局几何：矿场距最近矿点 %.2fm（该矿点距基地 %.2fm）===" % [
			(refinery2.global_position - nearest.global_position).length(), nearest_dist])
		print("  refinery.sight_range=%s  worker_capacity=%s" % [
			str(refinery2.get("sight_range")), str(refinery2.get("worker_capacity"))])
		print("  has_serviceable_ore=%s" % str(refinery2.call("has_serviceable_ore")))
		print("  最近矿点: ore_a=%s reachable=%s visible=%s serviceable=%s" % [
			str(nearest.get("resource_a")),
			str(refinery2.call("is_ore_reachable", nearest)),
			str(refinery2.call("_player_can_see_ore", nearest)),
			str(refinery2.call("_ore_is_serviceable", nearest)),
		])
		var nav2: RID = refinery2.call("_navigation_map")
		print("  refinery 自己的 nav_map_valid=%s（无效则 reachable 短路成 true，等于没测）"
			% str(nav2.is_valid()))
		# 用**对局真实的 terrain 导航图**量：矿场落成后，这颗锚点矿还在网格上吗？
		var off_before := 1e9
		if terrain_map.is_valid():
			off_before = float(refinery2.call("_off_mesh_xz", nearest.global_position, terrain_map))
		var threshold: float = float(
			Utils.Match.Unit.Movement.carve_clearance_of(nearest)) + 2.0
		var sticks := off_before <= threshold
		print("  terrain_map_valid=%s 锚点矿 off_mesh=%.2f 阈值(carve+2.0)=%.2f 贴得住=%s" % [
			str(terrain_map.is_valid()), off_before, threshold, str(sticks)])
		if not sticks:
			print("  ⚠ 本探针里矿场自己的 nav_map 无效 ⇒ 它量到的 terrain_map 不代表矿场真实用的域，"
				+ "off_mesh 绝对值不可用于归因；只能证明**可见性不是原因**。"
				+ "真正判否的那条要在烘焙好的真局里量（OreRefinerySmokeTest 的夹具自检已在那儿失败）")
		refinery2.queue_free()
	print("[IVOS] done")
	get_tree().quit(0)
