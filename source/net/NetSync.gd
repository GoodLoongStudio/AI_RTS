extends Node

## 挂在 Match 下：客户端把命令转发到服务器，服务器按 10Hz 广播单位快照。

const SNAPSHOT_INTERVAL_FRAMES := 6
# GDScript 的 `is` 右侧不能用局部变量（parse error），用脚本资源等价比较代替。
const HumanScript := preload("res://source/match/players/human/Human.gd")

var _match: Node = null
var _frame := 0
var _live := false
var _local_match_started := false

# 复核 P0-1：初始实体清单——NodePath 一致性的启动期硬校验，错了拒绝 go-live。
var _own_manifest: PackedStringArray = PackedStringArray()
var _client_manifests: Dictionary = {}  # peer_id -> PackedStringArray
var _go_live_blocked := false

# 复核 P1-1：客户端两快照线性插值（渲染落后一个快照周期，消除 10Hz 瞬移感）。
var _interp_prev: Dictionary = {}  # Match 相对路径 -> Vector3
var _interp_target: Dictionary = {}  # Match 相对路径 -> Vector3
var _last_snap_msec := 0
var _snap_interval_msec := 100


func _ready() -> void:
	_match = get_parent()
	set_physics_process(NetSession.is_networked())
	if not NetSession.is_networked():
		return
	MatchSignals.match_started.connect(_on_any_match_started)
	if NetSession.is_server():
		MatchSignals.unit_spawned.connect(_on_unit_spawned)
		NetSession.player_dropped.connect(_on_player_dropped)


func _on_any_match_started() -> void:
	NetSession.notify_match_ready()
	# match_started 在初始单位装配完成后发射（Match.gd:88），此时清单已稳定。
	_own_manifest = _collect_unit_paths()
	if not NetSession.is_server():
		_rpc_submit_manifest.rpc_id(1, _own_manifest)
	if NetSession.is_server():
		_local_match_started = true
		_try_go_live()


func _try_go_live() -> void:
	if not NetSession.is_server() or not _local_match_started:
		return
	if _go_live_blocked:
		return
	if not NetSession.all_human_matches_ready():
		return
	# 每个客户端（不含服务器自己）都必须提交清单且与服务器一致，否则拒绝开局。
	for peer_id in NetSession.human_peer_ids():
		if peer_id == multiplayer.get_unique_id():
			continue
		if not _client_manifests.has(peer_id):
			return
		var diff := _manifest_diff(_own_manifest, _client_manifests[peer_id])
		if not diff.is_empty():
			_go_live_blocked = true
			var reason := "初始单位清单与服务器不一致（%s）——请确认所有玩家使用同一份工程版本" % diff
			push_error("联机: " + reason)
			NetSession._rpc_abort.rpc(reason)
			return
	if _live:
		return
	_live = true
	# 复核 P1-5：go-live 对账——补齐窗口期漏掉的 spawn、清掉多余单位。
	_rpc_reconcile.rpc(_collect_reconcile_entries())
	for unit in get_tree().get_nodes_in_group("units"):
		_watch_unit(unit)


func _collect_unit_paths() -> PackedStringArray:
	var paths: PackedStringArray = PackedStringArray()
	for unit in get_tree().get_nodes_in_group("units"):
		if unit == null or not is_instance_valid(unit):
			continue
		paths.append(str(_match.get_path_to(unit)))
	paths.sort()
	return paths


func _manifest_diff(a: PackedStringArray, b: PackedStringArray) -> String:
	if a.size() != b.size():
		return "单位数 %d vs %d" % [a.size(), b.size()]
	for i in range(a.size()):
		if a[i] != b[i]:
			return "第 %d 个路径不同: %s vs %s" % [i, a[i], b[i]]
	return ""


func _collect_reconcile_entries() -> Array:
	var entries: Array = []
	for unit in get_tree().get_nodes_in_group("units"):
		if unit == null or not is_instance_valid(unit):
			continue
		var scene_path := String(unit.scene_file_path)
		if scene_path.is_empty():
			continue
		entries.append(
			{
				"path": str(_match.get_path_to(unit)),
				"parent": str(_match.get_path_to(unit.get_parent())),
				"scene": scene_path,
				"xf": unit.global_transform,
				"hp": unit.hp if "hp" in unit else 0.0,
			}
		)
	return entries


## 复核 P1-2：玩家掉线 → 服务器清掉其全部单位（歼灭规则随之自然结算，掉线算负）。
func _on_player_dropped(slot: int) -> void:
	if not NetSession.is_server():
		return
	var players := get_tree().get_nodes_in_group("players")
	if slot < 0 or slot >= players.size():
		return
	var dropped = players[slot]
	for unit in get_tree().get_nodes_in_group("units"):
		if is_instance_valid(unit) and unit.get_parent() == dropped:
			unit.queue_free()


