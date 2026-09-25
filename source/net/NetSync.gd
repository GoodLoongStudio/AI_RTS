extends Node

## 挂在 Match 下：客户端把命令转发到服务器，服务器按 10Hz 广播单位快照。

const SNAPSHOT_INTERVAL_FRAMES := 6
# 联机迷雾裁剪（2026-09-14 用户要求"联机不应该拿到迷雾里敌人的数据"）：
# 快照按**每个客户端自己的可见范围**定向下发，判定与单机 UnitVisibilityHandler 同口径。
const VIS_SIGHT_COMPENSATION := 2.0
# 每 2 次快照（≈5Hz）重算一次可见集合；敌人进入视野最多延迟 ~200ms。
const VISIBILITY_RECALC_SNAPSHOTS := 2
# GDScript 的 `is` 右侧不能用局部变量（parse error），用脚本资源等价比较代替。
const HumanScript := preload("res://source/match/players/human/Human.gd")
# 命令可视化（纯表现层）：客户端侧动态挂载，画副官指令的信标与路径；专用服不挂载。
const CommandVisualizerScript := preload("res://source/match/hud/CommandVisualizer.gd")
# 客户端 HP 首次同步标记：见 `_apply_authoritative_hp` 的注释（防"建造误播受击"）。
const NET_HP_SYNCED_META := "net_authoritative_hp_synced"
# 副官来源标记（2026-09-21 双 runner/自接管事故修复）：加在转发命令 `extra` 的
# **前缀**上随 RPC 带到局服。副官自己的命令**不是**玩家手动命令，绝不能被
# `_notify_adjutant_player_override` 当成"玩家接管"——否则副官每下发一条命令，
# 受令单位就被踢出 AI 托管（实测 sp_ft2_branch 局 112 个机动单位全部被踢，
# 军事/侦察轨再无执行者，全军在家攒兵直至超时）。
# 前缀形式（而非独占 extra）：produce/build 的 `scene|cmd_id` 协议原样保留，
# 局服侧先摘前缀再按原协议解析。
const ADJUTANT_SOURCE_MARKER := "src=adjutant|"

var _match: Node = null
var _frame := 0
var _live := false
var _local_match_started := false
# 当前转发的命令是否副官下发（DCS `_adjutant_execute` 期间置位）：
# 客户端傀儡端的副官命令同样走 `forward_command`，必须带来源标记，
# 否则局服会把它们当成玩家手动命令并收回托管（见 ADJUTANT_SOURCE_MARKER）。
var _adjutant_source := false

# 复核 P0-1：初始实体清单——NodePath 一致性的启动期硬校验，错了拒绝 go-live。
var _own_manifest: PackedStringArray = PackedStringArray()
var _client_manifests: Dictionary = {}  # peer_id -> PackedStringArray
var _go_live_blocked := false

# 结算回主菜单只允许执行一次（服务器广播与客户端本地推断可能先后到达）。
var _match_over_handled := false

# 复核 P1-1：客户端两快照线性插值（渲染落后一个快照周期，消除 10Hz 瞬移感）。
var _interp_prev: Dictionary = {}  # Match 相对路径 -> Vector3
var _interp_target: Dictionary = {}  # Match 相对路径 -> Vector3
var _interp_prev_yaw: Dictionary = {}  # Match 相对路径 -> float（平面朝向，弧度）
var _interp_target_yaw: Dictionary = {}  # Match 相对路径 -> float
var _last_snap_msec := 0
var _snap_interval_msec := 100

# 监督 HUD：右上角显示 延迟/FPS（云服显示 RTT，本机房显示"本机"，离线显示"单机"）。
var _hud_label: Label = null
var _hud_accum := 0.0
var _authoritative_stance_by_path := {}
var _authoritative_fire_policy_by_path := {}

# 迷雾裁剪：每个客户端槽位的可见集合（path 集合）与待发的 reconcile 条目。
var _visible_paths_by_slot: Dictionary = {}    # slot:int -> {path: true}
var _visible_entries_by_slot: Dictionary = {}  # slot:int -> Array[reconcile entry]
var _pending_reconcile_slots: Dictionary = {}  # slot:int -> true（可见集合变化，待定向 reconcile）
var _visibility_recalc_countdown := 0


func _ready() -> void:
	_match = get_parent()
	# 表现层挂载点在 is_networked() 早退之前：单机局也能看到命令可视化。
	if not NetSession.is_dedicated_server():
		_ensure_order_visualizer()
		# 右上角状态行（延时/FPS）同理提到早退之前：`_hud_tick` 本来就有"单机"分支，
		# 但它过去永远走不到（离线局在上一行 return 了）→ 单机玩家看不到帧率/画质。
		_ensure_hud()
		set_process(true)          # 离线局由 `_process` 驱动 `_hud_tick`（联机走 `_physics_process`）
	set_physics_process(NetSession.is_networked())
	if not NetSession.is_networked():
		return
	MatchSignals.match_started.connect(_on_any_match_started)
	# 对局结束广播(2026-08-31): 服务器结算后通知所有客户端回主菜单,
	# 否则客户端滞留死亡对局——视野归零全黑+HUD(黑屏假象), 且专用服不回收。
	MatchSignals.match_finished_with_defeat.connect(_on_match_finished.bind("失败"))
	MatchSignals.match_finished_with_victory.connect(_on_match_finished.bind("胜利"))
	if NetSession.is_server():
		MatchSignals.unit_spawned.connect(_on_unit_spawned)
		NetSession.player_dropped.connect(_on_player_dropped)


