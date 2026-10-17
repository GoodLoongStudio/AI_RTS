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

const CommandCenterScene = preload("res://source/match/units/CommandCenter.tscn")
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
	await _check_end_to_end_layer(match_instance, human, handler)
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
	var build_area = handler._build_range_rings
	_check(build_area != null, "进入放置模式后应创建地面建造范围显示")
	if build_area != null:
		_check(build_area is MeshInstance3D, "建造范围显示应是可渲染的 MeshInstance3D")
		var area_material = build_area.material_override
		_check(
			area_material is StandardMaterial3D
				and is_equal_approx((area_material as StandardMaterial3D).albedo_color.a, 0.22),
			"建造范围应使用白色半透明材质"
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


## 层 1.5：端到端 —— 切换后的蓝图**真的落地**的必须是新建筑。
##
## 只断言 `_pending_structure_prototype` 变了还不够：万一后续放置链路
## （`_finish_structure_placement` 或 C# `StructurePlacementRuntime.Place`）仍按旧场景
## 生成，玩家落下去的依然是机场、白高兴一场。这里把蓝图挪到合法点直接落下去，
## 数场景里新增的对空炮 / 没新增的机场。
func _check_end_to_end_layer(match_instance, human, handler) -> void:
	# reason 必须走既有白名单："ScriptedAdjustment"（`StructurePlacementSmokeTest` 同款）。
	# 自造 reason 会被**静默拒绝**，表现为后续 validity=NOT_ENOUGH_RESOURCES。
	var injected: bool = human.add_resources(
		{"resource_a": 100000, "resource_b": 100000}, "ScriptedAdjustment"
	)
	_check(injected, "端到端：测试资源注入应成功（reason 需在白名单内）")
	await get_tree().process_frame

	MatchSignals.place_structure.emit(load(AIRPORT))
	await get_tree().process_frame
	MatchSignals.place_structure.emit(load(ANTI_AIR))
	await get_tree().process_frame

	var blueprint = handler._active_blueprint_node
	_check(blueprint != null, "端到端：切换后应有活动蓝图")
	if blueprint == null:
		return

	var tank = match_instance.get_node_or_null("Players/Human/Tank")
	var anchor: Vector3 = tank.global_position if tank != null else Vector3(13.0, 0.0, 13.0)
	# 【2026-09-30 夹具修正】TestOneUnit 场景里**没有任何己方建筑**，而建筑放置要求
	# "与己方建筑相邻"（圆心距 <= 候选半径 + 已有半径 + 0.75）。旧实现把蓝图摆在
	# anchor+7 随便一个位置 → 权威判定必然 NotAdjacent；自动选址也永远找不到合法点
	# （实测 198 次采样全 NotAdjacent，诊断清单打印出 0 座可相邻的己方建筑）。
	# 本测试要测的是"切换后落地的是新建筑"，所以先给玩家造一座主基地，
	# 再把蓝图精确摆进相邻窗口（避免把"夹具没有基地"误判成放置链路坏了）。
	var base_structure: Node3D = CommandCenterScene.instantiate()
	match_instance.call(
		"_setup_and_spawn_unit",
		base_structure,
		Transform3D(Basis.IDENTITY, anchor + Vector3(0.0, 0.0, 12.0)),
		human,
		false
	)
	await get_tree().process_frame
	await get_tree().physics_frame
	var active_build_area = handler._build_range_rings
	if active_build_area != null:
		for _frame in range(30):
			if active_build_area.mesh != null:
				break
			await get_tree().process_frame
		_check(
			active_build_area.mesh != null and active_build_area.mesh.get_surface_count() > 0,
			"已有己方建筑后，建造范围显示应生成白色地面面片"
		)
	var turret_probe: Node3D = load(ANTI_AIR).instantiate()
	var turret_radius := float(turret_probe.body_radius())
	turret_probe.free()
	var window_center := float(base_structure.body_radius()) + turret_radius + 0.375
	blueprint.global_transform.origin = base_structure.global_position + Vector3(window_center, 0.0, 0.0)
	print("[probe] 相邻窗口中心=%.2f（基地 r=%.2f + 炮塔 r=%.2f + 0.375）" % [
		window_center, float(base_structure.body_radius()), turret_radius])
	await get_tree().process_frame
	print(
		"[probe] e2e validity=%s issues=%s" % [
			str(handler._calculate_blueprint_position_validity()),
			str(
				handler._placement_runtime.Evaluate(
					human, handler._pending_structure_prototype, blueprint.global_transform, {}
				).get("issues")
			),
		]
	)

	var before := _count_scene_nodes(human, "AntiAirTurret.tscn")
	var before_airport := _count_scene_nodes(human, "AircraftFactory.tscn")
	handler._finish_structure_placement()
	for _frame in range(4):
		await get_tree().process_frame
	var after := _count_scene_nodes(human, "AntiAirTurret.tscn")
	var after_airport := _count_scene_nodes(human, "AircraftFactory.tscn")

	_check(
		after > before,
		"端到端：切换后的蓝图落地应生成对空炮（对空炮 %d → %d）" % [before, after]
	)
	_check(
		after_airport == before_airport,
		"端到端：落地不得生成机场（机场 %d → %d）—— 说明仍在用旧原型" % [before_airport, after_airport]
	)
	if after > before:
		_check(
			handler._active_blueprint_node == null,
			"端到端：成功落地后应退出放置模式"
		)


## 递归数一下某个玩家名下挂了几份指定场景（含运行时实例化的，故 owned=false）。
##
## ⚠️ 必须排除 `structure-geometries/`：蓝图（幽灵）用的是与真建筑**同名**的场景
## （`structure-geometries/AntiAirTurret.tscn`），不排除就会把幽灵当成"已落地建筑"，
## 于是"落地前后都是 1"看起来像放置失败，其实是计数口径错了。
func _count_scene_nodes(root: Node, suffix: String) -> int:
	var count := 0
	for node in root.find_children("*", "", true, false):
		var scene_path := str(node.scene_file_path)
		if not scene_path.ends_with(suffix):
			continue
		if scene_path.contains("/structure-geometries/"):
			continue
		count += 1
	return count


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