func _watch_unit(unit: Node) -> void:
	if unit == null or not is_instance_valid(unit):
		return
	if unit.tree_exited.is_connected(_on_unit_tree_exited):
		return
	var path := str(_match.get_path_to(unit))
	unit.tree_exited.connect(_on_unit_tree_exited.bind(path))


func _on_unit_spawned(unit: Node) -> void:
	if not NetSession.is_server() or not _live:
		return
	_watch_unit(unit)
	var scene_path := String(unit.scene_file_path)
	if scene_path.is_empty():
		return
	_rpc_spawn.rpc(
		scene_path,
		str(_match.get_path_to(unit.get_parent())),
		unit.global_transform,
		unit.hp if "hp" in unit else 0.0
	)


func _on_unit_tree_exited(path: String) -> void:
	if not NetSession.is_server() or not _live:
		return
	_rpc_despawn.rpc(path)


func _physics_process(_delta: float) -> void:
	if not NetSession.is_networked():
		return
	if NetSession.is_server():
		_server_tick()
	else:
		_client_interp_tick()


func _server_tick() -> void:
	if not _live:
		_try_go_live()
	if not _live:
		return
	_frame += 1
	if _frame % SNAPSHOT_INTERVAL_FRAMES != 0:
		return
	_broadcast_snapshot()


func _client_interp_tick() -> void:
	if _interp_target.is_empty() or _last_snap_msec <= 0:
		return
	var t := clampf(
		float(Time.get_ticks_msec() - _last_snap_msec) / float(_snap_interval_msec),
		0.0,
		1.0
	)
	for path in _interp_target.keys():
		var unit := _match.get_node_or_null(NodePath(path))
		if unit == null or not is_instance_valid(unit):
			continue
		var prev: Vector3 = _interp_prev.get(path, _interp_target[path])
		var target: Vector3 = _interp_target[path]
		unit.global_position = prev.lerp(target, t)


func forward_command(
	op: String,
	unit_nodes: Array,
	destination: Vector3,
	target: Node,
	_issuer: Node,
	extra: String = ""
) -> Dictionary:
	var paths: PackedStringArray = PackedStringArray()
	for unit in unit_nodes:
		if unit != null and is_instance_valid(unit):
			paths.append(str(_match.get_path_to(unit)))
	var target_path := ""
	if target != null and is_instance_valid(target):
		target_path = str(_match.get_path_to(target))
	_rpc_command.rpc_id(1, op, paths, destination, target_path, extra)
	return {"status": "Accepted", "unit_results": []}


func apply_client_snapshot(
	units_payload: Array, resources_payload: Array, server_frame: int
) -> void:
	if NetSession.is_server():
		return
	# 复核 P1-1：快照只更新插值目标，位置由 _client_interp_tick 每物理帧过渡。
	var now := Time.get_ticks_msec()
	if _last_snap_msec > 0:
		_snap_interval_msec = clampi(now - _last_snap_msec, 50, 300)
	_last_snap_msec = now
	var seen: Dictionary = {}
	for item in units_payload:
		var path: String = item["path"]
		seen[path] = true
		var unit := _match.get_node_or_null(NodePath(path))
		if unit == null or not is_instance_valid(unit):
			continue
		_interp_prev[path] = _interp_target.get(path, item["pos"])
		_interp_target[path] = item["pos"]
		if item.has("yaw"):
			unit.rotation.y = item["yaw"]
		if item.has("hp") and "hp" in unit:
			unit.hp = item["hp"]
	for path in _interp_target.keys():
		if not seen.has(path):
			_interp_prev.erase(path)
			_interp_target.erase(path)
	var players := get_tree().get_nodes_in_group("players")
	for item in resources_payload:
		var slot := int(item["slot"])
		if slot < 0 or slot >= players.size():
			continue
		var player = players[slot]
		if player != null and player.has_method("apply_authoritative_resource_snapshot"):
			player.apply_authoritative_resource_snapshot(
				int(item["a"]), int(item["b"]), server_frame
			)


func _broadcast_snapshot() -> void:
	var units_payload: Array = []
	for unit in get_tree().get_nodes_in_group("units"):
		if unit == null or not is_instance_valid(unit):
			continue
		units_payload.append(
			{
				"path": str(_match.get_path_to(unit)),
				"pos": unit.global_position,
				"yaw": unit.rotation.y,
				"hp": unit.hp if "hp" in unit else 0,
			}
		)
	var resources_payload: Array = []
	var players := get_tree().get_nodes_in_group("players")
	for i in range(players.size()):
		var player = players[i]
		resources_payload.append(
			{"slot": i, "a": int(player.resource_a), "b": int(player.resource_b)}
		)
	# 复核 P2：快照携带服务器帧号，客户端用它做资源版本去重（原来传客户端本地 _frame 恒为 0）。
	_rpc_snapshot.rpc(units_payload, resources_payload, _frame)