func _ensure_hud() -> void:
	if _hud_label != null:
		return
	var layer := CanvasLayer.new()
	layer.layer = 60
	add_child(layer)
	_hud_label = Label.new()
	_hud_label.add_theme_font_size_override("font_size", 14)
	_hud_label.add_theme_color_override("font_color", Color(0.95, 0.93, 0.85))
	_hud_label.add_theme_color_override("font_outline_color", Color(0.1, 0.08, 0.05, 0.75))
	_hud_label.add_theme_constant_override("outline_size", 4)
	layer.add_child(_hud_label)
	_hud_label.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	_hud_label.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_hud_label.offset_right = -12.0
	_hud_label.offset_top = 8.0


## 命令可视化器：只在有渲染的角色上挂载（专用服 headless 不建节点）。
func _ensure_order_visualizer() -> void:
	if _match == null or _match.get_node_or_null("CommandVisualizer") != null:
		return
	var visualizer := CommandVisualizerScript.new()
	visualizer.name = "CommandVisualizer"
	_match.add_child(visualizer)


func _hud_tick(delta: float) -> void:
	if _hud_label == null:
		return
	_hud_accum += delta
	if _hud_accum < 0.5:
		return
	_hud_accum = 0.0
	var ping_text := "单机"
	if NetSession.is_networked():
		if NetSession.is_server():
			ping_text = "本机房 %d 人" % NetSession.connected_human_count()
		else:
			NetSession.send_ping()
			var ping := NetSession.get_ping_ms()
			# 0 = RTT 样本未积累（刚连上），显示 -- 避免误读成"0 延迟"。
			ping_text = ("%d ms" % ping) if ping > 0 else "-- ms"
	# 帧率治理把"当前画质档"接在**同一行**后面（用户 2026-09-14：不要另开一行，
	# 就用原来右上角这行）—— 玩家因此能看到"自动降画质"到底在不在动、动到哪一档。
	var quality := ""
	var governor := get_node_or_null("/root/PerformanceGovernor")
	if governor != null and governor.has_method("stats"):
		var stats: Dictionary = governor.call("stats")
		quality = str(governor.call("quality_suffix", stats))
	var text := "%s · %d FPS" % [ping_text, Engine.get_frames_per_second()]
	if not quality.is_empty():
		text += " · %s" % quality
	_hud_label.text = text


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
		var entry = _reconcile_entry_for(unit)
		if entry != null:
			entries.append(entry)
	return entries


## 单个单位的 reconcile 条目（生成节点所需的全部信息）；不可序列化/无场景的单位返回 null。
func _reconcile_entry_for(unit):
	if unit == null or not is_instance_valid(unit):
		return null
	var scene_path := String(unit.scene_file_path)
	if scene_path.is_empty():
		return null
	return {
		"path": str(_match.get_path_to(unit)),
		"parent": str(_match.get_path_to(unit.get_parent())),
		"scene": scene_path,
		"xf": unit.global_transform,
		"hp": unit.hp if ("hp" in unit and unit.hp != null) else 0.0,
		"stance": _authoritative_stance(unit),
		"fire_policy": _authoritative_fire_policy(unit),
	}


func _authoritative_stance(unit: Node, runtime: Node = null) -> String:
	if runtime == null:
		runtime = _match.get_node_or_null("CommandRuntime")
	if runtime != null and runtime.has_method("GetEngagementStance"):
		return str(runtime.GetEngagementStance(unit))
	return "Aggressive"


func _authoritative_fire_policy(unit: Node, runtime: Node = null) -> String:
	if runtime == null:
		runtime = _match.get_node_or_null("CommandRuntime")
	if runtime != null and runtime.has_method("GetFirePolicy"):
		return str(runtime.GetFirePolicy(unit))
	return "FireAtWill"


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
		unit.hp if "hp" in unit else 0.0,
		str(unit.name)
	)


func _on_unit_tree_exited(path: String) -> void:
	if not NetSession.is_server() or not _live:
		return
	_rpc_despawn.rpc(path)


func _physics_process(delta: float) -> void:
	if not NetSession.is_networked():
		return
	_hud_tick(delta)
	if NetSession.is_server():
		_server_tick()
	else:
		_client_interp_tick()


## 【单机也刷新右上角状态行】`_physics_process` 在离线局被关掉（`is_networked()=false`），
## 过去整个 `_hud_tick` 也跟着不跑 → 单机玩家看不到帧率（"单机"分支写了但走不到）。
## 这里只驱动**表现层**（延时/FPS/画质档），不碰任何网络逻辑。
func _process(delta: float) -> void:
	if NetSession.is_networked() or NetSession.is_dedicated_server():
		return
	_hud_tick(delta)


func _server_tick() -> void:
	if not _live:
		_try_go_live()
	if not _live:
		return
	_frame += 1
	if not _has_remote_human():
		return
	if _frame % SNAPSHOT_INTERVAL_FRAMES != 0:
		return
	_broadcast_snapshot()


func _has_remote_human() -> bool:
	var mine := multiplayer.get_unique_id()
	for peer_id in NetSession.human_peer_ids():
		if int(peer_id) != mine:
			return true
	return false


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
		if _interp_target_yaw.has(path):
			var prev_yaw: float = float(_interp_prev_yaw.get(path, _interp_target_yaw[path]))
			var target_yaw: float = float(_interp_target_yaw[path])
			unit.rotation.y = lerp_angle(prev_yaw, target_yaw, t)


## 表现事件（目前是开火）要求把某个傀儡的朝向**立刻**对齐权威值：
## 同时改写两个插值锚点，使后续帧从新值继续平滑，而不是被旧 prev 拉回去
## （只改 unit.rotation.y 会出现"对齐一帧、下一帧弹回"）。
## 只动朝向：位置插值、快照结算都不受影响。见 `Unit._snap_presentation_yaw`。
func reset_presentation_yaw(path: String, yaw: float) -> void:
	if not _interp_target_yaw.has(path):
		return
	_interp_prev_yaw[path] = yaw
	_interp_target_yaw[path] = yaw
	var unit := _match.get_node_or_null(NodePath(path))
	if unit != null and is_instance_valid(unit):
		unit.rotation.y = yaw


