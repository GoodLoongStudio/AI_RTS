extends Node

## 玩家路径探针：选中重型坦克，用真实视口右键确认命令卡上的选目标指令。
## 既有冒烟测试直接 emit unit_targeted / 调网关，会绕过
## UnitActionsController._unhandled_input 对右键的消费。

const MatchScene = preload("res://tests/manual/TestAllUnits.tscn")
const HeavyTankScene = preload("res://source/match/units/HeavyTank.tscn")
const ExplicitForceAttacking = preload(
	"res://source/match/units/actions/ExplicitForceAttacking.gd"
)
const TacticalWithdrawing = preload("res://source/match/units/actions/TacticalWithdrawing.gd")
const Moving = preload("res://source/match/units/actions/Moving.gd")
const GroundAttackMoving = preload("res://source/match/units/actions/GroundAttackMoving.gd")

var _failures := 0
var _finished := false
var _match: Node = null
var _feedback: Array[Dictionary] = []
var _orders: Array[Dictionary] = []
var _terrain_hits := 0
var _unit_hits: Array[String] = []


func _ready() -> void:
	get_tree().create_timer(90.0).timeout.connect(_on_failsafe)
	_match = MatchScene.instantiate()
	add_child(_match)
	var human = _match.get_node("Players/Human")
	var units_ready := false
	for _frame in 600:
		if (
			get_tree().get_nodes_in_group("units").size() >= 1
			and human.get_node_or_null("VehicleFactory") != null
			and human.get_node_or_null("UnitActionsController") != null
			and human.get_node("UnitActionsController").is_in_group("unit_actions_controller")
		):
			units_ready = true
			break
		await get_tree().process_frame
	if not units_ready:
		_fail("对局单位或本地命令控制器未就绪")
		_finish()
		return
	await get_tree().create_timer(0.3).timeout
	var factory = human.get_node("VehicleFactory")
	var controller = human.get_node("UnitActionsController")
	var input_runtime = _match.get_node("InputBindingRuntime")
	var hud = _find_command_hud()
	_check(hud != null, "应能找到命令卡")
	controller.command_feedback.connect(_on_feedback)
	_match.get_node("CommandRuntime").connect("OrderStateChanged", _on_order)
	MatchSignals.terrain_targeted.connect(func(_position): _terrain_hits += 1)
	MatchSignals.unit_targeted.connect(func(unit, _position): _unit_hits.append(str(unit.name)))

	var tank = HeavyTankScene.instantiate()
	tank.name = "ProbeHeavyTank"
	MatchSignals.setup_and_spawn_unit.emit(
		tank,
		Transform3D(Basis.IDENTITY, factory.global_position + Vector3(10.0, 0.0, 0.0)),
		human,
		false
	)
	await get_tree().process_frame
	await get_tree().create_timer(0.4).timeout
	_check(tank.get("attack_range") != null, "重型坦克应有攻击射程")
	await _select_only(tank)
	var camera: Camera3D = get_viewport().get_camera_3d()
	_check(camera != null, "探针需要对局相机")
	if camera == null:
		_finish()
		return
	camera.set_process(false)
	camera.set_process_unhandled_input(false)
	var view_size: Vector2 = get_viewport().get_visible_rect().size
	var factory_screen := Vector2(view_size.x * 0.42, view_size.y * 0.48)
	var ground_screen := Vector2(view_size.x * 0.42, view_size.y * 0.68)
	var retreat_screen := Vector2(view_size.x * 0.58, view_size.y * 0.62)
	var factory_hit = camera.get_ray_intersection(factory_screen)
	var ground_hit = camera.get_ray_intersection(ground_screen)
	var retreat_hit = camera.get_ray_intersection(retreat_screen)
	if factory_hit == null or ground_hit == null or retreat_hit == null:
		_fail("相机射线没有落到地面")
		_finish()
		return
	var factory_world: Vector3 = factory_hit
	factory.global_position = factory_world
	tank.global_position = factory_world + Vector3(8.0, 0.0, 0.0)
	factory.reset_physics_interpolation()
	tank.reset_physics_interpolation()
	await get_tree().physics_frame
	await get_tree().physics_frame
	print(
		"[PROBE] screens factory=%s ground=%s retreat=%s viewport=%s" % [
			factory_screen, ground_screen, retreat_screen, get_viewport().get_visible_rect().size
		]
	)
	print("[PROBE] factory ray=%s" % _ray_name(camera, factory_screen))
	print("[PROBE] ground ray=%s" % _ray_name(camera, ground_screen))

	_reset_counts()
	await _click(MOUSE_BUTTON_RIGHT, ground_screen)
	print(
		"[PROBE] baseline_ground terrain=%d units=%s orders=%s feedback=%s" % [
			_terrain_hits, _unit_hits, _order_kinds(), _feedback_names()
		]
	)
	var baseline_terrain := _terrain_hits

	input_runtime.emit_signal("ActionPressed", "unit.stop")
	await get_tree().process_frame
	_reset_counts()
	await _select_only(tank)
	await get_tree().process_frame
	input_runtime.emit_signal("ActionPressed", "unit.force_attack")
	await get_tree().process_frame
	var attack_button: String = "" if hud == null else str(hud.get_node("%ForceAttackButton").text)
	print(
		"[PROBE] after_X targeting=%s button=%s" % [
			controller.get_active_command_targeting(), attack_button
		]
	)
	_check(controller.get_active_command_targeting() == "ForceAttack", "X 应进入强制攻击选目标")
	_check("取消强制攻击" in attack_button, "进入强制攻击后按钮应变成取消")
	var hp_before: float = factory.hp
	var pos_before: Vector3 = tank.global_position
	_reset_counts()
	await _click(MOUSE_BUTTON_RIGHT, factory_screen)
	await get_tree().process_frame
	print(
		"[PROBE] after_X_click targeting=%s action=%s terrain=%d units=%s orders=%s feedback=%s" % [
			controller.get_active_command_targeting(),
			_action_name(tank),
			_terrain_hits,
			_unit_hits,
			_order_kinds(),
			_feedback
		]
	)
	_check(controller.get_active_command_targeting() == "", "右键确认后应退出强制攻击选目标")
	_check(_has_order("ForceAttack"), "右键车厂应产生 ForceAttack 订单")
	_check(
		tank.action != null and tank.action.get_script() == ExplicitForceAttacking,
		"重型坦克应进入 ExplicitForceAttacking（实际 %s）" % _action_name(tank)
	)
	var waited := 0.0
	while factory.hp >= hp_before - 0.05 and waited < 6.0:
		await get_tree().create_timer(0.25).timeout
		waited += 0.25
	var moved_to_factory: bool = tank.global_position.distance_to(pos_before) > 0.35
	print(
		"[PROBE] force_attack_result hp %s→%s moved=%s action=%s dist=%s" % [
			hp_before,
			factory.hp,
			moved_to_factory,
			_action_name(tank),
			tank.global_position.distance_to(factory.global_position)
		]
	)
	_check(
		_has_order("ForceAttack") and (factory.hp < hp_before - 0.05 or (
			tank.action != null and tank.action.get_script() == ExplicitForceAttacking and moved_to_factory
		)),
		"强制攻击车厂后应接令并开火或朝车厂移动（hp %s→%s action=%s）" % [
			hp_before, factory.hp, _action_name(tank)
		]
	)

	input_runtime.emit_signal("ActionPressed", "unit.stop")
	await get_tree().process_frame
	_reset_counts()
	await _select_only(tank)
	await get_tree().process_frame
	input_runtime.emit_signal("ActionPressed", "unit.tactical_withdraw")
	await get_tree().process_frame
	var withdraw_button: String = "" if hud == null else str(hud.get_node("%TacticalWithdrawButton").text)
	print(
		"[PROBE] after_Z targeting=%s button=%s" % [
			controller.get_active_command_targeting(), withdraw_button
		]
	)
	_check(controller.get_active_command_targeting() == "TacticalWithdraw", "Z 应进入战术后退选目标")
	var retreat_from: Vector3 = tank.global_position
	var retreat_click: Vector2 = _find_clear_ground_screen(get_viewport().get_camera_3d(), tank)
	_reset_counts()
	await _click(MOUSE_BUTTON_RIGHT, retreat_click)
	var got_withdraw := await _wait_for_order("TacticalWithdraw", 1.0)
	var movement = tank.get_node("Movement")
	print(
		"[PROBE] after_Z_click screen=%s ray=%s targeting=%s action=%s reverse=%s terrain=%d units=%s orders=%s feedback=%s" % [
			retreat_click,
			_ray_name(get_viewport().get_camera_3d(), retreat_click),
			controller.get_active_command_targeting(),
			_action_name(tank),
			movement.get("_is_tactical_withdrawal"),
			_terrain_hits,
			_unit_hits,
			_order_kinds(),
			_feedback
		]
	)
	_check(got_withdraw, "右键地面应产生 TacticalWithdraw 订单")
	_check(
		not _has_order("Move"),
		"战术后退确认不应被同一次点击的普通移动顶掉（orders=%s）" % _order_kinds()
	)
	_check(
		tank.action != null and tank.action.get_script() == TacticalWithdrawing,
		"战术后退应保持 TacticalWithdrawing（实际 %s）" % _action_name(tank)
	)
	_check(bool(movement.get("_is_tactical_withdrawal")), "战术后退应启用倒车")
	await get_tree().create_timer(1.2).timeout
	var retreat_delta: Vector3 = tank.global_position - retreat_from
	print(
		"[PROBE] retreat_delta=%s reverse_after=%s action=%s" % [
			retreat_delta, movement.get("_is_tactical_withdrawal"), _action_name(tank)
		]
	)
	_check(retreat_delta.length() > 0.4, "战术后退 1.2 秒内应离开原位（位移 %s）" % retreat_delta)

	input_runtime.emit_signal("ActionPressed", "unit.stop")
	await get_tree().process_frame
	await _check_force_move(input_runtime, controller, tank)
	await _check_attack_move(input_runtime, controller, tank, ground_screen)
	await _check_immediate(input_runtime, controller, tank, human, factory)

	controller.begin_repair_targeting()
	_check(controller.is_repair_targeting(), "维修模式应能进入")
	_reset_counts()
	await _click(MOUSE_BUTTON_RIGHT, ground_screen)
	await get_tree().physics_frame
	print("[PROBE] repair_right_click targeting=%s orders=%s" % [
		controller.get_active_command_targeting(), _order_kinds()
	])
	_check(not controller.is_repair_targeting(), "维修模式右键应退出，不把右键当成确认")
	_check(not _has_order("Move"), "维修模式右键不应顺便下达移动")

	print("[PROBE] baseline_terrain_count=%d" % baseline_terrain)
	print("Command card right-click probe completed: %d failure(s)" % _failures)
	_finish()


