extends Node

## 2–4 人内测联机会话。服务器权威，客户端只发命令、收快照。

const DEFAULT_HOST := "101.43.121.102"
const DEFAULT_PORT := 24567
const MAX_PLAYERS := 4
const MAP_PATH := "res://source/match/maps/PlainAndSimple.tscn"
const NetCommandProxyScript := preload("res://source/net/NetCommandProxy.gd")

const SLOT_EMPTY := 0
const SLOT_HUMAN := 1
const SLOT_AI := 2

var dedicated_server := false
## E2E 测试开关: --e2e-peaceful 时专用服的 AI 首波延迟 600s, 供机器人先验证经济链。
var e2e_peaceful := false
## 服务器侧: 客户端立即开局时经 RPC 传来的和平模式标记(AI 首波延迟 600s)。
var e2e_peaceful_server := false
## 单人测试局的 AI 被动模式：AI 仍可采集、建造、生产，但不会主动攻击。
var passive_ai_test := false
var passive_ai_test_server := false
var local_slot := 0
var _pending_solo_start := false
var _pending_solo_with_ai := false
var _pending_solo_passive_ai_test := false
var last_rtt_ms := -1  # 客户端对服务器的最近一次 RPC 往返（毫秒），-1 = 无样本
var local_player_name := "指挥官-%03d" % (randi() % 1000)
var _peer: ENetMultiplayerPeer = null
var _slots: Dictionary = {}  # peer_id -> slot 0..3
var _ready_peers: Dictionary = {}  # peer_id -> bool
var _slot_kinds: Array[int] = [SLOT_EMPTY, SLOT_EMPTY, SLOT_EMPTY, SLOT_EMPTY]
var _names: Dictionary = {}  # peer_id -> 昵称（服务器权威）
var _match_started := false
var _status := "idle"
var _match_ready_peers: Dictionary = {}
var _connect_deadline_msec := 0  # 客户端 join 超时保险（10s），防 ENet 32s 死等
var last_lobby_slots: Array = []  # 最近一次大厅快照：[{kind, name, ready}, ×4]

signal status_changed(text)
signal match_starting
signal player_dropped(slot: int)  # 复核 P1-2：对局中玩家掉线（服务器发出，slot 为其阵营槽位）
signal lobby_updated(slots: Array)  # RA3 式大厅：4 槽位全量状态广播


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
	if args.has("--e2e-peaceful"):
		e2e_peaceful = true
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
		_slot_kinds[0] = SLOT_HUMAN
		_names[1] = local_player_name
		local_slot = 0
	_broadcast_lobby()
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
	_connect_deadline_msec = Time.get_ticks_msec() + 10_000
	return OK


func _process(_delta: float) -> void:
	# 复核 2026-09-02：ENet 对无响应地址默认约 32 秒才触发 connection_failed，
	# 大厅会一直卡在「正在连接」。10 秒仍停在 CONNECTING 就主动取消并复位。
	if _connect_deadline_msec > 0 and Time.get_ticks_msec() >= _connect_deadline_msec:
		_connect_deadline_msec = 0
		if is_networked() and multiplayer.multiplayer_peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTING:
			_set_status("连接超时（10 秒无响应）。请检查 IP 与端口；云服默认 101.43.121.102:24567")
			_reset_peer()


func set_ready(is_ready: bool) -> void:
	if not is_networked():
		return
	if is_server() and not dedicated_server:
		_ready_peers[1] = is_ready
		_broadcast_lobby()
		return
	_rpc_set_ready.rpc_id(1, is_ready)


func connected_human_count() -> int:
	var count := 0
	for peer_id in _slots.keys():
		if int(_slots[peer_id]) >= 0:
			count += 1
	return count


## 客户端到服务器的往返延迟（毫秒）；无样本返回 -1。走自带 ping RPC（Godot 4.7
## 的 ENetPacketPeer 没有 get_stat，实测调用报错——不要用引擎 RTT API）。
func get_ping_ms() -> int:
	return last_rtt_ms