## 标记/解除"接下来转发的命令来自副官"（调用方：DebugControlServer 的
## `_adjutant_execute`，与本进程 DCS 的 `_adjutant_executing` 同步置位）。
func set_adjutant_source(value: bool) -> void:
	_adjutant_source = bool(value)


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
	# 副官来源随命令带到局服（前缀，不覆盖 produce/build 的 extra 协议）。
	var extra_out := extra
	if _adjutant_source and not extra_out.begins_with(ADJUTANT_SOURCE_MARKER):
		extra_out = ADJUTANT_SOURCE_MARKER + extra_out
	print("[CMD] 客户端提交 op=%s units=%s dest=%s" % [op, paths, destination])
	_rpc_command.rpc_id(1, op, paths, destination, target_path, extra_out)
	# 联机客户端**拿不到**逐单位结果（服务器异步执行）：返回"已发送"口径，
	# 由 HUD 显示"已发送（等待服务器确认）"，不再伪造 Accepted + 空结果
	# （旧版让命令栏恒显示"接受 0，拒绝 0"，玩家无法判断命令是否生效 — 2026-09-14）。
	return {
		"status": "PendingAuthority",
		"accepted": unit_nodes.size(),
		"rejected": 0,
		"unit_results": [],
	}


## 客户端 HUD 只读取最近一次服务器快照确认的策略。
func get_authoritative_engagement_stance(unit) -> String:
	if unit == null or not is_instance_valid(unit):
		return "Aggressive"
	return str(_authoritative_stance_by_path.get(str(_match.get_path_to(unit)), "Aggressive"))


func get_authoritative_fire_policy(unit) -> String:
	if unit == null or not is_instance_valid(unit):
		return "FireAtWill"
	return str(_authoritative_fire_policy_by_path.get(str(_match.get_path_to(unit)), "FireAtWill"))


