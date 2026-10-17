extends Node

## 临时探针：验证"点击位置不合法时自动吸附到最近合法落点"（2026-09-29）。
## 场景复刻用户实报：矿场蓝图点在基地正左 11m（实测整条线 Occupied），
## 吸附后应该把蓝图挪到 ≤10m 内某合法点并成功落地。

const MatchSettings = preload("res://source/data-model/MatchSettings.gd")
const RefineryScene = preload("res://source/match/units/OreRefinery.tscn")
const MAP_SCENE := "res://source/match/maps/PlainAndSimple.tscn"

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("[PROBE] PASS: ", msg)
	else:
		_failures += 1
		print("[PROBE] FAIL: ", msg)


func _ready():
	var settings = MatchSettings.new()
	var human = load("res://source/data-model/PlayerSettings.gd").new()
	human.controller = Constants.PlayerType.HUMAN
	human.color = Constants.Player.COLORS[0]
	settings.players.append(human)
	settings.visible_player = 0
	var a_match: Node = load("res://source/match/Match.tscn").instantiate()
	a_match.settings = settings
	a_match.map = load(MAP_SCENE).instantiate()
	add_child(a_match)
	get_tree().current_scene = a_match
	var cc_pos := Vector3.ZERO
	var terrain_map = a_match.navigation.get_navigation_map_rid_by_domain(
		Constants.Match.Navigation.Domain.TERRAIN
	)
	for _frame in range(3600):
		await get_tree().physics_frame
		var pn: Node = a_match.get_node_or_null("Players")
		if pn == null or pn.get_child_count() < 1:
			continue
		for sub in pn.get_child(0).get_children():
			if sub is Node3D and sub.get_script() != null \
					and "CommandCenter" in str(sub.get_script().resource_path):
				cc_pos = sub.global_position
		if cc_pos != Vector3.ZERO and \
				NavigationServer3D.map_get_closest_point_owner(terrain_map, cc_pos).is_valid():
			break
	print("[PROBE] 对局就绪 CC=", cc_pos)
	await get_tree().physics_frame
	var human_node: Node = a_match.get_node("Players").get_children()[0]
	human_node.add_resources({"resource_a": 50000}, "Probe")
	await get_tree().physics_frame
	var runtime: Node = a_match.get_node("StructurePlacementRuntime")
	var balance: Node = a_match.get_node("BalanceConfigRuntime")
	var cost: Dictionary = balance.GetConstructionCost(RefineryScene)

	# 用户点的位置：基地正左 11m
	var click_point := Vector3(cc_pos.x - 11.0, 0, cc_pos.z)
	var direct = runtime.Evaluate(human_node, RefineryScene, Transform3D(Basis.IDENTITY, click_point), cost)
	print("[PROBE] 直接放在点击点：", direct.get("primary_issue"))
	_check(not bool(direct.get("accepted", false)), "点击点本身不合法（复现用户问题）")

	# 复刻 handler 的吸附搜索（同一算法）
	var found := Vector3.INF
	var radius := 1.0
	while radius <= 10.0 and found == Vector3.INF:
		for sector in range(12):
			var angle := TAU * float(sector) / 12.0
			var cand := click_point + Vector3(cos(angle) * radius, 0.0, sin(angle) * radius)
			var probe = runtime.Evaluate(human_node, RefineryScene, Transform3D(Basis.IDENTITY, cand), cost)
			if probe is Dictionary and bool(probe.get("accepted", false)):
				found = cand
				break
		radius += 1.0
	# 兜底：以己方建筑网络为锚的全场搜索（复刻 handler 第二级吸附）
	var reply = runtime.FindAutoSpot(human_node, RefineryScene, "base", click_point, 28.0)
	print("[PROBE] FindAutoSpot(base, 28m) → found=", reply.get("found") if reply is Dictionary else "null",
		" pos=", reply.get("pos") if reply is Dictionary else "")
	if reply is Dictionary and bool(reply.get("found", false)):
		var fp = reply["pos"]
		var placed_fb = runtime.Place(human_node, RefineryScene, Transform3D(Basis.IDENTITY, fp), cost)
		print("[PROBE] 兜底 Place → accepted=", placed_fb.get("accepted"), " status=", placed_fb.get("status"))
		_check(bool(placed_fb.get("accepted", false)), "兜底吸附后 Place 成功")
		# 撤销这座，避免干扰后面
		var st = placed_fb.get("structure")
		if st != null and is_instance_valid(st):
			st.queue_free()
	else:
		_check(false, "FindAutoSpot 也没找到合法落点")
	_check(found != Vector3.INF, "吸附搜索在 10m 内找到合法落点")
	if found != Vector3.INF:
		var d_click := found.distance_to(click_point)
		var d_cc := Vector2(found.x - cc_pos.x, found.z - cc_pos.z).length()
		print("[PROBE] 吸附落点=", found, " 距点击点 ", round(d_click * 10) / 10.0, "m，距基地 ", round(d_cc), "m")
		_check(d_click <= 10.0, "吸附点距点击点 ≤10m")
		var placed = runtime.Place(human_node, RefineryScene, Transform3D(Basis.IDENTITY, found), cost)
		_check(bool(placed.get("accepted", false)), "吸附后 Place 成功（%s）" % placed.get("status"))
		var struct = placed.get("structure")
		_check(struct != null and is_instance_valid(struct), "矿场真的生成")
	print("[PROBE] failures=", _failures)
	get_tree().quit(0 if _failures == 0 else 1)