## 客户端定期调用：向服务器发时间戳，服务器回显后算 RTT。
func send_ping() -> void:
	if is_networked() and not multiplayer.is_server():
		_rpc_ping.rpc_id(1, Time.get_ticks_msec())


@rpc("any_peer", "reliable")
func _rpc_ping(sent_msec: int) -> void:
	if not is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	if slot_of(sender) < 0:
		return
	_rpc_pong.rpc_id(sender, sent_msec)


@rpc("authority", "reliable")
func _rpc_pong(sent_msec: int) -> void:
	last_rtt_ms = clampi(Time.get_ticks_msec() - sent_msec, 0, 60000)


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
	_slot_kinds = [SLOT_EMPTY, SLOT_EMPTY, SLOT_EMPTY, SLOT_EMPTY]
	_names.clear()
	last_lobby_slots = []
	_match_started = false
	_connect_deadline_msec = 0
	_pending_solo_start = false
	_pending_solo_with_ai = false
	_pending_solo_passive_ai_test = false
	passive_ai_test = false
	passive_ai_test_server = false
	last_rtt_ms = -1
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
	_slot_kinds[slot] = SLOT_HUMAN
	_rpc_assign_slot.rpc_id(peer_id, slot)
	_broadcast_lobby()
	_set_status("玩家加入槽位 %d（当前 %d 人）" % [slot + 1, connected_human_count()])
	print("联机: 玩家加入槽位 %d（当前 %d 人）" % [slot + 1, connected_human_count()])


func _on_peer_disconnected(peer_id: int) -> void:
	var slot := slot_of(peer_id)
	_slots.erase(peer_id)
	_ready_peers.erase(peer_id)
	if slot >= 0 and slot < MAX_PLAYERS:
		_slot_kinds[slot] = SLOT_EMPTY
	_names.erase(peer_id)
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
	_connect_deadline_msec = 0
	_rpc_set_name.rpc_id(1, local_player_name)
	_set_status("已连接，请点准备")
	if _pending_solo_start:
		_pending_solo_start = false
		_auto_solo_start(_pending_solo_with_ai, _pending_solo_passive_ai_test)
		_pending_solo_with_ai = false
		_pending_solo_passive_ai_test = false


func _auto_solo_start(with_ai: bool = false, passive_ai_test: bool = false) -> void:
	# 等一拍，确保服务器已把本连接分配进槽位，再请求开局。
	await get_tree().create_timer(0.6).timeout
	if is_networked() and not multiplayer.is_server():
		_rpc_solo_start.rpc_id(1, e2e_peaceful, with_ai, passive_ai_test)


func _on_connection_failed() -> void:
	_set_status("连接失败")
	_reset_peer()


func _on_server_disconnected() -> void:
	# 对局中服务器断开：不再黑屏僵死，优雅回主菜单（复核 2026-08-31）。
	var in_match := _match_started
	_match_started = false
	_reset_peer()
	_set_status("服务器断开" + ("，对局已结束，返回主菜单" if in_match else ""))
	if in_match:
		get_tree().change_scene_to_file.call_deferred("res://source/main-menu/Main.tscn")


func _allocate_slot() -> int:
	var used := {}
	for slot in _slots.values():
		used[int(slot)] = true
	for i in range(MAX_PLAYERS):
		if _slot_kinds[i] == SLOT_AI:
			continue
		if not used.has(i):
			return i
	return -1


## RA3 式大厅：服务器把 4 个槽位的完整状态广播给所有端。
func _broadcast_lobby() -> void:
	if not is_server():
		return
	var peer_by_slot := {}
	for peer_id in _slots.keys():
		peer_by_slot[int(_slots[peer_id])] = int(peer_id)
	var slots: Array = []
	var ready_count := 0
	for i in range(MAX_PLAYERS):
		var kind := int(_slot_kinds[i])
		var entry := {"kind": kind, "name": "", "ready": false}
		if kind == SLOT_HUMAN and peer_by_slot.has(i):
			var pid: int = peer_by_slot[i]
			entry["name"] = str(_names.get(pid, "指挥官"))
			entry["ready"] = bool(_ready_peers.get(pid, false))
			if entry["ready"]:
				ready_count += 1
		elif kind == SLOT_AI:
			entry["name"] = "简单 AI"
		slots.append(entry)
	_set_status("房间 %d/%d 人，已准备 %d" % [connected_human_count(), MAX_PLAYERS, ready_count])
	last_lobby_slots = slots
	lobby_updated.emit(slots)  # 本机（listen 房主）也要刷新自己的大厅视图
	_rpc_lobby.rpc(slots)


