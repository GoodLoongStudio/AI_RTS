extends Node

## 局内海克斯加成权威节点。抽牌、倒计时、落选、写观测与战报。
## Hermes 只能经 `submit_recommendation` 标星，不能在这里下单位命令。

const Human = preload("res://source/match/players/human/Human.gd")
const Catalog = preload("res://source/match/augments/AugmentCatalog.gd")
const Ranker = preload("res://source/match/augments/AugmentRanker.gd")
const Mods = preload("res://source/match/augments/AugmentModifiers.gd")
const OverlayScript = preload("res://source/match/hud/augments/AugmentDraftOverlay.gd")
const TrayScript = preload("res://source/match/hud/augments/AugmentTray.gd")

var _player_states: Dictionary = {}
var _opened_rounds: Dictionary = {}
var _overlay: CanvasLayer = null
var _tray: Control = null
var _countdown_override_msec := -1


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	if not _enabled():
		set_process(false)
		return
	var match_root := _match()
	if match_root != null and not match_root.is_node_ready():
		await match_root.ready
	_ensure_pause_gate()
	if MatchSignals.has_signal("unit_spawned") and not MatchSignals.unit_spawned.is_connected(_on_unit_spawned):
		MatchSignals.unit_spawned.connect(_on_unit_spawned)
	call_deferred("_mount_hud")
	set_process(true)


func _process(_delta: float) -> void:
	if not _enabled() or not _is_authority():
		_tick_overlay_only()
		return
	_maybe_open_scheduled_rounds()
	_tick_timeouts()
	_tick_overlay_only()


func snapshot_for(player: Node) -> Dictionary:
	var state := _state_of(player)
	var offer = state.get("offer", [])
	var rank = state.get("rank", {})
	return {
		"enabled": _enabled(),
		"owned": (state.get("owned", []) as Array).duplicate(true),
		"picks": (state.get("picks", []) as Array).duplicate(true),
		"offer": offer.duplicate(true) if offer is Array else [],
		"round_index": int(state.get("round_index", -1)),
		"deadline_msec": int(state.get("deadline_msec", 0)),
		"rank": rank.duplicate(true) if rank is Dictionary else {},
		"paused_for_draft": _pause_gate() != null and _pause_gate().is_held("augment"),
		"networked": NetSession.is_networked(),
	}


func gather_multiplier(player: Node) -> float:
	return float(_state_of(player).get("gather_mult", 1.0))


func pick(player: Node, augment_id: String, source: String) -> Dictionary:
	if player == null:
		return {"ok": false, "reason": "no player"}
	var state := _state_of(player)
	var offer: Array = state.get("offer", [])
	if offer.is_empty():
		return {"ok": false, "reason": "no offer"}
	var chosen: Dictionary = {}
	for item in offer:
		if item is Dictionary and str(item.get("id", "")) == augment_id:
			chosen = item
			break
	if chosen.is_empty():
		return {"ok": false, "reason": "id not in offer"}
	_apply_choice(player, state, chosen, source)
	return {"ok": true, "id": augment_id, "source": source}


func submit_recommendation(player: Node, payload: Dictionary) -> Dictionary:
	if player == null:
		return {"ok": false, "reason": "no player"}
	var state := _state_of(player)
	var offer: Array = state.get("offer", [])
	if offer.is_empty():
		return {"ok": false, "reason": "no offer"}
	var offer_ids: Array = []
	for item in offer:
		if item is Dictionary:
			offer_ids.append(str(item.get("id", "")))
	var order = payload.get("order", [])
	if not order is Array or order.size() != offer_ids.size():
		return {"ok": false, "reason": "order must be a permutation of the offer"}
	var seen := {}
	for card_id in order:
		var key := str(card_id)
		if key not in offer_ids or seen.has(key):
			return {"ok": false, "reason": "order must be a permutation of the offer"}
		seen[key] = true
	var reasons = payload.get("reasons", [])
	state["rank"] = {
		"order": order.duplicate(),
		"reasons": reasons.duplicate(true) if reasons is Array else [],
		"source": "live",
		"starred_id": str(order[0]) if not order.is_empty() else "",
	}
	_refresh_overlay_if_local(player)
	return {"ok": true, "source": "live"}


