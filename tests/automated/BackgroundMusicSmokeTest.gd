extends Node

## 背景音乐冒烟测试（2026-09-07）：
## 对局开始播和平曲 → 交火（单位受击）切战斗曲 → 战斗平息后回到和平曲；
## 主菜单音源资源存在。

const MatchScene = preload("res://tests/manual/TestAllUnits.tscn")
const TankScene = preload("res://source/match/units/Tank.tscn")
const Player = preload("res://source/match/players/Player.gd")

var _failures := 0
var _finished := false


func _ready():
	get_tree().create_timer(60.0).timeout.connect(_on_failsafe)
	var match_instance = MatchScene.instantiate()
	add_child(match_instance)
	await get_tree().process_frame
	await get_tree().create_timer(0.5).timeout

	var director = match_instance.get_node_or_null("MusicDirector")
	_check(director != null, "对局应挂载 MusicDirector")
	if director == null:
		_finish()
		return

	# 等待 match_started 后的和平曲
	var waited := 0.0
	while director._current != "peace" and waited < 8.0:
		await get_tree().create_timer(0.2).timeout
		waited += 0.2
	_check(director._current == "peace", "对局开始应播放和平曲（实际 %s）" % director._current)
	var peace_player: AudioStreamPlayer = director._players["peace"]
	_check(peace_player.playing, "和平曲应在播放中")
	_check(
		peace_player.stream is AudioStreamOggVorbis and peace_player.stream.loop,
		"和平曲应为 OGG 循环播放"
	)

	# 交火：敌方坦克贴脸人类坦克 → 自动互殴 → unit_damaged → 切战斗曲
	var enemy_player = Player.new()
	enemy_player.name = "MusicEnemy"
	enemy_player.color = Color.RED
	enemy_player.add_to_group("players")
	match_instance.get_node("Players").add_child(enemy_player)
	var enemy_tank = TankScene.instantiate()
	MatchSignals.setup_and_spawn_unit.emit(
		enemy_tank, Transform3D(Basis.IDENTITY, Vector3(5, 0, 0)), enemy_player, false
	)
	var my_tank = match_instance.get_node("Players/Human/Tank")
	waited = 0.0
	while director._current != "battle" and waited < 12.0:
		await get_tree().create_timer(0.25).timeout
		waited += 0.25
	_check(director._current == "battle", "交火后应切到战斗曲（实际 %s）" % director._current)

	# 战斗平息（击毁敌方或计时归零）→ 应回到和平曲
	waited = 0.0
	while director._current != "peace" and waited < 40.0:
		await get_tree().create_timer(1.0).timeout
		waited += 1.0
		print(
			"[BGM] hold=%.1f current=%s enemy_hp=%s my_hp=%s enemy_valid=%s" % [
				director._battle_hold, director._current,
				str(enemy_tank.get("hp")), str(my_tank.get("hp")),
				str(is_instance_valid(enemy_tank)),
			]
		)
	_check(director._current == "peace", "战斗平息后应回到和平曲（实际 %s）" % director._current)

	# 主菜单音源资源存在
	_check(
		ResourceLoader.exists("res://assets/music/command_menu.ogg"),
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
