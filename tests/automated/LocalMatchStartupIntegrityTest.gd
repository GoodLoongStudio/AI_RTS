extends Node

## 回归：本机开房必须要么进入完整 Match，要么停在加载失败页，绝不能以空配置进入。
## 这个探针直接实例化真实 Match 和默认配置，覆盖曾经导致“建筑价格全为 0”的路径。

const MatchScene := preload("res://source/match/Match.tscn")
const MapScene := preload("res://source/match/maps/PlainAndSimple.tscn")
const MatchSettingsScript := preload("res://source/data-model/MatchSettings.gd")
const PlayerSettingsScript := preload("res://source/data-model/PlayerSettings.gd")
const CommandCenterScene := preload("res://source/match/units/CommandCenter.tscn")
const TankScene := preload("res://source/match/units/Tank.tscn")

var _failures: Array[String] = []


func _ready() -> void:
	NetSession.disconnect_if_networked()
	var settings = MatchSettingsScript.new()
	var human = PlayerSettingsScript.new()
	human.controller = Constants.PlayerType.HUMAN
	human.color = Constants.Player.COLORS[0]
	settings.players.append(human)
	settings.visible_player = 0
	settings.local_player_index = 0

	var a_match: Node = MatchScene.instantiate()
	a_match.settings = settings
	a_match.map = MapScene.instantiate()
	# 测试场景自身正在执行 _ready；等待这一轮的 child setup 完成后再挂 Match。
	await get_tree().process_frame
	get_tree().root.add_child(a_match)
	await get_tree().process_frame

	_check(not bool(a_match.get_meta("match_initialization_failed", false)),
		"默认配置健康时 Match 不应被初始化闸门拦截")
	var balance: Node = a_match.get_node_or_null("BalanceConfigRuntime")
	_check(balance != null, "Match 必须挂载 BalanceConfigRuntime")
	if balance != null:
		_check(balance.IsHealthy(), "BalanceConfigRuntime 必须报告 IsHealthy=true")
		var construction_cost: Dictionary = balance.GetConstructionCost(CommandCenterScene)
		_check(float(construction_cost.get("resource_a", 0.0)) > 0.0,
			"建筑施工成本不能退化为 0")
		var production_cost: Dictionary = balance.GetProductionCost(TankScene)
		_check(float(production_cost.get("resource_a", 0.0)) > 0.0,
			"单位生产成本不能退化为 0")

	for i in range(30):
		await get_tree().process_frame
	_check(not bool(a_match.get_meta("match_initialization_failed", false)),
		"运行 30 帧后不得变成初始化失败状态")
	_check(get_tree().get_nodes_in_group("players").size() == 1,
		"本机测试房应创建 1 名玩家")

	if _failures.is_empty():
		print("[LOCAL-MATCH-INTEGRITY] PASS")
	else:
		for failure in _failures:
			push_error("[LOCAL-MATCH-INTEGRITY] FAIL: %s" % failure)
	a_match.queue_free()
	await get_tree().process_frame
	get_tree().quit(0 if _failures.is_empty() else 1)


func _check(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