## 把权威 hp 写进**客户端**单位。
##
## 为什么不能直接 `unit.hp = value`：客户端单位 `_ready` 后会被平衡配置设成**满血**
##（`BalanceConfigRuntime` 的 `unit.Set("hp", definition.MaxHp)`），而施工中的建筑
## 权威血量是 **1** —— 直赋等于"血量下降"，`Unit._set_hp` 会广播 `unit_damaged`，
## 旁白随即误播「基地遭到攻击」（2026-09-15 用户实测：每次建造都会响）。
## 权威端走的是 `mark_as_under_construction` → `set_hp_without_damage(1)`，所以单机不中，
## 只在联机客户端命中。
##
## 规则：**首次**把权威 hp 写进单位 = 初始化，不算受击（走 set_hp_without_damage）；
## 之后的下降才是真受击，保持原有"遭到攻击"播报（联机客户端没有别的受击事件源）。
func _apply_authoritative_hp(unit: Node, value: float) -> void:
	if not ("hp" in unit):
		return
	if not unit.has_meta(NET_HP_SYNCED_META):
		unit.set_meta(NET_HP_SYNCED_META, true)
		if unit.has_method("set_hp_without_damage"):
			unit.set_hp_without_damage(value)
			return
	unit.hp = value


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
		if item.has("stance"):
			_authoritative_stance_by_path[path] = str(item["stance"])
		if item.has("fire_policy"):
			_authoritative_fire_policy_by_path[path] = str(item["fire_policy"])
		var unit := _match.get_node_or_null(NodePath(path))
		if unit == null or not is_instance_valid(unit):
			continue
		_interp_prev[path] = _interp_target.get(path, item["pos"])
		_interp_target[path] = item["pos"]
		if item.has("yaw"):
			# 朝向与位置同走插值：直接赋值会让客户端朝向按快照频率(≈10Hz)阶跃跳变，
			# 视觉表现为单位原地高频抖动/瞬转（2026-09-02 移动故障视频定位）。
			_interp_prev_yaw[path] = _interp_target_yaw.get(path, float(item["yaw"]))
			_interp_target_yaw[path] = float(item["yaw"])
		if item.has("hp") and item["hp"] != null and "hp" in unit:
			_apply_authoritative_hp(unit, float(item["hp"]))
		if item.has("action") and unit.has_method("apply_presentation_action"):
			unit.apply_presentation_action(str(item["action"]))
		# 施工进度：只改外观与进度镜像，**不动 hp**（客户端 hp 由上面的快照结算）。
		if item.has("construction") and unit.has_method("present_construction"):
			var report: Array = item["construction"]
			if report.size() >= 2:
				unit.present_construction(int(report[0]), int(report[1]))
		# 炮管朝向镜像：让客户端炮塔的炮口与权威端一致（联机 ≠ 本地的老问题之一）。
		if item.has("barrel_yaw") and unit.has_method("apply_presentation_barrel_yaw"):
			unit.apply_presentation_barrel_yaw(float(item["barrel_yaw"]))
		# 生产队列镜像：让客户端 HUD 与服务器一致（增/改/删都在这一个入口收敛）。
		if item.has("production") and "production_queue" in unit \
				and unit.production_queue != null \
				and unit.production_queue.has_method("apply_presentation_snapshot"):
			unit.production_queue.apply_presentation_snapshot(item["production"])
	for path in _interp_target.keys():
		if not seen.has(path):
			_interp_prev.erase(path)
			_interp_target.erase(path)
			_interp_prev_yaw.erase(path)
			_interp_target_yaw.erase(path)
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
	var command_runtime = _match.get_node_or_null("CommandRuntime")
	var entries_all: Array = []  # [{unit, entry}]：快照条目（供逐客户端迷雾过滤）
	for unit in get_tree().get_nodes_in_group("units"):
		if unit == null or not is_instance_valid(unit):
			continue
		var entry := {
			"path": str(_match.get_path_to(unit)),
			"pos": unit.global_position,
			"yaw": unit.rotation.y,
			"hp": unit.hp if ("hp" in unit and unit.hp != null) else 0,
			"stance": _authoritative_stance(unit, command_runtime),
			"fire_policy": _authoritative_fire_policy(unit, command_runtime),
		}
		# 当前动作路径：傀儡本地拿不到 `action`（Unit._set_action 主动丢弃），
		# 表现层与 UI 需要它来判断"在建造/采集/攻击"（例如建造预览要避开建造中的工人）。
		if "action" in unit and unit.action != null and unit.action.get_script() != null:
			entry["action"] = str(unit.action.get_script().resource_path)
		# 施工进度：建造中的建筑必须让客户端也"看得见在造"。
		# 为什么走**快照**而不是一次性事件：快照 10Hz、幂等、可自愈 ——
		# 丢包、事件早于生成、重连都不会让客户端卡在错误外观（2026-09-11）。
		if unit.has_method("construction_progress_report"):
			var report: Array = unit.construction_progress_report()
			if report.size() >= 2 and int(report[1]) > 0:
				entry["construction"] = report
		# 炮塔炮管朝向（2026-09-12）：上面只下发**根节点** yaw，而权威端转的是炮管节点
		# （待机扫描 / 战斗瞄准都作用于 `node_to_rotate`）→ 客户端炮塔的炮管永远停在
		# 出厂角度。这里把炮管全局 yaw 一并下发（坦克等机动单位靠车体朝向，无需此项）。
		if unit.has_method("presentation_aim_node"):
			var aim_node = unit.presentation_aim_node()
			if aim_node != null:
				entry["barrel_yaw"] = aim_node.global_rotation.y
		# 生产队列镜像：客户端 HUD（RA3 侧栏）据此显示排队与建造进度动画。
		# **空数组也必须下发**：客户端的 apply_presentation_snapshot 靠"本次收到的
		# 集合"收敛增/改/删 —— 字段缺失时它整段跳过，删除分支永不执行，于是服务器
		# 已经造完、客户端仍永久残留最后一个元素。
		# 2026-09-11 实测症状：服务器 barracks 队列已空（命令账本 4 条 produce 全
		# Accepted、场上已出 4 个步兵），客户端 legacy_mirror 仍挂着
		# `state=Producing completed_work=118/120` → RA3 侧栏步兵卡片卡住不消失。
		if "production_queue" in unit and unit.production_queue != null \
				and unit.production_queue.has_method("presentation_snapshot"):
			entry["production"] = unit.production_queue.presentation_snapshot()
		entries_all.append({"unit": unit, "entry": entry})
	var resources_payload: Array = []
	var players := get_tree().get_nodes_in_group("players")
	for i in range(players.size()):
		var player = players[i]
		resources_payload.append(
			{"slot": i, "a": int(player.resource_a), "b": int(player.resource_b)}
		)
	if _frame % 100 == 0:
		print("[SNAP] 服务器镜像余额: ", resources_payload)
	# 复核 P2：快照携带服务器帧号，客户端用它做资源版本去重（原来传客户端本地 _frame 恒为 0）。
	# 【2026-09-14 迷雾裁剪】改为**逐客户端定向**下发：每个客户端只收到"自己看得见的单位"；
	# 可见集合变化时补一条定向 reconcile（客户端据此增/删节点 = 敌人进入/离开视野）。
	if _visibility_recalc_countdown <= 0:
		_recompute_client_visibility(entries_all)
		_visibility_recalc_countdown = VISIBILITY_RECALC_SNAPSHOTS
	_visibility_recalc_countdown -= 1
	var my_peer_id := multiplayer.get_unique_id()
	for peer_id in NetSession.human_peer_ids():
		if peer_id == my_peer_id:
			continue  # 本机房主本地即权威，不需要快照
		var slot := NetSession.slot_of(peer_id)
		if slot < 0:
			continue
		var visible_paths: Dictionary = _visible_paths_by_slot.get(slot, {})
		var payload: Array = []
		for item in entries_all:
			if visible_paths.has(str(item["entry"]["path"])):
				payload.append(item["entry"])
		_rpc_snapshot.rpc_id(peer_id, payload, resources_payload, _frame)
		if _pending_reconcile_slots.has(slot):
			_pending_reconcile_slots.erase(slot)
			_rpc_reconcile.rpc_id(peer_id, _visible_entries_by_slot.get(slot, []))


