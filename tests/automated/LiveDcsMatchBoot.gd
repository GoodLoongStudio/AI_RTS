extends Node

## 真实对局启动器（供 Python 经 DCS 驱动，2026-09-23）。
##
## 按 .workbuddy/2026-09-14 教程的"循环开局检测修复"方法学：起一局**真对局**
## （窗口化、带 HUD 与迷雾），DCS 监听调试口，由外部驱动 `op=attack` 真打死
## 敌方建筑，再用 `op=screenshot` 看画面、`op=tactical` 看实体——不猜机制，
## 直接在用户看到的那张画面上做检测。
##
## 本脚本只负责起局并保活（挂在 root，不随换场景被 free），其余全部交给 DCS。

const MatchSettings = preload("res://source/data-model/MatchSettings.gd")

const MAP_SCENE := "res://source/match/maps/generated/31-1319582492-767a002977/map_31-1319582492-767a002977.tscn"


func _ready():
	await get_tree().process_frame
	await get_tree().process_frame

	var settings = MatchSettings.new()
	var human = load("res://source/data-model/PlayerSettings.gd").new()
	human.controller = Constants.PlayerType.HUMAN
	human.color = Color.BLUE
	settings.players.append(human)
	var ai = load("res://source/data-model/PlayerSettings.gd").new()
	ai.controller = Constants.PlayerType.SIMPLE_CLAIRVOYANT_AI
	ai.color = Color.RED
	settings.players.append(ai)
	settings.visible_player = 0
	settings.visibility = MatchSettings.Visibility.PER_PLAYER

	var a_match = load("res://source/match/Match.tscn").instantiate()
	a_match.settings = settings
	a_match.map = load(MAP_SCENE).instantiate()
	get_tree().root.add_child(a_match)
	get_tree().current_scene = a_match
	print("[LIVE] match booted, DCS ready")