func debug_force_round(round_index: int, player: Node = null) -> Dictionary:
	var target := player if player != null else _local_player()
	if target == null:
		return {"ok": false, "reason": "no player"}
	return _open_round_for(target, round_index)


func debug_set_countdown_msec(msec: int) -> void:
	_countdown_override_msec = msec


func _enabled() -> bool:
	var flags := get_node_or_null("/root/FeatureFlags")
	if flags == null:
		return true
	return bool(flags.get("match_augments"))


func _is_authority() -> bool:
	return not NetSession.is_networked() or NetSession.is_server()


func _match() -> Node:
	return get_parent()


func _pause_gate() -> Node:
	return _match().get_node_or_null("PauseGate") if _match() != null else null


func _ensure_pause_gate() -> void:
	if _match() == null or _pause_gate() != null:
		return
	var gate := preload("res://source/match/augments/MatchPauseGate.gd").new()
	gate.name = "PauseGate"
	_match().add_child(gate)


func _local_player() -> Node:
	var match_root := _match()
	if match_root != null and match_root.has_method("get_local_player"):
		var local = match_root.get_local_player()
		if local != null:
			return local
	for player in get_tree().get_nodes_in_group("players"):
		if _is_human(player):
			return player
	return null


func _player_id(player: Node) -> String:
	return str(player.get_instance_id()) if player != null else ""


func _state_of(player: Node) -> Dictionary:
	var key := _player_id(player)
	if not _player_states.has(key):
		_player_states[key] = {
			"owned": [],
			"owned_ids": [],
			"owned_tags": [],
			"owned_effects": [],
			"picks": [],
			"gather_mult": 1.0,
			"offer": [],
			"round_index": -1,
			"deadline_msec": 0,
			"rank": {},
		}
	return _player_states[key]


func _maybe_open_scheduled_rounds() -> void:
	var match_root := _match()
	if match_root == null or not match_root.has_method("get_simulation_msec"):
		return
	var now := int(match_root.get_simulation_msec())
	for round_index in Catalog.round_count():
		if _opened_rounds.get(round_index, false):
			continue
		var at_msec := Catalog.round_at_msec(round_index)
		if at_msec < 0 or now < at_msec:
			continue
		_opened_rounds[round_index] = true
		for player in _combatants():
			_open_round_for(player, round_index)


func _open_round_for(player: Node, round_index: int) -> Dictionary:
	var state := _state_of(player)
	if not (state.get("offer", []) as Array).is_empty():
		return {"ok": false, "reason": "offer already open"}
	var match_id := _match_id()
	var seed_text := "%s|%s|%d" % [match_id, str(player.name), round_index]
	var offer := Catalog.roll(
		seed_text,
		state.get("owned_ids", []),
		state.get("owned_tags", []),
		state.get("owned_effects", [])
	)
	if offer.is_empty():
		return {"ok": false, "reason": "empty pool"}
	_opened_rounds[round_index] = true
	var countdown := _countdown_override_msec if _countdown_override_msec > 0 else Catalog.countdown_msec()
	state["offer"] = offer
	state["round_index"] = round_index
	state["deadline_msec"] = Time.get_ticks_msec() + countdown
	var facts := _facts_for(player)
	var profile := _profile_snapshot()
	state["rank"] = Ranker.rank(offer, facts, profile)
	if _is_local_human(player):
		if _pause_gate() != null and _pause_gate().can_freeze_world():
			_pause_gate().acquire("augment")
		_show_overlay(player)
	elif not _is_human(player):
		var top := str((state.get("rank", {}) as Dictionary).get("starred_id", ""))
		if top.is_empty() and not offer.is_empty():
			top = str(offer[0].get("id", ""))
		pick(player, top, "ai_rules")
	var offer_ids: Array = []
	for item in offer:
		if item is Dictionary:
			offer_ids.append(str(item.get("id", "")))
	_record_event(player, "augment_offered", round_index, ",".join(offer_ids), "offer")
	return {"ok": true, "offer": offer}