func set_local_name(player_name: String) -> void:
	local_player_name = player_name.strip_edges().substr(0, 16)
	if is_networked() and not multiplayer.is_server():
		_rpc_set_name.rpc_id(1, local_player_name)


func host_set_slot_kind(slot: int, kind: int) -> void:
	if not is_networked():
		return
	if is_server():
		_server_set_slot_kind(0, slot, kind)
		return
	_rpc_set_slot_kind.rpc_id(1, slot, kind)


func _server_set_slot_kind(sender_slot: int, slot: int, kind: int) -> void:
	if not _is_room_owner_slot(sender_slot) or slot < 0 or slot >= MAX_PLAYERS:
		return
	if kind != SLOT_EMPTY and kind != SLOT_AI:
		return
	if _slot_kinds[slot] == SLOT_HUMAN:
		return
	_slot_kinds[slot] = kind
	_broadcast_lobby()


@rpc("any_peer", "reliable")
func _rpc_set_name(player_name: String) -> void:
	if not is_server():
		return
	var peer_id := multiplayer.get_remote_sender_id()
	if slot_of(peer_id) < 0:
		return
	_names[peer_id] = player_name.strip_edges().substr(0, 16)
	_broadcast_lobby()


@rpc("any_peer", "reliable")
func _rpc_set_slot_kind(slot: int, kind: int) -> void:
	if not is_server():
		return
	var sender_slot := slot_of(multiplayer.get_remote_sender_id())
	_server_set_slot_kind(sender_slot, slot, kind)


func _try_start_match() -> void:
	if not is_server() or _match_started:
		return
	# 联机大厅口径（2026-09-05）：「点准备后开局」——所有已连接人类就绪即开，
	# 空槽/补位 AI 按大厅槽位配置参战；单人 + AI 也能在专用服直接开局。
	if connected_human_count() < 1:
		return
	for peer_id in _ready_peers.keys():
		if not _ready_peers[peer_id]:
			return
	_launch_match()


## 房主判定：本机 listen server 为 0 号槽；专用服以最近一次大厅广播为准，
## 房主 = 最小槽位的人类玩家（此前判定写死 slot 0，专用服上 slot 0 被 AI
## 补位时真人永远拿不到开局按钮——2026-09-05 用户实测事故）。
## 注意：客户端的 _slots/_slot_kinds 字典不随广播同步，必须用 last_lobby_slots。
func is_room_owner() -> bool:
	if not is_networked():
		return false
	# 本机 listen server：自己就是 0 号槽房主。
	if not dedicated_server and local_slot == 0:
		return true
	# 专用服：房主 = 最小槽位的人类（以大厅广播快照为准；客户端的
	# _slots/_slot_kinds 字典不同步，不能用于判定）。
	var first_human_slot := -1
	for slot in range(last_lobby_slots.size()):
		if int(last_lobby_slots[slot].get("kind", -1)) == SLOT_HUMAN:
			first_human_slot = slot
			break
	return first_human_slot >= 0 and local_slot == first_human_slot


## 立即开局（单人开房仍走服务器）。
## 未连接时先连默认云服，连上自动单人开局；空槽保持空，不自动生成敌人。
## 本机 listen server 仅是开发自测路径，不在「立即开局」里。
## peaceful：和平模式（AI 首波进攻延迟 600s），供副官练发展与探索，
## 由调试端点 start op 的 peaceful 参数传入（--e2e-peaceful 仍作为全局默认）。
## 清除「自动开局」意图（挂起的 start_solo）。加入局服（普通进大厅）前必须调用，
## 防止此前残留的单人开局意图在连上服务器后自动开局（2026-09-05 实测事故）。
func clear_auto_start_intent() -> void:
	_pending_solo_start = false
	_pending_solo_with_ai = false
	_pending_solo_passive_ai_test = false


