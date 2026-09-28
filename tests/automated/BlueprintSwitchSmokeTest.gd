extends Node
## 蓝图切换回归 —— 复现 2026-09-28 用户报障：
## 「我想建造建筑，刚开始点的机场，现在点的防空炮，但是没有切换」
##
## 期望行为（红警式）：放置模式已激活时，再点另一个建筑图标 = **把待放置蓝图换成新建筑**；
## 旧幽灵节点释放，不得同时残留两个蓝图，也不得静默丢弃请求。
##
## 两层覆盖：
##   层 1 —— handler 语义：直接 `MatchSignals.place_structure.emit()` 两次，断言待放置原型切换。
##   层 2 —— 真实 UI：手动挂载 `Ra3Sidebar`（headless 下 `Match.gd` 刻意不挂侧栏），
##           找「机场」「对空炮」两个格子 `pressed.emit()`，走真实 `_on_cell_pressed` 路径。

const MatchScene = preload("res://tests/manual/TestOneUnit.tscn")
const WorkerScene = preload("res://source/match/units/Worker.tscn")
const SidebarScript = preload("res://source/match/hud/ra3/Ra3Sidebar.gd")

const AIRPORT := "res://source/match/units/AircraftFactory.tscn"
const ANTI_AIR := "res://source/match/units/AntiAirTurret.tscn"
const SIDEBAR_GROUP := "ra3_sidebar"

var _failures := 0


func _ready():
	var match_instance = MatchScene.instantiate()
	add_child(match_instance)
	for _frame in range(6):
		await get_tree().process_frame

	var human = match_instance.get_node_or_null("Players/Human")
	var handler = human.get_node_or_null("StructurePlacementHandler") if human != null else null
	_check(handler != null, "Human 下应挂载 StructurePlacementHandler")
	if handler == null:
		_finish(match_instance)
		return

	# headless / 专用服下 `Match._ready` 里有 await，local player 判定会晚几帧；
	# 不等到就断言会得到"信号没订阅"的假红，而不是真的缺陷。
	for _frame in range(180):
		if match_instance.get_local_player() != null:
			break
		await get_tree().process_frame
	print(
		"[probe] local_player=",
		str(match_instance.get_local_player()),
		" handler_player=",
		str(handler._player),
		" input_bound=",
		handler._local_input_bound
	)
	if not handler._local_input_bound:
		handler._bind_local_input()
	if not handler._local_input_bound and match_instance.get_local_player() == handler._player:
		# 绑定漏了就直接连，保证后面的断言测的是"切换"而不是"没接上"。
		MatchSignals.place_structure.connect(handler._on_structure_placement_request)
	# 空转护栏：信号没接上时下面所有断言都会假绿，必须先证明链路活着。
	_check(
		_signal_wired(handler),
		"StructurePlacementHandler 未订阅 place_structure —— 本探针会空转，先修装配"
	)

	await _check_handler_layer(handler)
	await _check_sidebar_layer(match_instance, human, handler)

	_finish(match_instance)


## 层 1：handler 语义。两次 emit，第二次必须替换待放置原型。
func _check_handler_layer(handler) -> void:
	var airport := load(AIRPORT) as PackedScene
	var anti_air := load(ANTI_AIR) as PackedScene

	MatchSignals.place_structure.emit(airport)
	await get_tree().process_frame
	_check(
		handler._active_blueprint_node != null,
		"点机场后应进入放置模式（活动幽灵节点存在）"
	)
	_check(
		_pending_path(handler) == AIRPORT,
		"点机场后待放置蓝图应为机场，实测 %s" % _pending_path(handler)
	)
	var first_ghost = handler._active_blueprint_node

	MatchSignals.place_structure.emit(anti_air)
	await get_tree().process_frame
	_check(
		_pending_path(handler) == ANTI_AIR,
		"放置中再点对空炮，待放置蓝图必须切换为对空炮，实测 %s" % _pending_path(handler)
	)
	_check(
		handler._active_blueprint_node != null and handler._active_blueprint_node != first_ghost,
		"切换后幽灵节点应替换为新实例（不得继续用机场那一个）"
	)
	_check(
		not is_instance_valid(first_ghost) or first_ghost.is_queued_for_deletion(),
		"切换后旧幽灵节点应释放，不得同时残留两个蓝图"
	)
	var second_ghost = handler._active_blueprint_node
	_check(
		second_ghost != null and not second_ghost.is_queued_for_deletion(),
		"切换后新幽灵节点应处于活动状态"
	)

	# 同一建筑重复点：保持现状，不重建、不取消（避免误触把已摆好的蓝图抖掉）。
	# 必须先断言节点非空，否则 `null == null` 会让这条断言永远绿。
	MatchSignals.place_structure.emit(anti_air)
	await get_tree().process_frame
	_check(second_ghost != null, "重复点断言的前提：切换后应存在幽灵节点")
	if second_ghost != null:
		_check(
			handler._active_blueprint_node == second_ghost,
			"重复点同一个建筑不应重建幽灵节点"
		)


