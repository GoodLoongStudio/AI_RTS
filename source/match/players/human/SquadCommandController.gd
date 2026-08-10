extends Node

signal active_squad_changed(squad_id)
signal command_target_requested(command, target_kind)
signal command_executed(command, message)
signal command_rejected(command, reason)

const SquadCommand = preload("res://source/match/commands/SquadCommand.gd")
const Moving = preload("res://source/match/units/actions/Moving.gd")
const AutoAttacking = preload("res://source/match/units/actions/AutoAttacking.gd")
const WaitingForTargets = preload("res://source/match/units/actions/WaitingForTargets.gd")

const SQUAD_NAMES = {1: "突击队", 2: "侦察队", 3: "支援队"}

var active_squad := 1
var pending_command = null
var squad_status := {1: "待命", 2: "待命", 3: "待命"}


func select_squad(squad_id: int) -> bool:
	if squad_id not in SQUAD_NAMES:
		return false
	if pending_command != null and pending_command.squad_id != squad_id:
		pending_command = null
	active_squad = squad_id
	var units = get_squad_units(squad_id)
	if not units.is_empty():
		Utils.Match.select_units(Utils.Set.from_array(units))
	active_squad_changed.emit(squad_id)
	return not units.is_empty()


func begin_command(command_type: int, source: String = "ui", raw_text: String = ""):
	var command = SquadCommand.new(active_squad, command_type, source, raw_text)
	if get_squad_units(active_squad).is_empty():
		command_rejected.emit(
			command,
			"%d %s 尚未编组。先框选单位并用 Ctrl+%d 保存编组。"
			% [active_squad, SQUAD_NAMES[active_squad], active_squad]
		)
		return null

	# Always restore the squad selection before accepting a command so UI/chat/hotkeys
	# all operate on the same unit set.
	select_squad(active_squad)
	pending_command = null

	if command_type == SquadCommand.Type.DEFEND:
		_execute_defend(command)
	elif command_type == SquadCommand.Type.STOP:
		_execute_stop(command)
	elif command.requires_terrain_target():
		pending_command = command
		command_target_requested.emit(command, "terrain")
	elif command.requires_unit_target():
		pending_command = command
		command_target_requested.emit(command, "unit")
	else:
		command_rejected.emit(command, "当前命令类型尚未实现。")
	return command


func cancel_pending_command():
	pending_command = null


func try_handle_terrain_target(position: Vector3) -> bool:
	if pending_command == null or not pending_command.requires_terrain_target():
		return false
	var command = pending_command
	pending_command = null
	command.target_position = position
	_execute_movement_command(command)
	return true


func try_handle_unit_target(unit) -> bool:
	if pending_command == null or not pending_command.requires_unit_target():
		return false
	var command = pending_command
	pending_command = null
	if not unit.is_in_group("adversary_units"):
		command_rejected.emit(command, "攻击命令只能指定敌方单位。")
		return true
	command.target_unit = unit
	_execute_attack(command)
	return true


func get_squad_units(squad_id: int) -> Array:
	return get_tree().get_nodes_in_group("unit_group_%d" % squad_id).filter(
		func(unit): return unit.is_in_group("controlled_units")
	)


func get_squad_status(squad_id: int) -> String:
	return squad_status.get(squad_id, "未知")


func _execute_movement_command(command):
	var units = get_squad_units(command.squad_id).filter(
		func(unit): return Moving.is_applicable(unit)
	)
	var terrain_units = units.filter(
		func(unit): return unit.movement_domain == Constants.Match.Navigation.Domain.TERRAIN
	)
	var air_units = units.filter(
		func(unit): return unit.movement_domain == Constants.Match.Navigation.Domain.AIR
	)
	var targets = Utils.Match.Unit.Movement.crowd_moved_to_new_pivot(
		terrain_units, command.target_position
	)
	targets += Utils.Match.Unit.Movement.crowd_moved_to_new_pivot(
		air_units, command.target_position
	)
	for tuple in targets:
		tuple[0].action = Moving.new(tuple[1])

	var label = SquadCommand.type_label(command.type)
	squad_status[command.squad_id] = "%s中" % label
	command_executed.emit(
		command,
		"%d %s：%s。" % [command.squad_id, SQUAD_NAMES[command.squad_id], label]
	)


func _execute_attack(command):
	var attackers := 0
	for unit in get_squad_units(command.squad_id):
		if AutoAttacking.is_applicable(unit, command.target_unit):
			unit.action = AutoAttacking.new(command.target_unit)
			attackers += 1
	if attackers == 0:
		command_rejected.emit(command, "当前小队没有能够攻击该目标的单位。")
		return

	var targetability = command.target_unit.find_child("Targetability")
	if targetability != null:
		targetability.animate()
	squad_status[command.squad_id] = "交战中"
	command_executed.emit(
		command,
		"%d %s：攻击 %s。"
		% [command.squad_id, SQUAD_NAMES[command.squad_id], command.target_unit.type]
	)


func _execute_defend(command):
	for unit in get_squad_units(command.squad_id):
		if unit.attack_range != null:
			unit.action = WaitingForTargets.new()
		else:
			unit.action = null
	squad_status[command.squad_id] = "固守中"
	command_executed.emit(
		command,
		"%d %s：原地防守，不主动追击。"
		% [command.squad_id, SQUAD_NAMES[command.squad_id]]
	)


func _execute_stop(command):
	for unit in get_squad_units(command.squad_id):
		unit.action = null
	squad_status[command.squad_id] = "待命"
	command_executed.emit(
		command,
		"%d %s：停止当前任务。" % [command.squad_id, SQUAD_NAMES[command.squad_id]]
	)
