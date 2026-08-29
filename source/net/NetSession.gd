extends Node

## 2–4 人内测联机会话。服务器权威，客户端只发命令、收快照。

const DEFAULT_HOST := "101.43.121.102"
const DEFAULT_PORT := 24567
const MAX_PLAYERS := 4
const MAP_PATH := "res://source/match/maps/PlainAndSimple.tscn"
const NetCommandProxyScript := preload("res://source/net/NetCommandProxy.gd")

var dedicated_server := false
var local_slot := 0
var _peer: ENetMultiplayerPeer = null
var _slots: Dictionary = {}  # peer_id -> slot 0..3
var _ready_peers: Dictionary = {}  # peer_id -> bool
var _match_started := false
var _status := "idle"
var _match_ready_peers: Dictionary = {}

signal status_changed(text)
signal match_starting
signal player_dropped(slot: int)  # 复核 P1-2：对局中玩家掉线（服务器发出，slot 为其阵营槽位）


func is_networked() -> bool:
	return _peer != null


func is_server() -> bool:
	return is_networked() and multiplayer.is_server()


func is_dedicated_server() -> bool:
	return dedicated_server


func should_forward_commands() -> bool:
	return is_networked() and not multiplayer.is_server()


func is_client_puppet() -> bool:
	return should_forward_commands()


func slot_of(peer_id: int) -> int:
	if not _slots.has(peer_id):
		return -1
	return int(_slots[peer_id])


func disconnect_session() -> void:
	_reset_peer()
	_set_status("已断开")


func command_gateway_for(player: Node):
	if player == null:
		return null
	if should_forward_commands():
		var match_node := player.find_parent("Match")
		if match_node == null:
			return null
		var sync := match_node.get_node_or_null("NetSync")
		if sync == null:
			return null
		return NetCommandProxyScript.new(sync, player)
	return player.find_child("UnitCommandGateway")


func get_status() -> String:
	return _status


func try_start_from_cmdline() -> bool:
	var args := OS.get_cmdline_user_args()
	var engine_args := OS.get_cmdline_args()
	if not args.has("--server") and not engine_args.has("--server"):
		return false
	dedicated_server = true
	var port := DEFAULT_PORT
	for i in range(args.size()):
		if args[i] == "--port" and i + 1 < args.size():
			port = int(args[i + 1])
	var err := host(port)
	if err != OK:
		push_error("dedicated server listen failed: %s" % err)
		get_tree().quit(1)
		return true
	_set_status("专用服监听 UDP %d，等待 2–4 名玩家" % port)
	return true


func host(port: int = DEFAULT_PORT) -> Error:
	_reset_peer()
	_peer = ENetMultiplayerPeer.new()
	var max_clients := MAX_PLAYERS if dedicated_server else MAX_PLAYERS - 1
	var err := _peer.create_server(port, max_clients)
	if err != OK:
		_peer = null
		return err
	multiplayer.multiplayer_peer = _peer
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	if not dedicated_server:
		_slots[1] = 0
		_ready_peers[1] = false
		local_slot = 0
	_set_status("已开房，端口 %d" % port)
	return OK


func join(address: String, port: int = DEFAULT_PORT) -> Error:
	_reset_peer()
	_peer = ENetMultiplayerPeer.new()
	var err := _peer.create_client(address, port)
	if err != OK:
		_peer = null
		return err
	multiplayer.multiplayer_peer = _peer
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)
	_set_status("正在连接 %s:%d …" % [address, port])
	return OK


func set_ready(is_ready: bool) -> void:
	if not is_networked():
		return
	if is_server() and not dedicated_server:
		_ready_peers[1] = is_ready
		_broadcast_lobby()
		_try_start_match()
		return
	_rpc_set_ready.rpc_id(1, is_ready)


func connected_human_count() -> int:
	var count := 0
	for peer_id in _slots.keys():
		if int(_slots[peer_id]) >= 0:
			count += 1
	return count