func start_solo(with_ai: bool = false, passive_ai_test: bool = false, peaceful: bool = false) -> void:
	var use_peaceful := peaceful or e2e_peaceful
	if not is_networked():
		_pending_solo_start = true
		_pending_solo_with_ai = with_ai
		_pending_solo_passive_ai_test = passive_ai_test
		var err := join(DEFAULT_HOST, DEFAULT_PORT)
		if err != OK:
			_pending_solo_start = false
			_set_status("连接失败：%s" % err)
		else:
			_set_status("正在连接 %s:%d，连上后自动开局…" % [DEFAULT_HOST, DEFAULT_PORT])
		return
	# create_client() returns before ENet finishes the handshake.  Do not send
	# an RPC until connected_to_server has fired; callers such as --autojoin can
	# legitimately reach this path during that short window.
	if not is_server() and multiplayer.multiplayer_peer.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED:
		_pending_solo_start = true
		_pending_solo_with_ai = with_ai
		_pending_solo_passive_ai_test = passive_ai_test
		_set_status("等待服务器连接，连上后自动开局…")
		return
	if not is_server():
		_rpc_solo_start.rpc_id(1, use_peaceful, with_ai, passive_ai_test)
		return
	e2e_peaceful_server = use_peaceful
	passive_ai_test_server = passive_ai_test
	if with_ai:
		_ensure_solo_opponent()
	_launch_match()


## 仅供冒烟/演示脚本显式请求「单人对 AI」；普通立即开局不调用。
func _ensure_solo_opponent() -> void:
	for i in range(MAX_PLAYERS):
		if _slot_kinds[i] == SLOT_AI:
			return
	for i in range(MAX_PLAYERS):
		if _slot_kinds[i] == SLOT_EMPTY:
			_slot_kinds[i] = SLOT_AI
			return


func _launch_match() -> void:
	if not is_server() or _match_started:
		return
	if connected_human_count() < 1:
		return
	_match_started = true
	var humans := connected_human_count()
	var peer_ids := PackedInt32Array()
	var slot_ids := PackedInt32Array()
	var kinds := PackedInt32Array()
	for i in range(MAX_PLAYERS):
		kinds.append(int(_slot_kinds[i]))
	for peer_id in _slots.keys():
		peer_ids.append(int(peer_id))
		slot_ids.append(int(_slots[peer_id]))
	print("联机: 开局，人类 %d，槽位 %s，配置 %s" % [humans, str(slot_ids), str(kinds)])
	_rpc_start_match.rpc(humans, peer_ids, slot_ids, kinds, passive_ai_test_server)


@rpc("any_peer", "reliable")
## 服务器侧房主判定：最小槽位的人类（与大厅 is_room_owner / Online UI 同口径）。
## 旧口径写死 sender_slot == 0，专用服上 0 号槽被 AI 补位时真人房主的所有
## 开局/增删 AI 请求都会被静默拒绝（2026-09-05 用户实测三按钮全无反应）。
func _is_room_owner_slot(sender_slot: int) -> bool:
	var human_slots: Array = []
	for i in range(MAX_PLAYERS):
		if int(_slot_kinds[i]) == SLOT_HUMAN:
			human_slots.append(i)
	if human_slots.is_empty():
		return false
	return sender_slot == human_slots.min()


func _rpc_solo_start(
	peaceful: bool = false, with_ai: bool = false, passive_ai_test: bool = false
) -> void:
	if not is_server() or _match_started:
		return
	var sender_slot := slot_of(multiplayer.get_remote_sender_id())
	if sender_slot < 0:
		return
	if not _is_room_owner_slot(sender_slot):
		return
	e2e_peaceful_server = peaceful
	passive_ai_test_server = passive_ai_test
	if with_ai:
		_ensure_solo_opponent()
	_launch_match()