## 重算"每个客户端玩家能看到哪些单位"（服务器侧，迷雾裁剪）。
## 口径与单机一致：己方 / 中立（无主）恒可见；其它玩家的单位只有落在己方
## "揭示单位"（is_revealing：在 revealed_units 组且 visible）的 sight_range 内才可见。
## 可见集合发生变化时登记 `_pending_reconcile_slots`，由快照发送端补一条定向 reconcile。
func _recompute_client_visibility(entries_all: Array) -> void:
	var players := get_tree().get_nodes_in_group("players")
	var all_units := get_tree().get_nodes_in_group("units")
	for peer_id in NetSession.human_peer_ids():
		var slot := NetSession.slot_of(peer_id)
		if slot < 0 or slot >= players.size():
			continue
		var player = players[slot]
		if player == null or not is_instance_valid(player):
			continue
		var revealers: Array = []
		for unit in all_units:
			if unit == null or not is_instance_valid(unit):
				continue
			if unit.get_parent() != player:
				continue
			if unit.has_method("is_revealing") and unit.is_revealing():
				revealers.append(unit)
		var visible_paths: Dictionary = {}
		var visible_entries: Array = []
		for item in entries_all:
			var unit = item["unit"]
			if not _is_unit_visible_to_player(unit, player, revealers):
				continue
			var path := str(item["entry"]["path"])
			visible_paths[path] = true
			var entry = _reconcile_entry_for(unit)
			if entry != null:
				visible_entries.append(entry)
		var previous: Dictionary = _visible_paths_by_slot.get(slot, {})
		var changed := previous.size() != visible_paths.size()
		if not changed:
			for path in visible_paths.keys():
				if not previous.has(path):
					changed = true
					break
		_visible_paths_by_slot[slot] = visible_paths
		_visible_entries_by_slot[slot] = visible_entries
		if changed:
			_pending_reconcile_slots[slot] = true


## 判定一个单位是否对某客户端玩家可见（服务器侧只读；显式 float 避免 GDScript 类型推断坑）。
func _is_unit_visible_to_player(unit, player, revealers: Array) -> bool:
	var owner = unit.get("player")
	if owner == player:
		return true
	# 中立实体（资源点等无主对象）始终可见：否则玩家看不到可采集资源。
	if owner == null:
		return true
	for revealer in revealers:
		var sight = revealer.get("sight_range")
		if sight == null:
			continue
		var rp: Vector3 = revealer.global_position
		var up: Vector3 = unit.global_position
		var dx: float = rp.x - up.x
		var dz: float = rp.z - up.z
		if sqrt(dx * dx + dz * dz) <= float(sight) + VIS_SIGHT_COMPENSATION:
			return true
	return false


## 把转发命令的终态登记到调试端点命令历史，供副官按 command_id 复核。
## （仅本地调用，不是 RPC；@rpc 注解属于下方的 _rpc_command。）
func _record_command_terminal(command_id: String, op: String, issuer: Node,
		subject: String, scene: String, status: String, reason: String,
		artifact_id := "") -> void:
	if command_id.is_empty():
		return
	var dbg = get_node_or_null("/root/DebugControlServer")
	if dbg == null or not dbg.has_method("record_command"):
		return
	dbg.record_command(command_id, op, str(issuer.name), subject, scene,
		status, reason, artifact_id)


