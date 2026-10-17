extends Node

const Fixture = preload("res://tests/automated/AugmentMatchFixture.gd")
const Catalog = preload("res://source/match/augments/AugmentCatalog.gd")
const Mods = preload("res://source/match/augments/AugmentModifiers.gd")
const TANK = "res://source/match/units/Tank.tscn"
const INFANTRY = "res://source/match/units/Infantry.tscn"
const WORKER = "res://source/match/units/Worker.tscn"
const REFINERY = "res://source/match/units/OreRefinery.tscn"

var failures: Array = []
var measurements: Array = []
var match_root: Node
var runtime: Node
var player: Node
var enemy: Node
var damaged_events := 0


func _ready() -> void:
	await get_tree().process_frame
	var store = get_node("/root/GrowthStore")
	var saved_levels = store.state.get("levels", {}).duplicate(true)
	store.state["levels"] = {}
	GrowthModifiers.reset_cache()
	var catalog_data := Catalog.data().duplicate(true)
	match_root = await Fixture.create(get_tree())
	player = match_root.get_node("Players/Player0")
	enemy = match_root.get_node("Players/Player1")
	runtime = match_root.get_node("AugmentRuntime")
	runtime.set_process(false)
	MatchSignals.unit_damaged.connect(_on_damaged)
	var tank = Fixture.spawn(match_root, player, TANK, Vector3(15, 0, 35))
	var infantry = Fixture.spawn(match_root, player, INFANTRY, Vector3(20, 0, 35))
	# Tank has demo_on_damage_heal; use infantry so healing cannot mask measured damage.
	var enemy_tank = Fixture.spawn(match_root, enemy, INFANTRY, Vector3(23, 0, 35))
	var worker = Fixture.spawn(match_root, player, WORKER, Vector3(15, 0, 45))
	var base = player.get_node("Base")
	await get_tree().process_frame
	for unit in get_tree().get_nodes_in_group("units"):
		unit.get_parent().get_node("UnitCommandGateway").SetFirePolicy([unit], "HoldFire", unit.get_parent())
	var baseline_hit := await _hit(infantry, enemy_tank)
	_check(baseline_hit > 0, "real C# damage baseline must be positive")
	for card in catalog_data["cards"]:
		runtime._player_states.clear()
		for unit in [tank, infantry, worker, base]:
			Mods.apply_to_unit(unit, [])
			unit.set_hp_without_damage(float(unit.hp_max) * 0.5)
		Catalog._cache = catalog_data.duplicate(true)
		Catalog._cache["cards"] = [card]
		if card.id == "aug_citadel" and not OS.get_environment("AIRTS_AUGMENT_SHOTS").is_empty():
			Catalog._cache["cards"] = catalog_data["cards"].filter(
				func(item): return item.id in ["aug_warpath", "aug_citadel", "aug_gather_plus"])
		Catalog._cache["rounds"] = []
		var before_money := _balance()
		var enemy_hp_max := float(enemy_tank.hp_max)
		var old_worker_hp := float(worker.hp_max)
		var old_tank_hp := float(tank.hp_max)
		var old_base_hp := float(base.hp_max)
		var old_sight := float(tank.sight_range)
		var fog = match_root.get_node("FogOfWar")
		var boundary: Vector3 = tank.global_position + Vector3(0, 0, -(old_sight * 1.1 + 2.0))
		# Isolate this observer for the boundary query, retaining the real visibility service.
		var other_sights := {}
		for unit in get_tree().get_nodes_in_group("units"):
			if unit.get_parent() == player and unit != tank:
				other_sights[unit] = unit.sight_range
				unit.sight_range = 0.0
		var before_visible: bool = fog.player_can_see(player, boundary)
		for unit in other_sights:
			unit.sight_range = other_sights[unit]
		_check(runtime.debug_force_round(0, player).get("ok", false), "open " + str(card.id))
		var overlay = match_root.find_child("AugmentDraftOverlay", true, false)
		if card.id == "aug_citadel":
			await _capture("draft-before.png")
		overlay.pick_requested.emit(str(card.id))
		if card.id == "aug_citadel":
			await _capture("citadel-selected.png")
		var effect: Dictionary = card.effect
		var value := float(effect.get("value", 1.0))
		var row := {"id": card.id, "effect": effect, "before_hit": baseline_hit}
		_check(runtime.snapshot_for(player)["owned"].size() == 1, "UI selection stores one card")
		_check(is_equal_approx(float(enemy_tank.hp_max), enemy_hp_max), "enemy HP unchanged")
		_check(not runtime.pick(player, str(card.id), "duplicate").get("ok", false), "duplicate rejected")
		if effect.type == "resource_grant":
			row["credited"] = _balance() - before_money
			_check(row.credited == int(effect.resource_a), "exact cash credit " + str(card.id))
		elif effect.type == "damage_mult":
			row["after_hit"] = await _hit(infantry, enemy_tank)
			_check(is_equal_approx(float(row.after_hit), baseline_hit * value), "real damage " + str(card.id))
			_check(is_equal_approx(float(worker.damage_multiplier), 1.0), "combat bonus excludes worker")
		elif effect.type == "hp_mult":
			var target = base if effect.scope == "structure" else tank
			var initial := old_base_hp if effect.scope == "structure" else old_tank_hp
			row["before_max"] = initial
			row["after_max"] = target.hp_max
			row["after_hp"] = target.hp
			_check(is_equal_approx(float(target.hp_max), initial * value), "max HP " + str(card.id))
			_check(is_equal_approx(float(target.hp) / float(target.hp_max), 0.5), "retain wounded HP ratio")
			_check(is_equal_approx(float(worker.hp_max), old_worker_hp), "HP combat bonus excludes worker")
		elif effect.type == "sight_mult":
			row["before_sight"] = old_sight
			row["after_sight"] = tank.sight_range
			for unit in other_sights:
				unit.sight_range = 0.0
			row["before_visible"] = before_visible
			row["after_visible"] = fog.player_can_see(player, boundary)
			_check(not before_visible and row.after_visible, "actual visibility boundary expands")
			for unit in other_sights:
				unit.sight_range = other_sights[unit]
		elif effect.type == "gather_mult":
			row["delivery"] = await _gather(value)
		var new_tank = Fixture.spawn(match_root, player, TANK, Vector3(35, 0, 45))
		_check(is_equal_approx(float(new_tank.damage_multiplier), float(tank.damage_multiplier)), "spawn inherits damage")
		_check(is_equal_approx(float(new_tank.hp_max), float(tank.hp_max)), "spawn inherits max HP")
		_check(is_equal_approx(float(new_tank.sight_range), float(tank.sight_range)), "spawn inherits sight")
		var before_reapply := float(tank.hp)
		for _repeat in 3:
			runtime._on_unit_spawned(tank)
		_check(is_equal_approx(float(tank.hp), before_reapply), "reapply does not stack")
		if effect.type == "hp_mult" and effect.scope == "structure":
			var new_base = Fixture.spawn(match_root, player,
				"res://source/match/units/CommandCenter.tscn", Vector3(70, 0, 70))
			_check(is_equal_approx(float(new_base.hp_max), float(base.hp_max)), "new building inherits max HP")
			_check(is_equal_approx(float(new_base.hp), float(new_base.hp_max)), "new completed building starts full")
			new_base.queue_free()
		new_tank.queue_free()
		await get_tree().process_frame
		measurements.append(row)
	# Changing multiplier is not an attack: recomputation must not notify damage listeners.
	Mods.apply_to_unit(base, [catalog_data["cards"][5]])
	damaged_events = 0
	Mods.apply_to_unit(base, [])
	_check(damaged_events == 0, "HP recomputation must not emit unit_damaged")
	await _growth_composition(catalog_data, baseline_hit)
	store.state["levels"] = saved_levels
	GrowthModifiers.reset_cache()
	Catalog._cache = catalog_data
	var output := OS.get_environment("AIRTS_AUGMENT_OUTPUT")
	if not output.is_empty():
		var file := FileAccess.open(output, FileAccess.WRITE)
		file.store_string(JSON.stringify({"measurements": measurements, "failures": failures,
			"pid": OS.get_process_id(), "simulation_msec": match_root.get_simulation_msec()}, "\t"))
	print("Match augment effects test completed: %d failure(s)" % failures.size())
	SmokeTestExit.request(get_tree(), 0 if failures.is_empty() else 1, match_root)