func _check_force_move(input_runtime, controller, tank) -> void:
	_reset_counts()
	await _select_only(tank)
	await get_tree().process_frame
	input_runtime.emit_signal("ActionPressed", "unit.force_move")
	await get_tree().process_frame
	_check(controller.get_active_command_targeting() == "ForceMove", "C 应进入强制移动选目标")
	var camera: Camera3D = get_viewport().get_camera_3d()
	var clear_ground := _find_clear_ground_screen(camera, tank)
	_reset_counts()
	await _click(MOUSE_BUTTON_RIGHT, clear_ground)
	await get_tree().process_frame
	print(
		"[PROBE] force_move screen=%s ray=%s targeting=%s terrain=%d units=%s orders=%s action=%s feedback=%s" % [
			clear_ground,
			_ray_name(camera, clear_ground),
			controller.get_active_command_targeting(),
			_terrain_hits,
			_unit_hits,
			_order_kinds(),
			_action_name(tank),
			_feedback,
		]
	)
	_check(_has_order("ForceMove"), "C + 右键地面应产生 ForceMove 订单")
	_check(
		tank.action != null and tank.action.get_script() == Moving,
		"强制移动应驱动 Moving（实际 %s）" % _action_name(tank)
	)
	input_runtime.emit_signal("ActionPressed", "unit.stop")
	await get_tree().process_frame