func _notify_adjutant_player_override(issuer: Node, units: Array) -> void:
	# 玩家命令的权威落点在局服。客户端 DCS 自己 notify 进不了 runner（它扫 24612）。
	# 副官命令走局服 DCS 且带 `_adjutant_executing`，不会进这条 RPC。
	var dbg = get_node_or_null("/root/DebugControlServer")
	if dbg == null or not dbg.has_method("notify_player_override") or issuer == null:
		return
	var names: Array = []
	for unit in units:
		if unit != null and is_instance_valid(unit):
			names.append(str(unit.name))
	if names.is_empty():
		return
	dbg.notify_player_override(str(issuer.name), names)


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
	# 副官来源摘前缀（副官命令不是玩家手动命令；见 ADJUTANT_SOURCE_MARKER）。
	# 必须在任何 extra 协议解析（produce/build 的 scene|cmd_id）**之前**摘干净。
	var from_adjutant := str(extra).begins_with(ADJUTANT_SOURCE_MARKER)
	var extra_clean := str(extra)
	if from_adjutant:
		extra_clean = extra_clean.substr(ADJUTANT_SOURCE_MARKER.length())
	var slot := NetSession.slot_of(multiplayer.get_remote_sender_id())
	var players := get_tree().get_nodes_in_group("players")
	if slot < 0 or slot >= players.size():
		print("[CMD][服务器] 拒绝: 槽位无效 slot=%d" % slot)
		return
	var issuer = players[slot]
	if issuer == null or issuer.get_script() != HumanScript:
		print("[CMD][服务器] 拒绝: issuer 非人类玩家 slot=%d" % slot)
		return
	var units: Array = []
	for path in paths:
		var unit = _match.get_node_or_null(NodePath(path))
		# 客户端和服务器的根节点路径可能不同（例如 /root/Online/Match
		# 与 /root/Match）。命令协议以全局 Unit 名称兜底解析，归属仍由
		# issuer 严格校验，避免跨玩家操控。
		if unit == null:
			var wanted_name := String(path).get_file()
			for candidate in get_tree().get_nodes_in_group("units"):
				if candidate.name == wanted_name and candidate.get_parent() == issuer:
					unit = candidate
					break
		if unit != null and is_instance_valid(unit) and unit.get_parent() == issuer:
			units.append(unit)
	if op == "produce":
		# extra 协议：scene_path[|command_id]；command_id 由客户端生成用于复核关联。
		var extra_parts: PackedStringArray = extra_clean.split("|")
		var produce_scene := str(extra_parts[0])
		var produce_command_id := str(extra_parts[1]) if extra_parts.size() > 1 else ""
		if units.is_empty() or produce_scene.is_empty():
			print("[CMD][服务器] produce 拒绝: units=%d extra='%s' paths=%s" % [
				units.size(), extra_clean, paths])
			return
		var queue = units[0].find_child("ProductionQueue")
		if queue == null:
			print("[CMD][服务器] produce 拒绝: %s 无 ProductionQueue" % units[0].name)
			return
		var produced = queue.produce(load(produce_scene))
		var receipt: Dictionary = queue.get_last_result() if queue.has_method("get_last_result") else {}
		print("[CMD][服务器] produce %s element=%s receipt=%s" % [
			produce_scene, str(produced != null), str(receipt)])
		var item_id := ""
		if receipt.get("item") is Dictionary:
			item_id = str(receipt["item"].get("item_id", ""))
		_record_command_terminal(produce_command_id, "produce", issuer, str(units[0].name),
			produce_scene, str(receipt.get("status", "")),
			str(receipt.get("reason", "")) if receipt.has("reason") else "", item_id)
		return
	if op == "place_structure":
		# 人类玩家放置建筑（复核 2026-08-31：此前傀儡端 Place 只在本地生成, 服务器毫不知情）。
		var placement_runtime = _match.get_node_or_null("StructurePlacementRuntime")
		if placement_runtime == null or units.is_empty() or extra_clean.is_empty():
			print("[CMD][服务器] place_structure 拒绝: runtime/参数缺失")
			return
		# extra 协议：scene_path|yaw[|command_id]；command_id 由客户端生成用于复核关联。
		var parts: PackedStringArray = extra_clean.split("|")
		var yaw: float = float(parts[1]) if parts.size() > 1 else 0.0
		var build_command_id := str(parts[2]) if parts.size() > 2 else ""
		var structure_transform := Transform3D(
			Basis.IDENTITY.rotated(Vector3.UP, yaw), destination
		)
		var place_result: Dictionary = placement_runtime.Place(
			issuer, load(parts[0]), structure_transform, {}
		)
		var place_ok := bool(place_result.get("accepted", false))
		print(
			"[CMD][服务器] place_structure accepted=",
			place_ok,
			" issue=",
			str(place_result.get("primary_issue", ""))
		)
		if place_ok:
			placement_runtime.AssignBuilders(
				units, place_result["structure"], issuer, place_result["displaced_unit_ids"]
			)
		var structure_node = place_result.get("structure")
		_record_command_terminal(build_command_id, "build", issuer,
			"|".join(units.map(func(u): return str(u.name))), str(parts[0]),
			"Accepted" if place_ok else "Rejected",
			str(place_result.get("primary_issue", "")),
			str(structure_node.name) if structure_node != null and is_instance_valid(structure_node) else "")
		return
	if op == "repair_structure":
		# 联机客户端的"维修"必须由**权威端**执行（2026-09-12）：
		# 此前客户端只本地 `set_repairing`，而 Structure._process 的按秒回血/扣费
		# 需要 `player._economy_runtime`（客户端由快照结算），且 10Hz 快照立刻把 hp
		# 覆盖回去 → 玩家看到的就是"点了维修没反应"。权威端置位后，
		# 回血与扣费本来就走 Structure._process，客户端从快照看到 hp 上涨。
		var affected := 0
		for unit in units:
			if unit.has_method("is_repairing") and unit.has_method("set_repairing"):
				unit.set_repairing(not unit.is_repairing())
				affected += 1
				print("[CMD][服务器] repair_structure %s -> %s" % [
					unit.name, "维修中" if unit.is_repairing() else "已停止"])
		if affected == 0:
			print("[CMD][服务器] repair_structure 拒绝: 无可用建筑")
		return
	if op == "sell_structure":
		# 同 repair：出售必须由权威端拆毁并退款（返还半价走 ConstructionRefund）。
		var sold := 0
		for unit in units:
			if unit.has_method("sell"):
				unit.sell()
				sold += 1
		if sold == 0:
			print("[CMD][服务器] sell_structure 拒绝: 无可用建筑")
		else:
			print("[CMD][服务器] sell_structure 出售 %d 座建筑" % sold)
		return
	if units.is_empty():
		print("[CMD][服务器] 拒绝: 单位解析为空 op=%s paths=%s" % [op, paths])
		return
	var gateway = issuer.find_child("UnitCommandGateway")
	if gateway == null:
		print("[CMD][服务器] 拒绝: 人类玩家无 UnitCommandGateway")
		return
	var target = _match.get_node_or_null(NodePath(target_path)) if target_path != "" else null
	if target == null and target_path != "":
		var wanted_target_name := String(target_path).get_file()
		for candidate in get_tree().get_nodes_in_group("units"):
			if candidate.name == wanted_target_name:
				target = candidate
				break
		if target == null:
			for candidate in get_tree().get_nodes_in_group("resource_units"):
				if candidate.name == wanted_target_name:
					target = candidate
					break
	if target == null and op == "gather" and not units.is_empty():
		# 最后一道兼容兜底：不同端地图节点路径可能不同，按发起者
		# 单位最近的同类资源选择目标，避免客户端命令静默丢失。
		var origin: Vector3 = units[0].global_position
		var nearest := INF
		for candidate in get_tree().get_nodes_in_group("resource_units"):
			# 显式 float：distance_to 在此上下文返回 Variant，:= 无法推断类型，
			# 会让整个 NetSync.gd 解析失败（表现为联机黑屏且 NetSync 缺失）。
			var d: float = candidate.global_position.distance_to(origin)
			if d < nearest:
				nearest = d
				target = candidate
	print("[CMD][服务器] 应用 op=%s units=%d dest=%s" % [op, units.size(), destination])
	# 副官自己的命令**不是**玩家手动命令：不收回托管、不发 override 事件。
	# （2026-09-21 事故：傀儡端副官命令经这条 RPC 落地，被当成玩家接管，
	#  受令单位全部离开 AI 托管，军事/侦察轨失去执行者，全军在家攒兵。）
	if not from_adjutant:
		_notify_adjutant_player_override(issuer, units)
	match op:
		"move":
			var move_result: Dictionary = gateway.MoveUnits(units, destination, issuer)
			var child_names: Array = units[0].get_children().map(
				func(c): return str(c.name)
			)
			print(
				"[CMD][服务器] MoveUnits 结果: ",
				move_result,
				" | unit=", units[0].name,
				" children=", child_names,
				" FindChild(Movement)=",
				units[0].find_child("Movement", false, false) != null
			)
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
				var gather_result: Dictionary = gateway.GatherResources(units, target, issuer)
				print("[CMD][服务器] GatherResources 结果: ", gather_result)
		"construct":
			if target != null:
				gateway.ConstructUnits(units, target, issuer)
		"cancel_construct":
			if target != null:
				gateway.CancelConstruction(target, issuer)
		"set_engagement_stance":
			var stance_result: Dictionary = gateway.SetEngagementStance(units, extra_clean, issuer)
			print("[CMD][服务器] SetEngagementStance 结果: ", stance_result)
		"set_fire_policy":
			var policy_result: Dictionary = gateway.SetFirePolicy(units, extra_clean, issuer)
			print("[CMD][服务器] SetFirePolicy 结果: ", policy_result)
		"cancel_produce":
			# 客户端取消生产（extra = item_id 或 "*" 表示全部）：权威端执行，
			# 队列变化经快照回到客户端 HUD（2026-09-14：此前客户端没有转发分支，点了没反应）。
			if units.is_empty():
				print("[CMD][服务器] cancel_produce 拒绝: 单位解析为空")
				return
			var cancel_queue = units[0].find_child("ProductionQueue")
			if cancel_queue == null:
				print("[CMD][服务器] cancel_produce 拒绝: %s 无 ProductionQueue" % units[0].name)
				return
			if extra == "*":
				cancel_queue.cancel_all()
				print("[CMD][服务器] cancel_produce 全部取消（%s）" % units[0].name)
			else:
				var cancel_element = null
				for element in cancel_queue.get_elements():
					if str(element.item_id) == extra:
						cancel_element = element
						break
				if cancel_element == null:
					print("[CMD][服务器] cancel_produce 未找到 item=%s（%s）" % [extra, units[0].name])
					return
				cancel_queue.cancel(cancel_element)
				print("[CMD][服务器] cancel_produce 取消 item=%s（%s）" % [extra, units[0].name])
		"set_rally_point":
			var rally_runtime = _match.get_node_or_null("RallyPointRuntime")
			if rally_runtime == null:
				print("[CMD][服务器] set_rally_point 拒绝: 无 RallyPointRuntime")
				return
			var rally_point_result: Dictionary = rally_runtime.SetPosition(units, destination, issuer)
			print("[CMD][服务器] set_rally_point 结果: ", rally_point_result)
		"set_rally_target":
			var rally_target_runtime = _match.get_node_or_null("RallyPointRuntime")
			if rally_target_runtime == null or target == null:
				print("[CMD][服务器] set_rally_target 拒绝: runtime/目标缺失")
				return
			var rally_target_result: Dictionary = rally_target_runtime.SetTarget(units, target, issuer)
			print("[CMD][服务器] set_rally_target 结果: ", rally_target_result)
		"clear_rally_point":
			var rally_clear_runtime = _match.get_node_or_null("RallyPointRuntime")
			if rally_clear_runtime == null:
				print("[CMD][服务器] clear_rally_point 拒绝: 无 RallyPointRuntime")
				return
			var rally_clear_result: Dictionary = rally_clear_runtime.Clear(units, issuer)
			print("[CMD][服务器] clear_rally_point 结果: ", rally_clear_result)
		"cast_skill":
			# 客户端技能施放（extra = skill_id；target 为空 = 自身技能）：权威端执行（2026-09-14）。
			var skill_result: Dictionary = gateway.CastSkill(units, extra_clean, issuer, target)
			print("[CMD][服务器] CastSkill 结果: ", skill_result)
		"cast_skill_ground":
			var skill_ground_result: Dictionary = gateway.CastSkillGround(
				units, extra_clean, destination, issuer
			)
			print("[CMD][服务器] CastSkillGround 结果: ", skill_ground_result)


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
func _rpc_spawn(scene_path: String, parent_path: String, xf: Transform3D, hp: float,
		unit_name := "") -> void:
	if NetSession.is_server():
		return
	_spawn_unit(scene_path, parent_path, xf, hp, "", unit_name)