func _growth_composition(catalog_data: Dictionary, baseline_hit: float) -> void:
	runtime._player_states.clear()
	get_node("/root/GrowthStore").state["levels"] = {
		"combat_power": 5, "combat_guard": 5, "combat_command": 4,
		"construction_armor": 5, "economy_gather": 5,
	}
	GrowthModifiers.reset_cache()
	var grown = Fixture.spawn(match_root, player, INFANTRY, Vector3(17, 0, 35))
	var target = Fixture.spawn(match_root, enemy, INFANTRY, Vector3(23, 0, 35))
	var base = Fixture.spawn(match_root, player,
		"res://source/match/units/CommandCenter.tscn", Vector3(70, 0, 70))
	base.set_hp_without_damage(float(base.hp_max) * 0.5)
	var grown_max := float(base.hp_max)
	_check(is_equal_approx(grown_max, 100.0), "growth building HP +25% before augment")
	_check(is_equal_approx(await _hit(grown, target), baseline_hit * 1.2), "growth actual damage +20%")
	var index := 0
	for card_id in ["aug_warpath", "aug_citadel", "aug_longwatch", "aug_gather_plus"]:
		Catalog._cache = catalog_data.duplicate(true)
		Catalog._cache["cards"] = catalog_data["cards"].filter(func(card): return card.id == card_id)
		Catalog._cache["rounds"] = []
		_check(runtime.debug_force_round(index, player).get("ok", false), "growth opens " + card_id)
		runtime._overlay.pick_requested.emit(card_id)
		index += 1
	var damage := await _hit(grown, target)
	_check(is_equal_approx(damage, baseline_hit * 1.2 * 1.25), "growth and augment actual damage multiply once")
	_check(is_equal_approx(float(base.hp_max), 135.0), "growth and augment building HP multiply once")
	_check(is_equal_approx(float(base.hp), 67.5), "combined HP preserves wounded ratio")
	_check(is_equal_approx(float(grown.sight_range), float(grown.get_meta(Mods.META_SIGHT)) * 1.2 * 1.5),
		"growth and augment sight multiply once")
	var newborn = Fixture.spawn(match_root, player, INFANTRY, Vector3(18, 0, 40))
	for _repeat in 3:
		runtime.apply_unit_bonuses(newborn)
	_check(is_equal_approx(float(newborn.damage_multiplier), 1.5), "newborn combined damage stays 1.5")
	_check(is_equal_approx(float(newborn.hp_max), float(grown.hp_max)), "newborn inherits combined HP")
	var delivery := await _gather(1.25 * 1.25)
	measurements.append({"id": "growth_composition", "before_hit": baseline_hit,
		"after_hit": damage, "before_max": grown_max, "after_max": base.hp_max,
		"after_hp": base.hp, "delivery": delivery})
	for unit in [grown, target, base, newborn]:
		unit.queue_free()
	await get_tree().process_frame