func _check_attack_move(input_runtime, controller, tank, ground_screen: Vector2) -> void:
	_reset_counts()
	await _select_only(tank)
	await get_tree().process_frame
	input_runtime.emit_signal("ActionPressed", "unit.attack_move")
	await get_tree().process_frame
	_check(controller.is_ground_attack_move_targeting(), "A 应进入移动并攻击选目标")
	_reset_counts()
	await _click(MOUSE_BUTTON_RIGHT, ground_screen)
	await get_tree().process_frame
	print("[PROBE] attack_move_right orders=%s action=%s" % [_order_kinds(), _action_name(tank)])
	_check(_has_order("GroundAttackMove"), "A + 右键地面应产生 GroundAttackMove 订单")
	_check(
		tank.action != null and tank.action.get_script() == GroundAttackMoving,
		"移动并攻击应驱动 GroundAttackMoving（实际 %s）" % _action_name(tank)
	)
	input_runtime.emit_signal("ActionPressed", "unit.stop")
	await get_tree().process_frame
	await _select_only(tank)
	await get_tree().process_frame
	input_runtime.emit_signal("ActionPressed", "unit.attack_move")
	await get_tree().process_frame
	_reset_counts()
	await _click(MOUSE_BUTTON_LEFT, ground_screen)
	await get_tree().process_frame
	print("[PROBE] attack_move_left orders=%s action=%s" % [_order_kinds(), _action_name(tank)])
	_check(_has_order("GroundAttackMove"), "A + 左键地面应产生 GroundAttackMove 订单")
	input_runtime.emit_signal("ActionPressed", "unit.stop")
	await get_tree().process_frame