func _set_status(text: String) -> void:
	_status = text
	status_changed.emit(text)


## 单人练习房判定：参战玩家（slot_kind != NONE 占位）不足 2 个。
## 设计师需求（2026-09-04）：单人开局只有玩家主动退出才结束，不以胜利/失败为结束——
## 因此结算 UI 与专用服回收都必须跳过，否则单人局开局即被判胜利并回收服务器。
func is_solo_practice() -> bool:
	var tree := get_tree()
	if tree == null:
		return false
	var count := 0
	for p in tree.get_nodes_in_group("players"):
		if p.has_meta("slot_kind") and int(p.get_meta("slot_kind")) != 0:
			count += 1
	return count < 2


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
	# 复核 2026-09-05：准备只作状态展示，不再自动开局——开局权在房主。


@rpc("authority", "reliable")
func _rpc_assign_slot(slot: int) -> void:
	local_slot = slot
	_set_status("已分配阵营槽位 %d，点准备后开局" % (slot + 1))


@rpc("authority", "reliable")
func _rpc_lobby(slots: Array) -> void:
	last_lobby_slots = slots
	lobby_updated.emit(slots)


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
	human_count: int,
	peer_ids: PackedInt32Array,
	slot_ids: PackedInt32Array,
	kinds: PackedInt32Array,
	passive_ai_test: bool = false
) -> void:
	self.passive_ai_test = passive_ai_test
	var my_id := multiplayer.get_unique_id()
	for i in range(min(peer_ids.size(), slot_ids.size())):
		if peer_ids[i] == my_id:
			local_slot = slot_ids[i]
			break
	match_starting.emit()
	_start_loading(kinds)


func _start_loading(kinds: PackedInt32Array) -> void:
	var MatchSettings = load("res://source/data-model/MatchSettings.gd")
	var PlayerSettings = load("res://source/data-model/PlayerSettings.gd")
	var LoadingScene = load("res://source/main-menu/Loading.tscn")
	var match_settings = MatchSettings.new()
	# 联机对局恢复 PER_PLAYER 战争迷雾（2026-09-04）。
	# 此前 Demo 期临时强制 FULL（当时 PER_PLAYER 的 FogOfWar 合成在 ENet 下有
	# 整屏黑盖问题）；现在 AI 副官参战，全可见=上帝视角破坏公平，必须恢复迷雾。
	# 若客户端出现黑屏回归，单独修渲染管线，不再回退到全可见。
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
		if i < kinds.size() and int(kinds[i]) == SLOT_HUMAN:
			player_settings.controller = Constants.PlayerType.HUMAN
		elif i < kinds.size() and int(kinds[i]) == SLOT_AI:
			player_settings.controller = Constants.PlayerType.SIMPLE_CLAIRVOYANT_AI
		else:
			# 大厅里被房主撤掉 AI 的空槽：占位玩家，不再无脑补 AI。
			player_settings.controller = Constants.PlayerType.NONE
		match_settings.players.append(player_settings)
	var loading = LoadingScene.instantiate()
	loading.match_settings = match_settings
	loading.map_path = MAP_PATH
	var tree := get_tree()
	# 复核 2026-08-31：重开局时旧 Match 尚未释放完，新 Match 会被改名 @Match@2，
	# 与服务器约定的 /root/Match/NetSync RPC 路径永久错开——表现为「单位点不动」。
	# 先给旧 Match/Loading 改名让路（queue_free 延迟销毁，不炸正在派发的 RPC）。
	for stale_name in ["Match", "Loading"]:
		var stale := tree.root.get_node_or_null(NodePath(stale_name))
		if stale != null:
			stale.name = "%s_old_%d" % [stale_name, Time.get_ticks_msec()]
			stale.queue_free()
	var current := tree.current_scene
	current.get_parent().add_child(loading)
	tree.current_scene = loading
	current.queue_free()
