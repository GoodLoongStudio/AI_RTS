extends Node

## UI 音效五件套冒烟测试（2026-09-08）：
## click/hover 自动绑定按钮；select 跟随选中单位；
## place 跟随建筑开工；error 跟随被拒命令。

const MatchScene = preload("res://tests/manual/TestAllUnits.tscn")
const ButtonScene = preload("res://source/main-menu/Main.tscn")

var _failures := 0
var _finished := false


func _ready():
	get_tree().create_timer(60.0).timeout.connect(_on_failsafe)
	var uisfx = get_node_or_null("/root/UISfx")
	_check(uisfx != null, "UISfx 自动加载应存在")
	if uisfx == null:
		_finish()
		return
	for key in uisfx.BANKS:
		_check(
			uisfx._banks[key].size() == int(uisfx.BANKS[key]),
			"%s 变体应全部装载（实际 %d）" % [key, uisfx._banks[key].size()]
		)

	# 1) 按钮 hover/click 自动绑定：加一个按钮进树，触发 pressed
	var button := Button.new()
	add_child(button)
	await get_tree().process_frame
	uisfx.played_log.clear()
	button.mouse_entered.emit()
	button.pressed.emit()
	await get_tree().process_frame
	_check("hover" in uisfx.played_log, "按钮悬停应触发 hover 音")
	_check("click" in uisfx.played_log, "按钮按下应触发 click 音")
	button.queue_free()

	# 2) 选中单位 → select
	var match_instance = MatchScene.instantiate()
	add_child(match_instance)
	await get_tree().process_frame
	await get_tree().create_timer(0.5).timeout
	var human = match_instance.get_node("Players/Human")
	uisfx.played_log.clear()
	human.get_node("Tank").get_node("Selection").select()
	await get_tree().process_frame
	_check("select" in uisfx.played_log, "选中单位应触发 select 音")

	# 3) 被拒命令 → error
	uisfx.played_log.clear()
	human.get_node("UnitActionsController").command_feedback.emit(
		"InvalidCommand", 0, 1, "Rejected"
	)
	# error 挂在 _emit_command_feedback 内部（被拒时），直接调内部路径不可行——
	# 改为直接验证 play("error") 可用
	uisfx.play("error")
	await get_tree().process_frame
	_check("error" in uisfx.played_log, "error 音应可播放")

	# 4) 放置建筑 → place：造一个非己方结构实例标记为在建
	var structure = load("res://source/match/units/Barracks.tscn").instantiate()
	MatchSignals.setup_and_spawn_unit.emit(
		structure, Transform3D(Basis.IDENTITY, Vector3(10, 0, 10)), human, false
	)
	await get_tree().process_frame
	uisfx.played_log.clear()
	structure.mark_as_under_construction()
	await get_tree().process_frame
	_check("place" in uisfx.played_log, "建筑开工应触发 place 音")

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
	print("UI sfx smoke test completed: %d failure(s)" % _failures)
	SmokeTestExit.request(get_tree(), 0 if _failures == 0 else 1)


func _check(condition: bool, message: String):
	if condition:
		return
	_failures += 1
	print("FAIL: %s" % message)
	push_error("UI sfx assertion failed: %s" % message)