func _check_immediate(input_runtime, controller, tank, human, factory) -> void:
	await _select_only(tank)
	await get_tree().process_frame
	_reset_counts()
	input_runtime.emit_signal("ActionPressed", "unit.stance_aggressive")
	await get_tree().process_frame
	print("[PROBE] aggressive stance=%s feedback=%s" % [
		controller.get_selected_combat_policy("EngagementStance"), _feedback
	])
	_check(
		controller.get_selected_combat_policy("EngagementStance") == "Aggressive",
		"侵略热键应写入 Aggressive"
	)
	_reset_counts()
	input_runtime.emit_signal("ActionPressed", "unit.stance_guard")
	await get_tree().process_frame
	_check(
		controller.get_selected_combat_policy("EngagementStance") == "Guard",
		"警戒热键应写入 Guard"
	)
	_reset_counts()
	input_runtime.emit_signal("ActionPressed", "unit.stance_hold_ground")
	await get_tree().process_frame
	_check(
		controller.get_selected_combat_policy("EngagementStance") == "HoldGround",
		"固守热键应写入 HoldGround"
	)
	_reset_counts()
	input_runtime.emit_signal("ActionPressed", "unit.stance_return_to_base")
	await get_tree().process_frame
	print("[PROBE] return_to_base action=%s orders=%s feedback=%s" % [
		_action_name(tank), _order_kinds(), _feedback
	])
	_check(
		controller.get_selected_combat_policy("EngagementStance") == "ReturnToBase",
		"撤回基地热键应写入 ReturnToBase"
	)
	input_runtime.emit_signal("ActionPressed", "unit.stance_aggressive")
	await get_tree().process_frame
	input_runtime.emit_signal("ActionPressed", "unit.stop")
	await get_tree().process_frame

	_reset_counts()
	input_runtime.emit_signal("ActionPressed", "unit.force_move")
	await get_tree().process_frame
	await _click(MOUSE_BUTTON_RIGHT, get_viewport().get_camera_3d().unproject_position(
		tank.global_position + Vector3(-6.0, 0.0, 0.0)
	))
	await get_tree().process_frame
	_reset_counts()
	var hud = _find_command_hud()
	if hud != null:
		hud.get_node("%HaltButton").pressed.emit()
	await get_tree().process_frame
	print("[PROBE] halt action=%s feedback=%s order_state=%s" % [
		_action_name(tank),
		_feedback,
		human.get_node("UnitCommandGateway").GetActiveOrderState(tank)
	])
	_check(
		_feedback_names().has("HaltMovement"),
		"停止移动应反馈 HaltMovement"
	)

	_reset_counts()
	input_runtime.emit_signal("ActionPressed", "unit.toggle_hold_fire")
	await get_tree().process_frame
	print("[PROBE] hold_fire policy=%s feedback=%s" % [
		controller.get_selected_combat_policy("FirePolicy"), _feedback
	])
	_check(
		controller.get_selected_combat_policy("FirePolicy") == "HoldFire",
		"停火热键应写入 HoldFire"
	)
	input_runtime.emit_signal("ActionPressed", "unit.toggle_hold_fire")
	await get_tree().process_frame

	await _select_only(factory)
	await get_tree().process_frame
	_reset_counts()
	input_runtime.emit_signal("ActionPressed", "unit.clear_rally")
	await get_tree().process_frame
	print("[PROBE] clear_rally feedback=%s" % _feedback)
	_check(
		_feedback_names().has("ClearRallyPoint"),
		"清除集结热键应反馈 ClearRallyPoint"
	)


func _select_only(unit) -> void:
	MatchSignals.deselect_all_units.emit()
	await get_tree().process_frame
	unit.get_node("Selection").select()


