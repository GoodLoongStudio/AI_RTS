extends Node

## 同帧重叠放置复现/守门测试（2026-09-23 用户报"敌方电脑会造重叠建筑"）。
##
## 根因：`GodotStructurePlacementWorldPort.Units()` 按物理帧缓存 "units" 组快照。
## 同一物理帧内先放置的建筑落地入组后缓存不刷新，后一次放置的占用检查看不到它
## ⇒ 两个建筑落在同一位置也被判合法。电脑玩家的经济/生产/防御三个控制器都是
## ~0.5s 定时器，同帧触发时必然复现。
##
## 本测试在同一帧内对同一坐标连续放置两次，第二次必须被 `Occupied` 拒绝。

const MatchSettings = preload("res://source/data-model/MatchSettings.gd")
const BarracksScene = preload("res://source/match/units/Barracks.tscn")

var _failures := 0


func _check(cond: bool, msg: String) -> void:
	if cond:
		print("[PASS] " + msg)
	else:
		_failures += 1
		print("[FAIL] " + msg)


func _ready():
	await get_tree().process_frame
	await get_tree().process_frame

	var settings = MatchSettings.new()
	var ps = load("res://source/data-model/PlayerSettings.gd").new()
	ps.controller = Constants.PlayerType.HUMAN
	ps.color = Color.BLUE
	settings.players.append(ps)
	settings.visible_player = 0
	settings.visibility = MatchSettings.Visibility.FULL

	var a_match = load("res://source/match/Match.tscn").instantiate()
	a_match.settings = settings
	a_match.map = load("res://source/match/maps/PlainAndSimple.tscn").instantiate()
	get_tree().root.add_child(a_match)
	get_tree().current_scene = a_match

	# 等对局就绪（玩家 + CC + 导航）
	var deadline := Time.get_ticks_msec() + 60000
	var ready := false
	while Time.get_ticks_msec() < deadline:
		await get_tree().physics_frame
		var players = a_match.get_node_or_null("Players")
		if players != null and players.get_child_count() >= 1:
			var first_player = players.get_child(0)
			if first_player != null and first_player.get_child_count() > 0:
				ready = true
				break
	_check(ready, "对局应就绪")
	# 等单位完成出生配置（视野/位置注入）——刚 add_child 时 CC 还在原点、sight 未注入
	for _frame in range(180):
		await get_tree().physics_frame

	var human = a_match.get_node("Players").get_child(0)
	var runtime = a_match.get_node("StructurePlacementRuntime")
	var cost = a_match.get_node("BalanceConfigRuntime").GetConstructionCost(BarracksScene)
	_check(human.add_resources({"resource_a": 5000}, "ScriptedAdjustment"), "资源注入应成功")

	# 找一个合法落点：在己方指挥中心周围探一圈，取第一个 Evaluate 通过的点
	var cc: Node3D = null
	for child in human.get_children():
		if child is Node3D and str(child.get("unit_type_id")) == "command_center":
			cc = child
			break
	_check(cc != null, "应能找到己方指挥中心")
	if cc == null:
		print("Same-frame overlap placement: 1 failure(s)")
		get_tree().quit(1)
	var spot := Vector3.ZERO
	var found := false
	for radius in [3.0, 4.0, 5.0, 6.0, 7.0]:
		for sector in range(12):
			var angle := TAU * float(sector) / 12.0
			var candidate := Vector3(
				cc.global_position.x + cos(angle) * radius,
				cc.global_position.y,
				cc.global_position.z + sin(angle) * radius
			)
			var probe: Dictionary = runtime.Evaluate(
				human, BarracksScene, Transform3D(Basis.IDENTITY, candidate), cost
			)
			if bool(probe.get("accepted", false)):
				spot = candidate
				found = true
				break
		if found:
			break
	_check(found, "应能在基地附近找到合法落点")
	if not found:
		print("Same-frame overlap placement: 1 failure(s)")
		get_tree().quit(1)
	var transform := Transform3D(Basis.IDENTITY, spot)

	# 第一次放置（应成功）
	var first: Dictionary = runtime.Place(human, BarracksScene, transform, cost)
	_check(bool(first.get("accepted", false)),
		"同帧第一次放置应成功（issue=%s）" % str(first.get("primary_issue", "")))

	# 第二次放置：**同一帧内**（不 await）对同一坐标再放一次 → 必须 Occupied 拒绝
	var second: Dictionary = runtime.Place(human, BarracksScene, transform, cost)
	var occupied := "Occupied" in (second.get("issues", []) as Array)
	_check(not bool(second.get("accepted", false)),
		"同帧第二次放置必须被拒绝（否则就是重叠建筑；issue=%s）" % str(second.get("primary_issue", "")))
	_check(occupied, "同帧第二次放置的拒绝原因应为 Occupied")

	# 第三次：隔一帧后再放同一坐标 → 同样必须拒绝（跨帧缓存刷新后也要挡住）
	await get_tree().physics_frame
	var third: Dictionary = runtime.Place(human, BarracksScene, transform, cost)
	_check(not bool(third.get("accepted", false)),
		"跨帧重复放置也必须被拒绝（issue=%s）" % str(third.get("primary_issue", "")))

	# 统计实际建筑数：应为 2（CC + 兵营）
	var barracks_count := 0
	for unit in human.get_children():
		if str(unit.get("unit_type_id")) == "barracks":
			barracks_count += 1
	_check(barracks_count == 1, "同帧两次放置后兵营应只有 1 座（实际 %d）" % barracks_count)

	if _failures == 0:
		print("Same-frame overlap placement: 0 failure(s)")
		get_tree().quit(0)
	else:
		print("Same-frame overlap placement: %d failure(s)" % _failures)
		get_tree().quit(1)
