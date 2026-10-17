extends Node

const Fixture = preload("res://tests/automated/AugmentMatchFixture.gd")
const Catalog = preload("res://source/match/augments/AugmentCatalog.gd")

var match_root: Node
var runtime: Node
var peer_id := 0
var client_ready := false
var client_verified := false
var failures: Array = []
var rows: Array = []
var stage := 0
var is_host := false
var base_max := 0.0
var damage_baseline := 0.0


func _ready() -> void:
	await get_tree().process_frame
	is_host = OS.get_environment("AIRTS_AUGMENT_ROLE") == "server"
	var peer := ENetMultiplayerPeer.new()
	if is_host:
		peer.set_bind_ip("127.0.0.1")
	var port := int(OS.get_environment("AIRTS_AUGMENT_PORT"))
	var result := peer.create_server(port, 2) if is_host else peer.create_client("127.0.0.1", port)
	_check(result == OK, "ENet create")
	if result != OK:
		_finish()
		return
	NetSession._peer = peer
	multiplayer.multiplayer_peer = peer
	NetSession.local_slot = 0 if is_host else 1
	NetSession._slots[1] = 0
	if is_host:
		multiplayer.peer_connected.connect(func(id):
			peer_id = id
			NetSession._slots[id] = 1)
	else:
		var started := Time.get_ticks_msec()
		while peer.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED:
			if Time.get_ticks_msec() - started > 10000:
				_check(false, "ENet connect timeout")
				_finish()
				return
			await get_tree().process_frame
	match_root = await Fixture.create(get_tree(), 0 if is_host else 1)
	runtime = match_root.get_node("AugmentRuntime")
	# Real card definitions, deterministic draft, no catalog changes on disk.
	Catalog._cache = Catalog.data().duplicate(true)
	Catalog._cache["rounds"] = []
	var player = match_root.get_node("Players/Player1")
	base_max = float(player.get_node("Base").hp_max)
	if is_host:
		await _host_run(player)
	else:
		_ready_client.rpc_id(1)
		await _client_run(player)


func _host_run(player: Node) -> void:
	if not await _wait(func(): return client_ready, 10):
		_finish()
		return
	var tank = Fixture.spawn(match_root, player, "res://source/match/units/Tank.tscn", Vector3(30, 0, 30))
	var infantry = Fixture.spawn(match_root, player, "res://source/match/units/Infantry.tscn", Vector3(15, 0, 35))
	var target = Fixture.spawn(match_root, match_root.get_node("Players/Player0"),
		"res://source/match/units/Infantry.tscn", Vector3(23, 0, 35))
	damage_baseline = await _hit(infantry, target)
	for index in 5:
		var card_id: String = ["aug_citadel", "aug_warpath", "aug_gather_plus", "aug_cash_drop", "aug_longwatch"][index]
		# Reset player draft state only to exercise all five mutually exclusive effect families.
		runtime._player_states.clear()
		Catalog._cache["cards"] = [Catalog.card(card_id)] if Catalog.card(card_id) != {} else [
			JSON.parse_string(FileAccess.get_file_as_string(Catalog.CONFIG_PATH))["cards"].filter(
				func(card): return card.id == card_id)[0]]
		client_verified = false
		_check(runtime.debug_force_round(index, player).get("ok", false), "host opens " + card_id)
		if not await _wait(func(): return runtime.snapshot_for(player)["owned"].size() == 1, 8):
			break
		var card: Dictionary = runtime.snapshot_for(player)["owned"][0]
		_check(card.id == card_id, "server accepts client selected card")
		var row := {"id": card_id, "host_owned": runtime.snapshot_for(player)["owned"].size()}
		if card_id == "aug_citadel":
			row["hp_max"] = player.get_node("Base").hp_max
			_check(is_equal_approx(float(row.hp_max), base_max * 1.35), "authoritative max HP +35%")
		elif card_id == "aug_warpath":
			row["before_damage"] = damage_baseline
			row["after_damage"] = await _hit(infantry, target)
			_check(is_equal_approx(float(row.after_damage), damage_baseline * 1.25), "authoritative damage +25%")
		elif card_id == "aug_gather_plus":
			_check(is_equal_approx(float(runtime.gather_multiplier(player)), 1.25), "server gather multiplier")
		elif card_id == "aug_cash_drop":
			row["balance"] = player.resource_a
			_check(int(player.resource_a) == 5000, "server grants cash exactly once")
		if not await _wait(func(): return client_verified, 8):
			break
		await get_tree().create_timer(0.15).timeout
		_check(runtime.snapshot_for(player)["owned"].size() == 1, "duplicate RPC not stacked")
		rows.append(row)
		if index < 4:
			_next_stage.rpc_id(peer_id, index + 1)
			await get_tree().create_timer(0.1).timeout
	# Keep the expired offer open so auto-pick cannot hide a wrongly accepted RPC.
	runtime.set_process(false)
	runtime._player_states.clear()
	Catalog._cache = JSON.parse_string(FileAccess.get_file_as_string(Catalog.CONFIG_PATH))
	Catalog._cache["rounds"] = []
	client_verified = false
	_check(runtime.debug_force_round(5, player).get("ok", false), "host opens deadline probe")
	var state: Dictionary = runtime._state_of(player)
	var before_rank: Dictionary = state["rank"].duplicate(true)
	state["deadline_msec"] = Time.get_ticks_msec() - 1
	_next_stage.rpc_id(peer_id, 5)
	await _wait(func(): return client_verified, 8)
	await get_tree().create_timer(0.15).timeout
	_check((state["owned"] as Array).is_empty(), "expired pick cannot consume open offer")
	_check(not (state["offer"] as Array).is_empty(), "expired offer remains for authoritative timeout")
	_check(state["rank"] == before_rank, "expired recommendation cannot alter timeout ranking")
	rows.append({"id": "expired_requests", "owned_count": state["owned"].size(),
		"rank_unchanged": state["rank"] == before_rank})
	_done.rpc_id(peer_id)
	var shutdown_start := Time.get_ticks_msec()
	while peer_id in multiplayer.get_peers() and Time.get_ticks_msec() - shutdown_start < 3000:
		await get_tree().process_frame
	_finish()