## 层 2：真实侧栏点击路径（用户实际操作的那条）。
## headless 下 Match 不挂侧栏，这里手动挂一份，只覆盖「点格子 → 蓝图切换」这段 UI 逻辑。
func _check_sidebar_layer(match_instance, human, handler) -> void:
	var hud = match_instance.get_node_or_null("HUD")
	_check(hud != null, "对局应有 HUD 节点")
	if hud == null:
		return
	var sidebar = SidebarScript.new()
	sidebar.name = "ProbeRa3Sidebar"
	hud.add_child(sidebar)
	await get_tree().process_frame
	await get_tree().process_frame

	# 保证「机场」「对空炮」都处于可点状态：worker 口径下放置需要施工者，各建一个。
	var tank = match_instance.get_node_or_null("Players/Human/Tank")
	var anchor: Vector3 = tank.global_position if tank != null else Vector3(13.0, 0.0, 13.0)
	var worker = WorkerScene.instantiate()
	match_instance.call(
		"_setup_and_spawn_unit",
		worker,
		Transform3D(Basis.IDENTITY, anchor + Vector3(3.0, 0.0, 0.0)),
		human,
		false
	)
	await get_tree().process_frame
	sidebar._refresh_cells()
	await get_tree().process_frame

	# 从干净状态起步：清掉层 1 留下的放置态。
	handler._cancel_structure_placement()
	await get_tree().process_frame

	var airport_cell = _find_cell(sidebar, "机场")
	var anti_air_cell = _find_cell(sidebar, "对空炮")
	_check(airport_cell != null, "「建筑」页签应存在「机场」格子")
	_check(anti_air_cell != null, "「建筑」页签应存在「对空炮」格子")
	if airport_cell == null or anti_air_cell == null:
		return

	airport_cell.button.pressed.emit()
	await get_tree().process_frame
	_check(
		_pending_path(handler) == AIRPORT,
		"侧栏点「机场」后待放置蓝图应为机场，实测 %s" % _pending_path(handler)
	)

	anti_air_cell.button.pressed.emit()
	await get_tree().process_frame
	_check(
		_pending_path(handler) == ANTI_AIR,
		"侧栏点「对空炮」后待放置蓝图必须切换为对空炮，实测 %s" % _pending_path(handler)
	)
	_check(
		handler._active_blueprint_node != null and not handler._active_blueprint_node.is_queued_for_deletion(),
		"侧栏切换后应仍有活动幽灵节点"
	)


func _find_cell(sidebar, caption: String):
	for cell in sidebar._cells:
		if str(cell.item.get("caption", "")) == caption:
			return cell
	return null


func _pending_path(handler) -> String:
	var prototype = handler._pending_structure_prototype
	if prototype == null:
		return ""
	return str(prototype.resource_path)


func _signal_wired(handler) -> bool:
	for connection in MatchSignals.place_structure.get_connections():
		if connection.callable.get_object() == handler:
			return true
	return false


func _finish(match_instance):
	print("Blueprint switch smoke test completed: %d failure(s)" % _failures)
	match_instance.queue_free()
	await get_tree().process_frame
	SmokeTestExit.request(get_tree(), 0 if _failures == 0 else 1)


func _check(condition: bool, message: String):
	if condition:
		return
	_failures += 1
	push_error("Blueprint switch assertion failed: %s" % message)