func _spawn_unit(
	scene_path: String, parent_path: String, xf: Transform3D, hp: float,
	forced_path: String = "", unit_name: String = ""
) -> void:
	var parent := _match.get_node_or_null(NodePath(parent_path))
	if parent == null or scene_path.is_empty():
		return
	var packed = load(scene_path)
	if packed == null:
		return
	var unit = packed.instantiate()
	# 命名必须与服务器一致：客户端上送的命令路径用本机节点名，服务器按同一路径解析；
	# 若客户端沿用场景默认名（Barracks）而服务器叫 Unit_N，服务器会解析不到单位并拒绝
	# （2026-09-10「联机局没法造兵」的根因：produce 拒绝 units=0）。
	var authoritative_name := ""
	if forced_path != "":
		var np := NodePath(forced_path)
		authoritative_name = String(np.get_name(np.get_name_count() - 1))
	elif unit_name != "":
		authoritative_name = unit_name
	if authoritative_name != "":
		unit.name = authoritative_name
	parent.add_child(unit)
	if forced_path != "":
		if str(_match.get_path_to(unit)) != forced_path:
			push_warning(
				"联机: 对账生成路径不符 %s（实际 %s），已移除" % [forced_path, _match.get_path_to(unit)]
			)
			unit.queue_free()
			return
	unit.global_transform = xf
	# 物理插值开启后，进树后的瞬移需显式 reset，避免从原点滑到出生位的拖影。
	unit.reset_physics_interpolation()
	if "hp" in unit and hp != null:
		_apply_authoritative_hp(unit, float(hp))
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


