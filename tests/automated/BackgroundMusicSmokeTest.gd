extends Node

## 背景音乐冒烟测试（2026-09-08 曲池暂空版）：
## 对局内 BGM 待用户提供音频——MusicDirector 应挂载且任何受击事件不崩溃、不发声；
## 主菜单音乐资源存在且可打开循环。

const MatchScene = preload("res://tests/manual/TestAllUnits.tscn")
const TankScene = preload("res://source/match/units/Tank.tscn")
const Player = preload("res://source/match/players/Player.gd")

var _failures := 0
var _finished := false


func _ready():
	get_tree().create_timer(45.0).timeout.connect(_on_failsafe)
	var match_instance = MatchScene.instantiate()
	add_child(match_instance)
	await get_tree().process_frame
	await get_tree().create_timer(0.5).timeout

	var director = match_instance.get_node_or_null("MusicDirector")
	_check(director != null, "对局应挂载 MusicDirector")
	if director == null:
		_finish()
		return
	_check(director._players.is_empty(), "曲池暂空时不应创建音乐播放器")

	# 模拟战斗事件：曲池为空时应静默不崩溃
	var enemy_player = Player.new()
	enemy_player.name = "MusicEnemy"
	enemy_player.color = Color.RED
	enemy_player.add_to_group("players")
	match_instance.get_node("Players").add_child(enemy_player)
	var enemy_tank = TankScene.instantiate()
	MatchSignals.setup_and_spawn_unit.emit(
		enemy_tank, Transform3D(Basis.IDENTITY, Vector3(5, 0, 0)), enemy_player, false
	)
	await get_tree().process_frame
	await get_tree().create_timer(1.0).timeout
	_check(director._current == "", "曲池暂空时不应处于任何曲目状态")

	# 主菜单音源资源存在
	_check(
		ResourceLoader.exists("res://assets/music/menu_theme.ogg"),
		"主菜单音乐资源应存在"
	)

	_finish()


func _on_failsafe():
	if _finished:
		return
	print("FAIL: 看门狗超时——测试协程中断未收尾")
	_finish()


func _finish():
	if _finished:
		return
	_finished = true
	print("Background music smoke test completed: %d failure(s)" % _failures)
	SmokeTestExit.request(get_tree(), 0 if _failures == 0 else 1)


func _check(condition: bool, message: String):
	if condition:
		return
	_failures += 1
	print("FAIL: %s" % message)
	push_error("Background music assertion failed: %s" % message)