func _click(button_index: int, screen_position: Vector2) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = button_index
	event.pressed = true
	event.position = screen_position
	event.global_position = screen_position
	event.button_mask = (
		MOUSE_BUTTON_MASK_RIGHT if button_index == MOUSE_BUTTON_RIGHT else MOUSE_BUTTON_MASK_LEFT
	)
	get_viewport().push_input(event, true)
	await get_tree().process_frame
	var release := InputEventMouseButton.new()
	release.button_index = button_index
	release.pressed = false
	release.position = screen_position
	release.global_position = screen_position
	get_viewport().push_input(release, true)
	await get_tree().process_frame


func _wait_for_order(kind: String, seconds: float) -> bool:
	var waited := 0.0
	while waited < seconds:
		if _has_order(kind):
			return true
		await get_tree().physics_frame
		waited += get_physics_process_delta_time()
	return false


func _find_clear_ground_screen(camera: Camera3D, tank) -> Vector2:
	var size: Vector2 = get_viewport().get_visible_rect().size
	var tank_screen: Vector2 = camera.unproject_position(tank.global_position)
	for y_ratio in [0.72, 0.3, 0.55, 0.8]:
		for x_ratio in [0.35, 0.5, 0.62]:
			var screen := Vector2(size.x * x_ratio, size.y * y_ratio)
			if screen.distance_to(tank_screen) < 80.0:
				continue
			var chain := _ray_name(camera, screen)
			if chain.ends_with("Terrain") and not chain.contains("ProbeHeavyTank") and not chain.contains("VehicleFactory"):
				return screen
	return Vector2(size.x * 0.35, size.y * 0.3)


func _ray_name(camera: Camera3D, screen_position: Vector2) -> String:
	var origin := camera.project_ray_origin(screen_position)
	var destination := origin + camera.project_ray_normal(screen_position) * 1000.0
	var excluded: Array[RID] = []
	var names: PackedStringArray = []
	for _layer in 6:
		var query := PhysicsRayQueryParameters3D.create(origin, destination)
		query.collide_with_areas = true
		query.collide_with_bodies = true
		query.collision_mask = 0xFFFFFFFF
		query.exclude = excluded
		var hit: Dictionary = camera.get_world_3d().direct_space_state.intersect_ray(query)
		if hit.is_empty():
			break
		excluded.append(hit["rid"])
		var collider = hit.get("collider")
		names.append(str(collider.name) if collider != null else "?")
	return "miss" if names.is_empty() else ",".join(names)


func _reset_counts() -> void:
	_feedback.clear()
	_orders.clear()
	_terrain_hits = 0
	_unit_hits.clear()


func _on_feedback(command_name: String, accepted: int, rejected: int, status: String) -> void:
	_feedback.append({
		"command": command_name,
		"accepted": accepted,
		"rejected": rejected,
		"status": status,
	})


func _on_order(
	_order_id: String,
	_command_id: String,
	_unit_id: String,
	kind: String,
	_previous: String,
	state: String,
	_replaced: String
) -> void:
	_orders.append({"kind": kind, "state": state})


func _order_kinds() -> Array[String]:
	var kinds: Array[String] = []
	for entry in _orders:
		kinds.append("%s:%s" % [entry["kind"], entry["state"]])
	return kinds


func _feedback_names() -> Array[String]:
	var names: Array[String] = []
	for entry in _feedback:
		names.append(str(entry["command"]))
	return names


func _has_order(kind: String) -> bool:
	for entry in _orders:
		if entry["kind"] == kind and entry["state"] == "InProgress":
			return true
	return false


func _action_name(unit) -> String:
	if unit.action == null:
		return "<none>"
	return str(unit.action.get_script().resource_path.get_file())


func _find_command_hud():
	var hud_root = _match.get_node_or_null("HUD")
	if hud_root == null:
		return null
	var candidates = hud_root.find_children("TraditionalUnitCommandHUD", "", true, false)
	return candidates[0] if not candidates.is_empty() else null


func _on_failsafe() -> void:
	if _finished:
		return
	_fail("看门狗超时")
	_finish()


func _finish() -> void:
	if _finished:
		return
	_finished = true
	print("Command card right-click probe completed: %d failure(s)" % _failures)
	SmokeTestExit.request(get_tree(), 0 if _failures == 0 else 1, _match)


func _check(condition: bool, message: String) -> void:
	if condition:
		print("[OK] %s" % message)
		return
	_fail(message)


func _fail(message: String) -> void:
	_failures += 1
	print("FAIL: %s" % message)
	push_error(message)