## 对局结束: 服务器广播结果并回收, 客户端回主菜单(2026-08-31 黑屏修复)。
func _on_match_finished(result: String) -> void:
	# 单人练习房：不以胜负结束，且不回收专用服（设计师需求 2026-09-04）。
	# 否则单人局开局即被判胜利 → 广播 → 5 秒后专用服退出。
	if NetSession.is_solo_practice():
		print("[对局] 单人练习房：跳过结算广播（", result, "），对局继续")
		return
	if not NetSession.is_networked():
		return
	if NetSession.is_server():
		# 广播给客户端（`rpc()` 不会在服务器本机执行，房主自己也必须显式走一次）。
		_rpc_match_over.rpc(result)
		if NetSession.is_dedicated_server():
			print("[对局] 已广播结果: ", result, ", 5 秒后回收专用服")
			await get_tree().create_timer(5.0).timeout
			get_tree().quit(0)
		else:
			# 本机房主（单机 / 联机房主）：只回主菜单，**不回收进程**
			#（旧实现会 `quit(0)`；此前被"恒判单人练习房"的早退挡住，从未暴露 — 2026-09-14）。
			print("[对局] 已广播结果: ", result, "（本机房主，不回收进程）")
			_rpc_match_over(result)
	else:
		_rpc_match_over(result)


@rpc("authority", "reliable")
func _rpc_match_over(result: String) -> void:
	# 幂等：服务器广播与客户端本地推断可能先后到达，只允许执行一次
	#（否则出现两个 3 秒计时器、两次切场景 — 2026-09-14）。
	if _match_over_handled:
		return
	_match_over_handled = true
	NetSession._match_started = false
	get_tree().paused = false
	NetSession._set_status("对局结束: " + result + "，即将返回主菜单")
	print("[对局] 收到结算: ", result, "，3 秒后返回主菜单")
	await get_tree().create_timer(3.0).timeout
	# 回主菜单前断开会话：避免"人还在房间 / 本机 server 残留"（2026-09-14）。
	NetSession.disconnect_if_networked()
	get_tree().change_scene_to_file.call_deferred("res://source/main-menu/Main.tscn")


## 命令可视化广播（纯表现层，2026-09-10）：权威端把一次命令（含副官指令）广播给表现层，
## 客户端据此在目标点画信标、从受令单位画路径。不改快照结构、不改任何玩法状态；
## unreliable 语义不需要——丢一条只少一次视觉指示，故用 reliable 保证指示完整。
func broadcast_order_visual(payload: Dictionary) -> void:
	# 【2026-09-11 修正：发起方本机也必须看到指示】
	# 原实现在"联机 且 非权威端"（正是**玩家客户端**）时直接什么都不做，
	# 于是"从客户端 DCS 发出的副官命令"在屏幕上**完全没有指示** ——
	# 用户实测："AI 副官在指挥部队，但看不到任何指挥动画"。
	# 命令可视化是纯表现层，谁发起谁就该看到，不能依赖"只有房主才广播"。
	MatchSignals.order_visualized.emit(payload)
	if not NetSession.is_networked():
		return
	if NetSession.is_server():
		_rpc_order_visual.rpc(payload)


@rpc("authority", "reliable")
func _rpc_order_visual(payload: Dictionary) -> void:
	if NetSession.is_server():
		return
	MatchSignals.order_visualized.emit(payload)


## ---------------------------------------------------------------------------
## 表现事件广播（纯表现层，2026-09-11）
##
## 为什么必须补这条通道（用户报"看不到建造动画 / 看不到交火特效与音效 / UI 没进度"）：
## 联机客户端是**傀儡**——`Unit._set_action` 主动丢弃 action（Unit.gd:529-532），
## 快照也只带 pos/yaw/hp/stance/fire_policy，于是下列**纯表现**在客户端全部缺失：
##   - `attack_fired` 只在权威端由 ProjectileRuntime 发（真实创建投射物时）→ 客户端无开火动画/音效；
##   - 采集火花由本地 Action 驱动（CollectingResourcesWhileInRange）→ 客户端无 Action 即无火花。
## 这里沿用 `broadcast_order_visual` 的成熟模式：**只广播表现事件**，
## 不复制第二份权威状态、不改快照结构、不参与任何玩法结算。
##
## 只发给客户端：房主/单机本地已有 Action 驱动表现，再补一次会变成"双份音效/动画"。
## ---------------------------------------------------------------------------
func broadcast_presentation(kind: String, path: String, payload: Dictionary = {}) -> void:
	if not NetSession.is_networked() or not NetSession.is_server():
		return
	var event := payload.duplicate()
	event["kind"] = kind
	event["path"] = path
	_rpc_presentation.rpc(event)


@rpc("authority", "reliable")
func _rpc_presentation(event: Dictionary) -> void:
	if NetSession.is_server():
		return
	var unit := _match.get_node_or_null(NodePath(str(event.get("path", ""))))
	if unit == null or not is_instance_valid(unit):
		# 事件早于生成（可靠 RPC 与生成顺序不保证）：丢弃即可 ——
		# 施工/生产进度走的是幂等快照，会自动补上；开火/采集是一次性表现，少一帧不致命。
		return
	match str(event.get("kind", "")):
		"fired":
			if unit.has_method("present_fired"):
				# 整个 event 传进去：其中可能带权威端算好的 `aim`（真实弹道落点）。
				unit.present_fired(event)
		"gather":
			if unit.has_method("present_gather"):
				unit.present_gather(bool(event.get("active", false)))
		_:
			pass
