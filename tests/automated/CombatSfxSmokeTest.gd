extends Node

## 战斗音效冒烟测试（2026-09-07）：
## 步兵打坦克应有枪声+金属命中音；坦克开火应有炮声；坦克打步兵应有爆炸命中音。

const MatchScene = preload("res://tests/manual/TestAllUnits.tscn")
const InfantryScene = preload("res://source/match/units/Infantry.tscn")
const TankScene = preload("res://source/match/units/Tank.tscn")
const Player = preload("res://source/match/players/Player.gd")
const CombatSfx = preload("res://source/match/units/traits/CombatSfx.gd")

const WAIT_SECONDS := 25.0

var _failures := 0
var _finished := false


func _ready():
	get_tree().create_timer(60.0).timeout.connect(_on_failsafe)
	var match_instance = MatchScene.instantiate()
	add_child(match_instance)
	await get_tree().process_frame
	await get_tree().create_timer(0.5).timeout

	var human = match_instance.get_node("Players/Human")
	var enemy_player = Player.new()
	enemy_player.name = "SfxEnemy"
	enemy_player.color = Color.RED
	enemy_player.add_to_group("players")
	match_instance.get_node("Players").add_child(enemy_player)

	# 坦克对轰：敌方坦克放在人类坦克旁（金属打金属）
	var enemy_tank = TankScene.instantiate()
	MatchSignals.setup_and_spawn_unit.emit(
		enemy_tank, Transform3D(Basis.IDENTITY, Vector3(5, 0, 0)), enemy_player, false
	)
	# 步兵贴脸敌方坦克（软体打金属：枪声+金属命中）
	var soldier = InfantryScene.instantiate()
	MatchSignals.setup_and_spawn_unit.emit(
		soldier, Transform3D(Basis.IDENTITY, Vector3(6, 0, 2)), human, false
	)
	await get_tree().process_frame
	CombatSfx.clear_played_log()

	var waited := 0.0
	while waited < WAIT_SECONDS:
		var heard := CombatSfx.played_log
		var has_rifle := "rifle_fire" in heard
		var has_cannon := "cannon_fire" in heard
		var has_metal := "impact_metal" in heard
		if has_rifle and has_cannon and has_metal:
			break
		await get_tree().create_timer(0.25).timeout
		waited += 0.25

	var heard_log := CombatSfx.played_log
	_check("rifle_fire" in heard_log, "士兵开火应有枪声（rifle_fire）")
	_check("cannon_fire" in heard_log, "坦克开火应有炮声（cannon_fire）")
	_check("impact_metal" in heard_log, "子弹/炮弹命中坦克应有金属命中音（impact_metal）")
	_check(
		"impact_explosion" in heard_log or "impact_flesh" in heard_log,
		"坦克打步兵应有爆炸/软体命中音"
	)
	print("SFX heard: ", ",".join(heard_log))

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
	print("Combat sfx smoke test completed: %d failure(s)" % _failures)
	SmokeTestExit.request(get_tree(), 0 if _failures == 0 else 1)


func _check(condition: bool, message: String):
	if condition:
		return
	_failures += 1
	print("FAIL: %s" % message)
	push_error("Combat sfx assertion failed: %s" % message)
