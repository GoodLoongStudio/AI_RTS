class_name MatchHistoryHook
extends Node

## 真实对局的"记录入口"：把 `MatchSignals` 的起止事件接到 `MatchReportRecorder`。
##
## 挂载方式：`MatchReportStore._install_match_hook()` 在 `FeatureFlags.record_match_history`
## 为真时把本节点创建成 `/root/MatchReportStore` 的子节点。Store 是 autoload，
## 所以本节点跨场景存活 —— 信号只连一次，每局开始时**新建**一个 recorder。
##
## 三条纪律（与 recorder / schema 一致）：
## 1. **只接线，不推断。** 对局层读得到的字段（模式 / 地图路径 / 玩家身份 / 成长等级）
##    如实写入；读不到的一律 `null`，由 `data_completeness` 如实汇总。绝不用"默认值"
##    把缺失伪装成数据 —— 一个假的 `difficulty: "normal"` 比 `null` 危险得多。
## 2. **不碰玩法。** 所有回调只创建/结束记录器与读快照，不调用任何影响对局的 API。
## 3. **失败不冒泡。** 找不到对局根节点时只 `push_warning` 并放弃本局；
##    recorder 的 `contribute()` 是玩法侧主动推进权威数字的扩展点，不在本文件里"造数"。
##
## 已知边界（诚实记录，别把它当成"已完备"）：
## - `match_id` 由本地生成（`local-<时间戳>`），**不是**服务器下发的权威编号；
##   它的用途只是让同一局的两份报告可被 `MatchReportStore` 去重/追溯。
## - `difficulty` / `adjutant.type` / 逐单位击杀与伤害：对局层目前没有权威来源，
##   报告里是 `null`，完整度会很低。等玩法系统用 `contribute()` 推进来即可。

## 本地生成的 match_id 前缀：一眼能看出"这不是协议字段"。
const LOCAL_MATCH_ID_PREFIX := "local-"

var _recorder: MatchReportRecorder = null
## 上一局是否已收尾且尚未看到新的 `match_started`（2026-09-27 修）。
## 用途有两个：
## ① 对局在 `Match._ready` 期间就判出胜负时，`match_finished_*` 会比 `match_started`
##    先发 —— 此时 recorder 还没建，直接返回会把整局丢掉。标志为 false 说明这是
##    "开局前就结束"的真局：就地建 recorder 再收尾，保证打过的局一定有报告。
## ② 标志为 true 说明上一局已落盘，这时又来的结算只是重复上报（玩家连点/结算重放），
##    直接忽略 —— 既不串味到下一局，也不会把统计翻倍。
var _match_finished_awaiting_start := false
var _match_id := ""
var _connected := false
## 本进程内已发出的对局编号序号（见 `_make_match_id()` 的说明）。
var _match_seq := 0


func _ready() -> void:
	_connect_signals()


func _exit_tree() -> void:
	if not _connected:
		return
	_connected = false
	_bind_all(false)


# ==================== 信号接线 ====================

func _connect_signals() -> void:
	if _connected:
		return
	if get_node_or_null("/root/MatchSignals") == null:
		return
	_connected = true
	_bind_all(true)


func _bind_all(on: bool) -> void:
	var signals := get_node_or_null("/root/MatchSignals")
	if signals == null:
		return
	_bind(signals, "match_started", _on_match_started, on)
	_bind(signals, "match_aborted", _on_match_aborted, on)
	_bind(signals, "match_finished_with_victory", _on_match_victory, on)
	_bind(signals, "match_finished_with_defeat", _on_match_defeat, on)


func _bind(source: Node, signal_name: String, target: Callable, on: bool) -> void:
	if not source.has_signal(signal_name):
		return
	if on and not source.is_connected(signal_name, target):
		source.connect(signal_name, target)
	elif not on and source.is_connected(signal_name, target):
		source.disconnect(signal_name, target)


# ==================== 对局事件 ====================

func _on_match_started() -> void:
	# `match_started` 在对局 `_ready()` 末尾发出。此时地图与玩家都挂好了，但仍然
	# 延后一帧再动手：不在别人的 `_ready()` 里改节点树（本节点的子节点归属是 store，
	# 而 recorder 要挂到对局根上，属于跨树操作）。
	call_deferred("_begin_recording")


func _on_match_aborted() -> void:
	# 玩家从对局内菜单退出。Menu 会等 1.74s 再换场景，我们立即收尾，来得及。
	_finish("aborted", "玩家中途退出对局")


func _on_match_victory() -> void:
	_finish("victory")


func _on_match_defeat() -> void:
	_finish("defeat")


# ==================== 录制生命周期 ====================