func _tick_timeouts() -> void:
	var now := Time.get_ticks_msec()
	for player in _combatants():
		var state := _state_of(player)
		var offer: Array = state.get("offer", [])
		if offer.is_empty():
			continue
		if now < int(state.get("deadline_msec", 0)):
			continue
		var rank: Dictionary = state.get("rank", {})
		var top := str(rank.get("starred_id", ""))
		if top.is_empty() and not offer.is_empty():
			top = str(offer[0].get("id", ""))
		var source := "timeout_hermes" if str(rank.get("source", "")) == "live" else "timeout_rules"
		pick(player, top, source)


func _tick_overlay_only() -> void:
	if _overlay != null and _overlay.has_method("tick"):
		_overlay.tick()


func _apply_choice(player: Node, state: Dictionary, chosen: Dictionary, source: String) -> void:
	var card_id := str(chosen.get("id", ""))
	(state.get("owned", []) as Array).append(chosen.duplicate(true))
	(state.get("owned_ids", []) as Array).append(card_id)
	var tag := str(chosen.get("tag", ""))
	if tag != "" and not (state.get("owned_tags", []) as Array).has(tag):
		(state.get("owned_tags", []) as Array).append(tag)
	var effect = chosen.get("effect", {})
	var effect_type := str(effect.get("type", "")) if effect is Dictionary else ""
	if effect_type != "" and not (state.get("owned_effects", []) as Array).has(effect_type):
		(state.get("owned_effects", []) as Array).append(effect_type)
	if effect is Dictionary and effect_type == "gather_mult":
		state["gather_mult"] = float(effect.get("value", 1.0))
	if effect is Dictionary and effect_type == "resource_grant":
		var amount := int(effect.get("resource_a", 0))
		if amount > 0 and player.has_method("add_resources") and player.get("_economy_runtime") != null:
			# ⚠️ reason 必须是 C# `ResourceChangeReason` 的**枚举成员名**。传枚举里没有的字符串
			# 时，`EconomyRuntime.ApplyLegacy` 在 Enum.TryParse 失败后**不打印任何日志**就返回
			# InvalidTransaction —— 加钱卡会静默变成空操作（2026-09-15 实测：把 400 改成 5000
			# 也没用，钱根本没进账，而日志里连一行痕迹都没有）。这里用枚举里为「脚本/兼容代码的
			# 明确调整」保留的 ScriptedAdjustment；若要给加成单开 AugmentGrant 原因，必须在
			# C# 侧加枚举成员并重新构建（本机 dotnet build 目前因 NuGet 解析故障跑不起来）。
			player.add_resources({"resource_a": amount}, "ScriptedAdjustment", player)
	_reapply_units(player)
	var round_index := int(state.get("round_index", -1))
	(state.get("picks", []) as Array).append({
		"round": round_index,
		"id": card_id,
		"tag": tag,
		"source": source,
	})
	state["offer"] = []
	state["round_index"] = -1
	state["deadline_msec"] = 0
	state["rank"] = {}
	if _is_local_human(player):
		if _pause_gate() != null:
			_pause_gate().release("augment")
		if _overlay != null:
			_overlay.hide_draft()
		_refresh_tray(player)
	_record_event(player, "augment_picked", round_index, card_id, source)
	_contribute_report(player)


func _reapply_units(player: Node) -> void:
	var owned: Array = _state_of(player).get("owned", [])
	for unit in get_tree().get_nodes_in_group("units"):
		if _unit_owner(unit) == player:
			Mods.apply_to_unit(unit, owned)


func _on_unit_spawned(unit: Node) -> void:
	if unit == null:
		return
	var player = _unit_owner(unit)
	if player == null or not _player_states.has(_player_id(player)):
		return
	Mods.apply_to_unit(unit, _state_of(player).get("owned", []))


func _combatants() -> Array:
	var out: Array = []
	for player in get_tree().get_nodes_in_group("players"):
		if player.has_meta("slot_kind"):
			continue
		out.append(player)
	return out


func _is_human(player: Node) -> bool:
	if player == null:
		return false
	var script = player.get_script()
	if script != null and "players/human/" in str(script.resource_path):
		return true
	return player is Human


