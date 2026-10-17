extends "res://tests/automated/_ProjectileOriginVisualProbe.gd"

## Diagnostic Match: real attack orders plus model geometry, never OS input.
const BATTLE_OUT := "res://agent/runs/20261010-projectile-origin/battle"
var _shots := 0
var _seen := {}
var _active_shooter: Node3D
var _active_target: Node3D
var _active_type := ""
var _events: Array = []
var _camera: Camera3D


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(BATTLE_OUT))
	var settings := MatchSettings.new()
	for color in [Color.BLUE, Color.RED]:
		var player_settings := PlayerSettings.new()
		player_settings.controller = Constants.PlayerType.HUMAN
		player_settings.color = color
		settings.players.append(player_settings)
	_match = load("res://source/match/Match.tscn").instantiate()
	_match.settings = settings
	_match.map = load("res://source/match/maps/PlainAndSimple.tscn").instantiate()
	get_tree().root.add_child.call_deferred(_match)
	await get_tree().process_frame
	await _wait_for_match_ready()
	_projectiles = _match.get_node("Projectiles")
	_match._disable_war_fog()
	for layer in _match.find_children("*", "CanvasLayer", true, false):
		layer.visible = false
	var old_camera = _match.get_node("IsometricCamera3D")
	old_camera.set_process(false)
	old_camera.set_physics_process(false)
	_camera = Camera3D.new()
	_camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	_camera.size = 16.0
	_match.add_child(_camera)
	_camera.make_current()
	var focus := Vector3(84, 1, 80)
	_camera.global_position = focus + Vector3(0, 15, 11)
	_camera.look_at(focus)
	await get_tree().create_timer(1.0).timeout
	if DisplayServer.get_name() != "headless":
		FileAccess.open(BATTLE_OUT + "/ready.json", FileAccess.WRITE).store_string(
			JSON.stringify({"pid": OS.get_process_id(), "unix": Time.get_unix_time_from_system()}))
		var deadline := Time.get_ticks_msec() + 30000
		while not FileAccess.file_exists(BATTLE_OUT + "/start.flag") and Time.get_ticks_msec() < deadline:
			await get_tree().process_frame
		await get_tree().create_timer(1.0).timeout
	var players = _match.get_node("Players")
	var human = players.get_child(0)
	var enemy = players.get_child(1)
	var gateway = human.get_node("UnitCommandGateway")
	var catalog = _match.get_node("BalanceConfigRuntime")
	var runtime = _match.get_node("ProjectileRuntime")
	for type_id in ["anti_ground_turret", "machine_gun_turret", "tank", "heavy_tank", "soldier", "sniper", "rocketeer", "helicopter", "anti_air_turret", "apc"]:
		var shooter := _spawn_unit(catalog, type_id, human, Vector3(80, 6 if type_id == "helicopter" else 0, 80))
		var target_type := "helicopter" if type_id == "anti_air_turret" else "tank"
		var distance := maxf(minf(float(shooter.attack_range) * 0.65, 10.0), 5.0)
		var target := _spawn_unit(catalog, target_type, enemy, Vector3(80 + distance, 6 if target_type == "helicopter" else 0, 80))
		gateway.SetFirePolicy([shooter], "HoldFire", human)
		enemy.get_node("UnitCommandGateway").SetFirePolicy([target], "HoldFire", enemy)
		target.hp = 10000.0
		await get_tree().create_timer(0.4).timeout
		var idle_trait := shooter.find_child("RotateRandomlyWhenLookingForTargets", false, false)
		if idle_trait != null:
			idle_trait.set_physics_process(false)
		# Rotate the actual model/hierarchy, and fire three times per orientation.
		for yaw in [0.0, PI / 2.0, PI]:
			var aim = shooter.presentation_aim_node()
			if aim != null: aim.global_rotation.y = yaw
			else: shooter.rotation.y = yaw
			await get_tree().process_frame
			_validate_barrel_alignment(shooter, type_id)
			shooter.set_meta("muzzle_next_left", true)
			for shot in range(3):
				var attack_id: String = runtime.LaunchEntity(shooter, target, false)
				var record := _capture_record(type_id, shooter, target, attack_id)
				_validate_record(record)
				var marker_name := "MuzzleL" if shot % 2 == 0 else "MuzzleR"
				var marker := shooter.find_child(marker_name, true, false) as Node3D
				if marker != null:
					_check(_from_vec(record.projectile_root).distance_to(marker.global_position) < 0.001,
						"%s 应左右交替，yaw=%.2f shot=%d" % [type_id, yaw, shot])
				_projectile_by_attack_id(attack_id).queue_free()
			await get_tree().process_frame
		_active_shooter = shooter
		_active_target = target
		_active_type = type_id
		_shots = 0
		shooter.set_meta("muzzle_next_left", true)
		shooter.attack_fired.connect(_observe_fired)
		var rejected: Dictionary = gateway.AttackUnits([shooter], target, human)
		_check(rejected.status == "Rejected", "HoldFire 应拒绝普通攻击")
		gateway.SetFirePolicy([shooter], "FireAtWill", human)
		var accepted: Dictionary = gateway.AttackUnits([shooter], target, human)
		_check(accepted.status == "Accepted", "%s 正常攻击命令应接受" % type_id)
		var shot_deadline := Time.get_ticks_msec() + 12000
		while _shots < 2 and Time.get_ticks_msec() < shot_deadline:
			await get_tree().process_frame
		_check(_shots >= 2, "%s 应完成转向并连续开火" % type_id)
		gateway.SetFirePolicy([shooter], "HoldFire", human)
		gateway.StopUnits([shooter], human)
		await get_tree().create_timer(2.0).timeout
		_check(target.hp < 10000.0, "%s 已发射弹体在 Stop 后仍应结算" % type_id)
		_events.append({"type": type_id, "shots": _shots, "hp": target.hp,
			"unix": Time.get_unix_time_from_system()})
		shooter.attack_fired.disconnect(_observe_fired)
		shooter.queue_free()
		target.queue_free()
		await get_tree().process_frame
	var file := FileAccess.open(BATTLE_OUT + "/result.json", FileAccess.WRITE)
	file.store_string(JSON.stringify({"failures": _failures, "pid": OS.get_process_id(),
		"records": _records, "events": _events}, "  "))
	_match.queue_free()
	await get_tree().create_timer(0.3).timeout
	print("Projectile origin battle probe completed: %d failure(s)" % _failures)
	get_tree().quit(0 if _failures == 0 else 1)


func _observe_fired() -> void:
	_shots += 1
	for projectile in _projectiles.get_children():
		if not (projectile is Node3D) or not ("attack_id" in projectile): continue
		var attack_id := str(projectile.attack_id)
		if _seen.has(attack_id): continue
		_seen[attack_id] = true
		var record := _capture_record(_active_type, _active_shooter, _active_target, attack_id)
		record["unix"] = Time.get_unix_time_from_system()
		record["physics_frame"] = Engine.get_physics_frames()
		_validate_record(record)
		_records.append(record)
