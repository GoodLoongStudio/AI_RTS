extends Node

## 敌方血条染红冒烟测试（2026-09-09）：
## 本地玩家血条保持绿色，敌方单位血条满血色应为红色。

const MatchScene = preload("res://tests/manual/TestAllUnits.tscn")
const TankScene = preload("res://source/match/units/Tank.tscn")
const Player = preload("res://source/match/players/Player.gd")

var _failures := 0


func _ready():
	var match_instance = MatchScene.instantiate()
	add_child(match_instance)
	await get_tree().process_frame
	await get_tree().create_timer(0.5).timeout

	var human = match_instance.get_node("Players/Human")
	var enemy_player = Player.new()
	enemy_player.name = "RedBarEnemy"
	enemy_player.color = Color.RED
	enemy_player.add_to_group("players")
	match_instance.get_node("Players").add_child(enemy_player)

	var enemy_tank = TankScene.instantiate()
	MatchSignals.setup_and_spawn_unit.emit(
		enemy_tank, Transform3D(Basis.IDENTITY, Vector3(5, 0, 0)), enemy_player, false
	)
	await get_tree().process_frame
	await get_tree().create_timer(0.3).timeout

	var ally_bar = _bar_gradient(human.get_node("Tank"))
	var enemy_bar = _bar_gradient(enemy_tank)
	_check(ally_bar != null, "己方坦克应有血条")
	_check(enemy_bar != null, "敌方坦克应有血条")
	if ally_bar != null:
		var ally_color: Color = ally_bar.get_color(0)
		_check(ally_color.g > 0.5, "己方血条应为绿色（实际 %s）" % ally_color)
	if enemy_bar != null:
		var enemy_color: Color = enemy_bar.get_color(0)
		_check(enemy_color.r > 0.5 and enemy_color.g < 0.4, "敌方血条应为红色（实际 %s）" % enemy_color)

	print("Enemy health bar smoke test completed: %d failure(s)" % _failures)
	SmokeTestExit.request(get_tree(), 0 if _failures == 0 else 1)


func _bar_gradient(unit: Node) -> Gradient:
	var bar = unit.find_child("HealthBar", true, false)
	if bar == null:
		return null
	var actual = bar.find_child("ActualBar", true, false)
	if actual == null:
		return null
	return actual.texture.gradient


func _check(condition: bool, message: String):
	if condition:
		return
	_failures += 1
	print("FAIL: %s" % message)
	push_error("Enemy health bar assertion failed: %s" % message)