func _gather(mult: float) -> Dictionary:
	var refinery = Fixture.spawn(match_root, player, REFINERY, Vector3(30, 0, 35))
	refinery.worker_capacity = 0
	var ore = load("res://source/match/units/non-player/ResourceA.tscn").instantiate()
	ore.name = "AugmentOre"
	ore.position = Vector3(40, 0, 35)
	ore.resource_a = 40
	match_root.get_node("Map/Resources").add_child(ore)
	var worker = Fixture.spawn(match_root, player, WORKER, Vector3(43, 0, 35))
	var before := _balance()
	var result: Dictionary = player.get_node("UnitCommandGateway").GatherResources([worker], ore, player)
	_check(result.get("status", "") == "Accepted", "real Gather command accepted")
	var start := Time.get_ticks_msec()
	while Time.get_ticks_msec() - start < 20000 and _balance() == before:
		await get_tree().create_timer(0.1).timeout
	var credited := _balance() - before
	_check(credited == int(round(40.0 * mult)), "real delivery expected %d got %d" % [int(round(40.0 * mult)), credited])
	worker.queue_free()
	ore.queue_free()
	refinery.queue_free()
	await get_tree().process_frame
	return {"raw_ore": 40, "credited": credited, "mult": mult}


func _hit(source: Node, target: Node) -> float:
	target.set_hp_without_damage(float(target.hp_max))
	var before := float(target.hp)
	match_root.get_node("ProjectileRuntime").LaunchEntity(source, target, false)
	var started := Time.get_ticks_msec()
	while float(target.hp) >= before and Time.get_ticks_msec() - started < 2000:
		await get_tree().physics_frame
	return before - float(target.hp)


func _balance() -> int:
	return int(match_root.get_node("EconomyRuntime").GetSnapshot(player).get("resource_a", -1))


func _capture(filename: String) -> void:
	var path := OS.get_environment("AIRTS_AUGMENT_SHOTS")
	if path.is_empty():
		return
	var fog = match_root.get_node("FogOfWar")
	fog.set_runtime_enabled(false)
	var camera = match_root.get_node("IsometricCamera3D")
	camera.global_position = Vector3(8, 80, 113)
	if filename == "citadel-selected.png":
		player.get_node("Base").find_child("Selection").select()
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(path.path_join(filename))
	fog.set_runtime_enabled(true)


func _on_damaged(_unit: Node) -> void:
	damaged_events += 1


func _check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
		push_error("AUGMENT: " + message)