func _client_run(player: Node) -> void:
	for index in 5:
		if not await _wait(func():
			var snap: Dictionary = runtime.snapshot_for(player)
			return snap.round_index == index and not snap.offer.is_empty(), 8):
			_finish()
			return
		var snap: Dictionary = runtime.snapshot_for(player)
		var card_id := str(snap.offer[0].id)
		_check(runtime.snapshot_for(match_root.get_node("Players/Player0"))["offer"].is_empty(), "private offers")
		_check(not runtime.pick(match_root.get_node("Players/Player0"), card_id, "spoof").get("ok", false), "client cannot pick for host")
		_check(not runtime.pick(player, "aug_invented", "invalid").get("ok", false), "out-of-offer rejected")
		if runtime.has_method("_rpc_request_pick"):
			runtime._rpc_request_pick.rpc_id(1, card_id, index - 1)
			runtime._rpc_request_pick.rpc_id(1, "aug_invented", index)
			await get_tree().create_timer(0.1).timeout
			_check(runtime.snapshot_for(player)["owned"].is_empty(), "stale or forged request cannot consume open offer")
		var overlay = match_root.find_child("AugmentDraftOverlay", true, false)
		_check(overlay != null and overlay.visible, "client sees actual draft overlay")
		overlay.pick_requested.emit(card_id)
		if not await _wait(func(): return runtime.snapshot_for(player)["owned"].size() == 1, 8):
			_finish()
			return
		if card_id == "aug_citadel":
			await _wait(func(): return is_equal_approx(float(player.get_node("Base").hp_max), base_max * 1.35), 5)
			rows.append({"id": card_id, "client_hp_max": player.get_node("Base").hp_max})
			# Simulate a client whose local augment state is missing after startup.
			runtime._player_states.clear()
			runtime._client_state_requested = false
			await _wait(func(): return runtime.snapshot_for(player)["owned"].size() == 1, 4)
			_check(is_equal_approx(float(player.get_node("Base").hp_max), base_max * 1.35), "catch-up max HP not squared")
		elif card_id == "aug_cash_drop":
			await _wait(func(): return int(player.resource_a) == 5000, 5)
		# Direct reliable retransmission/stale round/invalid IDs exercise server-side rejection.
		if runtime.has_method("_rpc_request_pick"):
			runtime._rpc_request_pick.rpc_id(1, card_id, index)
			runtime._rpc_request_pick.rpc_id(1, "aug_invented", index)
			runtime._rpc_request_pick.rpc_id(1, card_id, index - 1)
		_verified.rpc_id(1)
		await _wait(func(): return stage >= index + 1, 8)
	if await _wait(func(): return runtime.snapshot_for(player)["round_index"] == 5, 8):
		var expired: Dictionary = runtime.snapshot_for(player)
		var order: Array = (expired["rank"]["order"] as Array).duplicate()
		order.reverse()
		runtime._rpc_request_recommendation.rpc_id(1, {"order": order, "reasons": []}, 5)
		runtime._rpc_request_pick.rpc_id(1, str(expired["offer"][0]["id"]), 5)
		_verified.rpc_id(1)
		await _wait(func(): return stage >= 6, 8)
	_finish()


func _hit(source: Node, target: Node) -> float:
	target.set_hp_without_damage(float(target.hp_max))
	var before := float(target.hp)
	match_root.get_node("ProjectileRuntime").LaunchEntity(source, target, false)
	var started := Time.get_ticks_msec()
	while float(target.hp) >= before and Time.get_ticks_msec() - started < 2000:
		await get_tree().physics_frame
	return before - float(target.hp)


@rpc("any_peer", "reliable")
func _ready_client() -> void:
	client_ready = true


@rpc("any_peer", "reliable")
func _verified() -> void:
	client_verified = true


@rpc("authority", "reliable")
func _next_stage(value: int) -> void:
	stage = value


@rpc("authority", "reliable")
func _done() -> void:
	stage = 6


func _wait(predicate: Callable, seconds: float) -> bool:
	var start := Time.get_ticks_msec()
	while Time.get_ticks_msec() - start < int(seconds * 1000):
		if predicate.call():
			return true
		await get_tree().create_timer(0.05).timeout
	_check(false, "network condition timed out at stage %d" % stage)
	return false


func _check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
		push_error("AUGMENT-NET: " + message)


func _finish() -> void:
	var output := OS.get_environment("AIRTS_AUGMENT_OUTPUT")
	if not output.is_empty():
		var file := FileAccess.open(output, FileAccess.WRITE)
		file.store_string(JSON.stringify({"role": "host" if is_host else "client", "rows": rows,
			"failures": failures, "pid": OS.get_process_id()}, "\t"))
	print("Match augment network test completed: %d failure(s)" % failures.size())
	NetSession.disconnect_session()
	SmokeTestExit.request(get_tree(), 0 if failures.is_empty() else 1, match_root)