func _begin_recording() -> void:
	if not is_inside_tree():
		return
	# 上一局还没收尾就开了新的一局（重开/异常）：先把旧的按"中止"落盘，不丢已采数据。
	if is_instance_valid(_recorder) and _recorder.active:
		_finish("aborted", "上一局在新对局开始前未正常结束")
	_recorder = null
	var root := _match_root()
	if root == null:
		push_warning("[MatchHistoryHook] 未找到对局根节点，本局不写入历史。")
		return
	_match_id = _make_match_id()
	var recorder := MatchReportRecorder.new()
	recorder.name = "MatchReportRecorder"
	# recorder._local_player() 用 get_parent() 当对局根，所以必须挂在**对局根**下，
	# 而不是本节点（本节点的父是 autoload store）。
	root.add_child(recorder)
	recorder.begin(_context())
	_recorder = recorder
	_match_finished_awaiting_start = false


func _finish(result: String, reason: String = "") -> void:
	if not is_instance_valid(_recorder):
		if _match_finished_awaiting_start:
			# 上一局已收尾后的重复上报：忽略，避免统计翻倍/串味。
			print("[MatchHistoryHook] 忽略重复结算上报：%s（上一局已落盘）" % result)
			return
		# 开局前就结束的真局：就地建 recorder 再收尾（报告时长会很短，但数据是真的）。
		print("[MatchHistoryHook] 结算早于开局：就地建档并收尾（%s）" % result)
		_begin_recording()
		if not is_instance_valid(_recorder):
			return
	# 立刻"摘掉"引用：finish() 内部会 upsert 并触发 reports_changed，
	# 重入时不应再看到这个 recorder。
	var recorder := _recorder
	_recorder = null
	if not recorder.active:
		return
	# 收局快照（真实值）。growth_before 已在 _context() 里写入。
	var after := _growth_snapshot()
	recorder.context["growth_after"] = after
	var before: Variant = recorder.context.get("growth_before", null)
	recorder.context["growth_spent_this_match"] = _spent_delta(before, after)
	_contribute_authoritative(recorder)
	recorder.finish(result, reason)
	_match_finished_awaiting_start = true
	# 收尾后立刻把 recorder 摘掉：它挂在**对局根**下，若一个 Match 实例里连打多局
	# （重开），死掉的 recorder 会一局一个地堆在场景树里。
	if is_instance_valid(recorder):
		recorder.queue_free()
	# 详细报告是唯一权威；画像读的是它的摘要。upsert 不会自动同步，这里显式推一次。
	var store := get_node_or_null("/root/MatchReportStore")
	if store != null and store.has_method("sync_growth_store"):
		store.call("sync_growth_store")


## 收局时把对局层**真实可读**的权威数字推进报告（recorder.contribute 语义：
## 只补读得到的，读不到就什么都不写，绝不用默认值充数）。
func _contribute_authoritative(recorder: MatchReportRecorder) -> void:
	var root := _match_root()
	if root == null:
		return
	var economy := root.get_node_or_null("EconomyRuntime")
	if economy == null or not economy.has_method("GetSnapshot"):
		return
	var player: Variant = root.call("get_local_player")
	if player == null:
		return
	var snapshot: Variant = economy.call("GetSnapshot", player)
	if not snapshot is Dictionary:
		return
	var snapshot_dict: Dictionary = snapshot
	for pair in [["resource_a", "overview.final_resources.resource_a"],
			["resource_b", "overview.final_resources.resource_b"],
			["resource_a", "economy.totals.remaining.resource_a"],
			["resource_b", "economy.totals.remaining.resource_b"]]:
		var value: Variant = snapshot_dict.get(str(pair[0]), null)
		if value == null or float(value) < 0.0:
			continue
		var section_path: PackedStringArray = str(pair[1]).split(".")
		recorder.contribute(section_path[0], "%s.%s" % [section_path[1], section_path[2]], float(value))


# ==================== 从对局层读真实字段 ====================

## 对局根节点 = 当前场景。用 `current_scene` 而不是硬编码路径：单机 / 联机 /
## 专用服 / 测试场景的根不同，但都带一个 `Players` 子节点（`Match.tscn` 结构）。
func _match_root() -> Node:
	var tree := get_tree()
	if tree == null:
		return null
	var scene := tree.current_scene
	if scene == null:
		return null
	if scene.get_node_or_null("Players") == null:
		return null
	return scene


## 组装 recorder 的上下文。**只放真实读到的值**，读不到就是 null。
func _context() -> Dictionary:
	var map_path := _selected_map_path()
	var map_name: Variant = null
	var map_path_value: Variant = null
	if not map_path.is_empty():
		map_name = map_path.get_file().get_basename()
		map_path_value = map_path
	return {
		"player_id": _local_player_id(),
		"match_id": _match_id,
		"mode": _mode(),
		# 副官类型没有权威来源：HUD 上挂的是"岚"，但那是 UI 呈现，不是本局配置。
		"adjutant": {"type": null, "level": null},
		"victory_condition": null,
		"growth_before": _growth_snapshot(),
		"map": _map_context(map_name, map_path_value),
		# 难度：读对局设置里 AI 玩家真正配置的值（PlayerSettings.difficulty）。
		# 多人/AI 难度不一致时取最难的，避免"只写第一个玩家"。
		"difficulty": _difficulty(),
	}