@rpc("any_peer", "reliable")
func _rpc_command(
	op: String,
	paths: PackedStringArray,
	destination: Vector3,
	target_path: String,
	extra: String = ""
) -> void:
	if not NetSession.is_server():
		return
	var slot := NetSession.slot_of(multiplayer.get_remote_sender_id())
	var players := get_tree().get_nodes_in_group("players")
	if slot < 0 or slot >= players.size():
		return
	var issuer = players[slot]
	if issuer == null or issuer.get_script() != HumanScript:
		return
	var units: Array = []
	for path in paths:
		var unit = _match.get_node_or_null(NodePath(path))
		if unit != null and is_instance_valid(unit) and unit.get_parent() == issuer:
			units.append(unit)
	if op == "produce":
		if units.is_empty() or extra.is_empty():
			return
		var queue = units[0].find_child("ProductionQueue")
		if queue != null:
			queue.produce(load(extra))
		return
	if units.is_empty():
		return
	var gateway = issuer.find_child("UnitCommandGateway")
	if gateway == null:
		return
	var target = _match.get_node_or_null(NodePath(target_path)) if target_path != "" else null
	match op:
		"move":
			gateway.MoveUnits(units, destination, issuer)
		"force_move":
			gateway.ForceMoveUnits(units, destination, issuer)
		"halt":
			gateway.HaltMovement(units, issuer)
		"stop":
			gateway.StopUnits(units, issuer)
		"withdraw":
			gateway.TacticalWithdrawUnits(units, destination, issuer)
		"ground_attack_move":
			gateway.GroundAttackMoveUnits(units, destination, issuer)
		"attack":
			if target != null:
				gateway.AttackUnits(units, target, issuer)
		"force_attack":
			if target != null:
				gateway.ForceAttackUnits(units, target, issuer)
		"force_attack_ground":
			gateway.ForceAttackGround(units, destination, issuer)
		"entity_attack_move":
			if target != null:
				gateway.EntityAttackMoveUnits(units, target, issuer)
		"follow":
			if target != null:
				gateway.FollowEntityUnits(units, target, issuer)
		"approach":
			if target != null:
				gateway.ApproachEntityUnits(units, target, issuer)
		"gather":
			if target != null:
				gateway.GatherResources(units, target, issuer)
		"construct":
			if target != null:
				gateway.ConstructUnits(units, target, issuer)
		"cancel_construct":
			if target != null:
				gateway.CancelConstruction(target, issuer)


@rpc("authority", "unreliable")
func _rpc_snapshot(units_payload: Array, resources_payload: Array, server_frame: int) -> void:
	apply_client_snapshot(units_payload, resources_payload, server_frame)


@rpc("any_peer", "reliable")
func _rpc_submit_manifest(paths: PackedStringArray) -> void:
	if not NetSession.is_server():
		return
	var peer_id := multiplayer.get_remote_sender_id()
	if NetSession.slot_of(peer_id) < 0:
		return
	_client_manifests[peer_id] = paths


@rpc("authority", "reliable")
func _rpc_reconcile(entries: Array) -> void:
	if NetSession.is_server():
		return
	_interp_prev.clear()
	_interp_target.clear()
	var wanted: Dictionary = {}
	for entry in entries:
		var path: String = entry["path"]
		wanted[path] = true
		if _match.get_node_or_null(NodePath(path)) != null:
			continue
		_spawn_unit(entry["scene"], entry["parent"], entry["xf"], entry["hp"], path)
	for unit in get_tree().get_nodes_in_group("units"):
		if unit == null or not is_instance_valid(unit):
			continue
		if not wanted.has(str(_match.get_path_to(unit))):
			unit.queue_free()


@rpc("authority", "reliable")
func _rpc_spawn(scene_path: String, parent_path: String, xf: Transform3D, hp: float) -> void:
	if NetSession.is_server():
		return
	_spawn_unit(scene_path, parent_path, xf, hp)


func _spawn_unit(
	scene_path: String, parent_path: String, xf: Transform3D, hp: float, forced_path: String = ""
) -> void:
	var parent := _match.get_node_or_null(NodePath(parent_path))
	if parent == null or scene_path.is_empty():
		return
	var packed = load(scene_path)
	if packed == null:
		return
	var unit = packed.instantiate()
	parent.add_child(unit)
	if forced_path != "":
		var np := NodePath(forced_path)
		unit.name = String(np.get_name(np.get_name_count() - 1))
		if str(_match.get_path_to(unit)) != forced_path:
			push_warning(
				"联机: 对账生成路径不符 %s（实际 %s），已移除" % [forced_path, _match.get_path_to(unit)]
			)
			unit.queue_free()
			return
	unit.global_transform = xf
	if "hp" in unit:
		unit.hp = hp
	if _match.has_method("_setup_unit_groups"):
		_match._setup_unit_groups(unit, parent)
	MatchSignals.unit_spawned.emit(unit)


@rpc("authority", "reliable")
func _rpc_despawn(path: String) -> void:
	if NetSession.is_server():
		return
	var unit := _match.get_node_or_null(NodePath(path))
	if unit != null and is_instance_valid(unit):
		unit.queue_free()