func _is_local_human(player: Node) -> bool:
	if not _is_human(player):
		return false
	var local := _local_player()
	return local == null or player == local


func _unit_owner(unit: Node) -> Node:
	if unit != null and unit.get("player") != null:
		return unit.player
	return unit.get_parent() if unit != null else null


func _facts_for(player: Node) -> Dictionary:
	var army := 0
	var structures := 0
	for unit in get_tree().get_nodes_in_group("units"):
		if _unit_owner(unit) != player:
			continue
		if Mods.is_structure_unit(unit):
			structures += 1
		elif unit.get("attack_damage") != null:
			army += 1
	var enemies := 0
	for unit in get_tree().get_nodes_in_group("units"):
		if _unit_owner(unit) != player and unit.get("attack_damage") != null:
			enemies += 1
	return {
		"army_count": army,
		"structure_count": structures,
		"enemy_count": enemies,
		"balance_a": int(player.get("resource_a")) if player != null else 0,
	}


func _profile_snapshot() -> Dictionary:
	var store := get_node_or_null("/root/GrowthStore")
	if store != null and store.has_method("get_profile_snapshot"):
		var snap = store.get_profile_snapshot()
		if snap is Dictionary:
			return snap
	if store != null and "state" in store:
		return {"levels": store.state.get("levels", {})}
	return {}


func _match_id() -> String:
	var dcs := get_node_or_null("/root/DebugControlServer")
	if dcs != null and dcs.has_method("_adjutant_match_id"):
		var mid = dcs.call("_adjutant_match_id", _match())
		if str(mid) != "":
			return str(mid)
	return "local-match"


func _mount_hud() -> void:
	var hud := _match().get_node_or_null("HUD") if _match() != null else null
	if hud == null:
		return
	if _overlay == null:
		var packed := load("res://source/match/hud/augments/AugmentDraftOverlay.tscn")
		if packed is PackedScene:
			_overlay = packed.instantiate()
		else:
			_overlay = OverlayScript.new()
		_overlay.name = "AugmentDraftOverlay"
		hud.add_child(_overlay)
		_overlay.pick_requested.connect(_on_overlay_pick)
	if _tray == null:
		_tray = TrayScript.new()
		_tray.name = "AugmentTray"
		hud.add_child(_tray)


func _show_overlay(player: Node) -> void:
	_mount_hud()
	if _overlay != null:
		_overlay.show_draft(snapshot_for(player), NetSession.is_networked())


func _refresh_overlay_if_local(player: Node) -> void:
	if not _is_local_human(player) or _overlay == null:
		return
	_overlay.show_draft(snapshot_for(player), NetSession.is_networked())


func _refresh_tray(player: Node) -> void:
	if _tray != null and _is_local_human(player):
		_tray.set_owned(_state_of(player).get("owned", []))


func _on_overlay_pick(augment_id: String) -> void:
	var player := _local_player()
	if player == null:
		return
	pick(player, augment_id, "player")


func _record_event(player: Node, kind: String, round_index: int, augment_id: String, source: String) -> void:
	if player != _local_player():
		return
	var recorder := _recorder()
	if recorder == null or not recorder.has_method("_add_event"):
		return
	var title := "加成三选一" if kind == "augment_offered" else "加成已选定"
	var detail := "第 %d 轮 %s %s" % [round_index + 1, augment_id, source]
	recorder.call("_add_event", kind, title, detail, augment_id, source == "timeout_hermes")


func _contribute_report(player: Node) -> void:
	if player != _local_player():
		return
	var recorder := _recorder()
	if recorder == null or not recorder.has_method("contribute"):
		return
	var state := _state_of(player)
	var owned: Array = []
	for card in state.get("owned", []):
		if card is Dictionary:
			owned.append({
				"id": str(card.get("id", "")),
				"tag": str(card.get("tag", "")),
				"name": str(card.get("name", "")),
			})
	recorder.contribute("augments", "owned", owned)
	recorder.contribute("augments", "picks", (state.get("picks", []) as Array).duplicate(true))


func _recorder() -> Node:
	var match_root := _match()
	if match_root == null:
		return null
	return match_root.get_node_or_null("MatchReportRecorder")