## 地图上下文：名称/路径之外补上对局层真实可读的尺寸、玩家数与地图种子。
## 读不到就 null —— 不拿"256"之类的常见值充数。
func _map_context(map_name: Variant, map_path_value: Variant) -> Dictionary:
	var out := {"name": map_name, "path": map_path_value}
	var root := _match_root()
	if root == null:
		return out
	var map_node := root.get_node_or_null("Map")
	if map_node != null:
		var size_value = map_node.get("size")
		if size_value is Vector2:
			out["size"] = [int((size_value as Vector2).x), int((size_value as Vector2).y)]
		var seed_value = map_node.get("map_seed")
		if seed_value != null and str(seed_value) != "":
			out["seed"] = str(seed_value)
	var players: Array = root.get_tree().get_nodes_in_group("players")
	if not players.is_empty():
		out["players"] = players.size()
	return out


## 难度口径：对局设置里各 AI 玩家 difficulty 的最大值（0/1/2 = 易/普通/难）。
## 没有 AI 玩家时返回 null，不写"普通"。
func _difficulty() -> Variant:
	var root := _match_root()
	if root == null:
		return null
	var settings = root.get("settings")
	if settings == null or not (settings.get("players") is Array):
		return null
	var best: Variant = null
	for entry in settings.players:
		if not entry is Resource:
			continue
		var value = entry.get("difficulty")
		if value == null:
			continue
		var level := int(value)
		if best == null or level > int(best):
			best = level
	return best


## 本局用的地图：`NetSession.selected_map_path` 是玩家在大厅/开局时真正选定的那张。
## 读不到就空串（调用方会转成 null），不猜默认地图。
func _selected_map_path() -> String:
	var net := get_node_or_null("/root/NetSession")
	if net == null:
		return ""
	return str(net.get("selected_map_path"))


## 模式：读 NetSession 的真实会话状态；既非联机也非单人练习时返回 null。
func _mode() -> Variant:
	var net := get_node_or_null("/root/NetSession")
	if net == null:
		return null
	if bool(net.call("is_networked")):
		return "online"
	if bool(net.call("is_solo_practice")):
		return "skirmish"
	return null


## 玩家身份：设备 ID（跨对局稳定，画像聚合"同一玩家的多场报告"靠它）。
## 读不到时退回 GrowthStore 的本地档案名，再不行才是字面量。
func _local_player_id() -> String:
	var net := get_node_or_null("/root/NetSession")
	if net != null:
		var device_id := str(net.get("device_id"))
		if not device_id.is_empty():
			return device_id
	return "local_player"


## 成长快照：直接抄 `GrowthStore.state` 的真实字段，不做任何换算。
## GrowthStore 缺席（测试/裁剪构建）时给全 null —— 空字段会被完整度统计抓住。
func _growth_snapshot() -> Dictionary:
	var growth := get_node_or_null("/root/GrowthStore")
	if growth == null:
		return {"levels": null, "available_points": null, "earned_total": null,
			"spent_total": null}
	var state: Variant = growth.get("state")
	if not (state is Dictionary):
		return {"levels": null, "available_points": null, "earned_total": null,
			"spent_total": null}
	var levels: Variant = (state as Dictionary).get("levels", null)
	return {
		"levels": (levels as Dictionary).duplicate(true) if levels is Dictionary else null,
		"available_points": (state as Dictionary).get("available_points", null),
		"earned_total": (state as Dictionary).get("earned_total", null),
		"spent_total": (state as Dictionary).get("spent_total", null),
	}


## 本局花掉的成长点 = 收局 spent_total − 开局 spent_total。
## 只有两次快照都在、且差值为正时才给数字：差值为 0 说明本局没加点（给 0 是事实，
## 但字段语义是"本局花费"，0 与"没测到"无法区分 —— 所以 0 也给 0，负数/缺失给 null）。
func _spent_delta(before: Variant, after: Variant) -> Variant:
	if not (before is Dictionary) or not (after is Dictionary):
		return null
	var b: Variant = (before as Dictionary).get("spent_total", null)
	var a: Variant = (after as Dictionary).get("spent_total", null)
	if b == null or a == null:
		return null
	var delta := int(a) - int(b)
	if delta < 0:
		# 花费不可能倒扣：说明两次快照不是同一份存档（重载/重置），不编造。
		return null
	return delta


## 本地对局编号。这是**我们自己发的号**，不是协议字段 —— 前缀已经说明了这点。
##
## ⚠️ 必须带序号：`Time.get_datetime_string_from_system()` 只有**秒**级精度，同一秒内连开
## 两局会发出同一个 match_id；而 `MatchReportStore._find_duplicate()` 的规则是
## "同一玩家 + 同一 match_id ⇒ 同一局"，于是**第二局会静默覆盖第一局**（不报错，数据少一局）。
## 实测踩过：连开两局，报告数停在 1。
func _make_match_id() -> String:
	_match_seq += 1
	var stamp := Time.get_datetime_string_from_system()
	stamp = stamp.replace("-", "").replace(":", "").replace("T", "").replace(" ", "")
	return "%s%s-%d" % [LOCAL_MATCH_ID_PREFIX, stamp, _match_seq]