func human_peer_ids() -> Array:
	var ids: Array = []
	for peer_id in _slots.keys():
		if int(_slots[peer_id]) >= 0:
			ids.append(int(peer_id))
	return ids


func notify_match_ready() -> void:
	if not is_networked():
		return
	if is_server() and not dedicated_server:
		_match_ready_peers[multiplayer.get_unique_id()] = true
		return
	if not is_server():
		_rpc_peer_match_ready.rpc_id(1)


func all_human_matches_ready() -> bool:
	var ids := human_peer_ids()
	if ids.is_empty():
		return false
	for peer_id in ids:
		if not _match_ready_peers.get(peer_id, false):
			return false
	return true


func _reset_peer() -> void:
	if multiplayer.peer_connected.is_connected(_on_peer_connected):
		multiplayer.peer_connected.disconnect(_on_peer_connected)
	if multiplayer.peer_disconnected.is_connected(_on_peer_disconnected):
		multiplayer.peer_disconnected.disconnect(_on_peer_disconnected)
	if multiplayer.connected_to_server.is_connected(_on_connected_to_server):
		multiplayer.connected_to_server.disconnect(_on_connected_to_server)
	if multiplayer.connection_failed.is_connected(_on_connection_failed):
		multiplayer.connection_failed.disconnect(_on_connection_failed)
	if multiplayer.server_disconnected.is_connected(_on_server_disconnected):
		multiplayer.server_disconnected.disconnect(_on_server_disconnected)
	if multiplayer.multiplayer_peer != null:
		multiplayer.multiplayer_peer.close()
	multiplayer.multiplayer_peer = null
	_peer = null
	_slots.clear()
	_ready_peers.clear()
	_match_ready_peers.clear()
	_match_started = false
	local_slot = 0
	dedicated_server = dedicated_server  # 有意保留专用服标记（self-assign），勿当作冗余代码"修复"


func _on_peer_connected(peer_id: int) -> void:
	if not is_server():
		return
	# 复核 P1-3：开局后新连接必须显式拒绝，否则后来者会挂在大厅死等。
	if _match_started:
		_rpc_reject.rpc_id(peer_id, "对局已开始，无法中途加入")
		_peer.disconnect_peer(peer_id)
		return
	var slot := _allocate_slot()
	if slot < 0:
		_rpc_reject.rpc_id(peer_id, "房间已满")
		_peer.disconnect_peer(peer_id)
		return
	_slots[peer_id] = slot
	_ready_peers[peer_id] = false
	_rpc_assign_slot.rpc_id(peer_id, slot)
	_broadcast_lobby()
	_set_status("玩家加入槽位 %d（当前 %d 人）" % [slot + 1, connected_human_count()])


func _on_peer_disconnected(peer_id: int) -> void:
	var slot := slot_of(peer_id)
	_slots.erase(peer_id)
	_ready_peers.erase(peer_id)
	if _match_started:
		# 复核 P1-2：掉线不再整局结束。清掉该玩家单位（见 NetSync._on_player_dropped），
		# 歼灭规则随之自然结算（掉线算负），其余人继续打完。
		if dedicated_server and connected_human_count() == 0:
			_set_status("所有玩家已掉线，专用服退出，等待 systemd 重启")
			get_tree().quit(0)
			return
		if slot >= 0 and is_server():
			player_dropped.emit(slot)
			_rpc_status.rpc("玩家 %d 已掉线，其单位已被移除，对局继续" % (slot + 1))
		return
	_broadcast_lobby()


func _on_connected_to_server() -> void:
	_set_status("已连接，请点准备")


func _on_connection_failed() -> void:
	_set_status("连接失败")
	_reset_peer()


func _on_server_disconnected() -> void:
	_set_status("服务器断开")
	_reset_peer()


func _allocate_slot() -> int:
	var used := {}
	for slot in _slots.values():
		used[int(slot)] = true
	for i in range(MAX_PLAYERS):
		if not used.has(i):
			return i
	return -1


