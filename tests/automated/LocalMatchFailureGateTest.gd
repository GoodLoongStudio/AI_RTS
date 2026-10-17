extends Node

## 回归：故意破坏平衡配置时，Match 必须被拒绝，不能生成玩家或进入可玩状态。

const MatchScene := preload("res://source/match/Match.tscn")
const MapScene := preload("res://source/match/maps/PlainAndSimple.tscn")
const MatchSettingsScript := preload("res://source/data-model/MatchSettings.gd")
const PlayerSettingsScript := preload("res://source/data-model/PlayerSettings.gd")


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
	var balance: Node = a_match.get_node("BalanceConfigRuntime")
	balance.BalanceConfigPath = "res://config/balance/does-not-exist.json"
	await get_tree().process_frame
	get_tree().root.add_child(a_match)
	await get_tree().process_frame

	var blocked := bool(a_match.get_meta("match_initialization_failed", false))
	var players := get_tree().get_nodes_in_group("players").size()
	if blocked and players == 0:
		print("[LOCAL-MATCH-FAILURE-GATE] PASS")
	else:
		push_error("[LOCAL-MATCH-FAILURE-GATE] FAIL blocked=%s players=%d" % [blocked, players])
	a_match.queue_free()
	await get_tree().process_frame
	get_tree().quit(0 if blocked and players == 0 else 1)