func _broadcast_lobby() -> void:
	if not is_server():
		return
	var ready_count := 0
	for is_ready in _ready_peers.values():
		if is_ready:
			ready_count += 1
	var humans := connected_human_count()
	_set_status("房间 %d/%d 人，已准备 %d" % [humans, MAX_PLAYERS, ready_count])
	_rpc_lobby.rpc(humans, ready_count)


func _try_start_match() -> void:
	if not is_server() or _match_started:
		return
	var humans := connected_human_count()
	if humans < 2:
		return
	for peer_id in _ready_peers.keys():
		if not _ready_peers[peer_id]:
			return
	_match_started = true
	var peer_ids := PackedInt32Array()
	var slot_ids := PackedInt32Array()
	for peer_id in _slots.keys():
		peer_ids.append(int(peer_id))
		slot_ids.append(int(_slots[peer_id]))
	_rpc_start_match.rpc(humans, peer_ids, slot_ids)


func _set_status(text: String) -> void:
	_status = text
	status_changed.emit(text)


@rpc("any_peer", "reliable")
func _rpc_peer_match_ready() -> void:
	if not is_server():
		return
	_match_ready_peers[multiplayer.get_remote_sender_id()] = true


@rpc("any_peer", "reliable")
func _rpc_set_ready(is_ready: bool) -> void:
	if not is_server() or _match_started:
		return
	var peer_id := multiplayer.get_remote_sender_id()
	_ready_peers[peer_id] = is_ready
	_broadcast_lobby()
	_try_start_match()


@rpc("authority", "reliable")
func _rpc_assign_slot(slot: int) -> void:
	local_slot = slot
	_set_status("已分配阵营槽位 %d，点准备后开局" % (slot + 1))


@rpc("authority", "reliable")
func _rpc_lobby(human_count: int, ready_count: int) -> void:
	_set_status("房间 %d/%d 人，已准备 %d" % [human_count, MAX_PLAYERS, ready_count])


@rpc("authority", "reliable")
func _rpc_reject(reason: String) -> void:
	_set_status(reason)


@rpc("authority", "reliable")
func _rpc_abort(reason: String) -> void:
	push_error("联机中止: " + reason)
	_set_status(reason)


@rpc("authority", "reliable", "call_local")
func _rpc_status(text: String) -> void:
	# 对局中的状态文本没有 HUD 挂载点，先落控制台（测试同学用编辑器跑，Output 可见）。
	print("联机: ", text)
	_set_status(text)


@rpc("authority", "reliable", "call_local")
func _rpc_start_match(
	human_count: int, peer_ids: PackedInt32Array, slot_ids: PackedInt32Array
) -> void:
	var my_id := multiplayer.get_unique_id()
	for i in range(min(peer_ids.size(), slot_ids.size())):
		if peer_ids[i] == my_id:
			local_slot = slot_ids[i]
			break
	match_starting.emit()
	_start_loading(human_count)


func _start_loading(human_count: int) -> void:
	var MatchSettings = load("res://source/data-model/MatchSettings.gd")
	var PlayerSettings = load("res://source/data-model/PlayerSettings.gd")
	var LoadingScene = load("res://source/main-menu/Loading.tscn")
	var match_settings = MatchSettings.new()
	match_settings.visibility = match_settings.Visibility.PER_PLAYER
	if dedicated_server:
		match_settings.local_player_index = -1
		match_settings.visible_player = 0
	else:
		match_settings.local_player_index = local_slot
		match_settings.visible_player = local_slot
	for i in range(MAX_PLAYERS):
		var player_settings = PlayerSettings.new()
		player_settings.color = Constants.Player.COLORS[i]
		if i < human_count:
			player_settings.controller = Constants.PlayerType.HUMAN
		else:
			player_settings.controller = Constants.PlayerType.SIMPLE_CLAIRVOYANT_AI
		match_settings.players.append(player_settings)
	var loading = LoadingScene.instantiate()
	loading.match_settings = match_settings
	loading.map_path = MAP_PATH
	var tree := get_tree()
	var current := tree.current_scene
	current.get_parent().add_child(loading)
	tree.current_scene = loading
	current.queue_free()
