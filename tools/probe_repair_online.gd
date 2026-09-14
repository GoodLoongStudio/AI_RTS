extends Node

## 联机「维修 / 出售」端到端探针（客户端进程）。
##
## 用法：先在另一个进程起专用服，并把 stdout 落盘
##   godot --headless --path . -- --server --port 24682 > server.log 2>&1 &
## 再跑本场景（由 probe_repair_online_boot.gd 引导，驱动挂在 root 上）
##   godot --headless --path . res://tools/probe_repair_online.tscn > client.log 2>&1
##
## 它验证的是**联机模式下维修/出售真的被转发到权威端**：
##   客户端（傀儡）→ UnitActionsController._apply_structure_target_mode
##   → NetSession.should_forward_commands() 分支 → NetSync.forward_command
##   → 服务器 NetSync.gd 的 `if op == "repair_structure" / "sell_structure"`
## 服务器侧的铁证是专用服 stdout 里的 `[CMD][服务器] repair_structure ...`，
## 客户端侧的铁证是本文件打印的 `[PROBE] >>> 已下发 ...`。
##
## 两个必须遵守的点（都是踩过的坑）：
##  1) 驱动必须挂在 root（见 boot 脚本），否则开局换场景会把本节点释放、协程静默死掉；
##  2) passive_ai_test 局很快判"胜利"并拆掉 Match，所以开局后**立刻**动作，
##     全程只用短等待，并带看门狗兜底。

const PHASE_TIMEOUT_SEC := 120.0

var _failures := 0
var _finished := false


func _check(cond: bool, msg: String) -> void:
	if cond:
		print("[PROBE] OK   %s" % msg)
		return
	_failures += 1
	print("[PROBE] FAIL %s" % msg)


func _wait(seconds: float) -> void:
	# 用 Timer 而不是 process_frame 空转：场景切换/暂停语义下更稳。
	await get_tree().create_timer(seconds).timeout


func _ready() -> void:
	get_tree().create_timer(PHASE_TIMEOUT_SEC).timeout.connect(_on_watchdog)
	await _run()


func _on_watchdog() -> void:
	if _finished:
		return
	_finished = true
	print("[PROBE] FAIL 看门狗超时（%.0fs）——探针协程未收尾" % PHASE_TIMEOUT_SEC)
	print("[PROBE] ===== 结束：%d failure(s) =====" % (_failures + 1))
	get_tree().quit(1)


## 开局后 Match 可能挂在 root 下，也可能成为 current_scene；两边都找一次。
func _find_match() -> Node:
	var direct := get_tree().root.get_node_or_null("Match")
	if direct != null:
		return direct
	var current := get_tree().current_scene
	if current != null and current.has_method("get_local_player"):
		return current
	for child in get_tree().root.get_children():
		if child.has_method("get_local_player"):
			return child
	return null


func _run() -> void:
	# ---- 1) 连本地专用服 ----
	print("[PROBE] 阶段1：连接专用服 127.0.0.1:24682")
	NetSession.join("127.0.0.1", 24682)
	var deadline := Time.get_ticks_msec() + 15000
	while not NetSession.is_networked() and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	_check(NetSession.is_networked(), "应连上专用服 127.0.0.1:24682")
	if not NetSession.is_networked():
		_finish()
		return

	# ---- 2) 开局 ----
	print("[PROBE] 阶段2：请求开局并等待 Match")
	NetSession.start_solo(true)
	deadline = Time.get_ticks_msec() + 90000
	var match_node: Node = null
	while Time.get_ticks_msec() < deadline:
		match_node = _find_match()
		if match_node != null:
			break
		await get_tree().process_frame
	_check(match_node != null, "联机对局应出现 Match")
	if match_node == null:
		_finish()
		return

	deadline = Time.get_ticks_msec() + 20000
	var player: Node = null
	while Time.get_ticks_msec() < deadline:
		player = match_node.get_local_player()
		if player != null:
			break
		await get_tree().process_frame
	_check(player != null, "应能定位本地玩家")
	if player == null:
		_finish()
		return

	# ---- 3) 必须是傀儡端（否则走的是本地直执行，测不到转发）----
	_check(NetSession.should_forward_commands(), "客户端应为傀儡端（会转发命令）")
	_check(not NetSession.is_server(), "客户端不应是权威端")

	var ctl = player.get_node_or_null("UnitActionsController")
	_check(ctl != null, "Human 下应有 UnitActionsController")
	if ctl == null:
		_finish()
		return

	# 结构不要按硬编码子节点名找：客户端傀儡端的复制路径/父节点与单机不同
	# （实测 `player.get_node_or_null("Barracks")` 恒为 null）。改为从
	# `controlled_units` 组里挑，并用场景路径区分兵营 / 指挥中心。
	var structures := _collect_structures()
	_dump_structures(player, structures)
	var barracks: Node = _pick_structure(structures, "Barracks")
	var cc: Node = _pick_structure(structures, "CommandCenter")
	if barracks == null:
		barracks = structures[0] if structures.size() > 0 else null
	if cc == null:
		cc = structures[1] if structures.size() > 1 else null
	_check(barracks != null, "应能找到一座己方建筑用于维修")
	_check(cc != null, "应能找到一座己方建筑用于出售")
	if barracks == null or cc == null:
		_finish()
		return

	# _apply_structure_target_mode 的前置：必须在 controlled_units 组
	_check(barracks.is_in_group("controlled_units"), "维修目标应在 controlled_units 组")
	_check(cc.is_in_group("controlled_units"), "出售目标应在 controlled_units 组")

	# ---- 4) 维修：客户端转发 repair_structure ----
	print("[PROBE] 阶段3：维修（客户端转发）")
	# 满血会被 Structure._process 立刻停修，先打伤
	if barracks.has_method("set_hp_without_damage") and "hp_max" in barracks:
		barracks.set_hp_without_damage(barracks.hp_max * 0.5)
	await get_tree().process_frame
	ctl.begin_repair_targeting()
	_check(ctl.get_active_command_targeting() == "Repair", "begin_repair_targeting 后模式应为 Repair")
	ctl._apply_structure_target_mode(barracks, "Repair")
	print("[PROBE] >>> 已下发 repair_structure（傀儡端转发）target=%s" % barracks.name)
	await _wait(2.0)
	_check(ctl.get_active_command_targeting() == "Repair", "维修后应保持 Repair 模式（可连点下一座）")

	# ---- 5) 退出模式 ----
	# 必须放在出售**之前**：卖掉最后一座建筑会让服务器立刻结算胜负并拆掉 Match，
	# 之后本地 Human / UnitActionsController 全部 is_freed，再断言就是打在空气上
	# （实测会抛 `Nonexistent function ... in base 'previously freed'` 并吃掉整个协程）。
	print("[PROBE] 阶段4：退出模式")
	ctl.cancel_command_targeting()
	_check(ctl.get_active_command_targeting() == "", "cancel_command_targeting 后应退出模式")

	# ---- 6) 出售：客户端转发 sell_structure（放最后，之后不再触碰对局节点）----
	print("[PROBE] 阶段5：出售（客户端转发）")
	ctl.begin_sell_targeting()
	_check(ctl.get_active_command_targeting() == "Sell", "begin_sell_targeting 后模式应为 Sell")
	ctl._apply_structure_target_mode(cc, "Sell")
	print("[PROBE] >>> 已下发 sell_structure（傀儡端转发）target=%s" % cc.name)

	_finish()


## 己方建筑候选：`controlled_units` 组里所有带 `sell()` 的节点。
func _collect_structures() -> Array:
	var out: Array = []
	for node in get_tree().get_nodes_in_group("controlled_units"):
		if node is Node and node.has_method("sell"):
			out.append(node)
	return out


## 按场景文件路径 / 节点名里的关键字挑建筑（兵营 / 指挥中心）。
func _pick_structure(structures: Array, keyword: String) -> Node:
	for node in structures:
		var scene_path := str(node.scene_file_path)
		if scene_path.contains(keyword) or str(node.name).contains(keyword):
			return node
	return null


## 结构解析失败时要能一眼看出真实树形，否则只能瞎猜。
func _dump_structures(player: Node, structures: Array) -> void:
	var direct := ""
	for child in player.get_children():
		if not direct.is_empty():
			direct += ", "
		direct += _describe_node(child)
	print("[PROBE] 诊断 player=%s 直接子节点=[%s]" % [player.name, direct])
	for node in structures:
		print("[PROBE] 诊断 候选建筑 name=%s scene=%s groups=%s" % [
			node.name, node.scene_file_path, str(node.get_groups())])


func _describe_node(node: Node) -> String:
	return "%s(%s)" % [node.name, node.get_class()]


func _finish() -> void:
	if _finished:
		return
	_finished = true
	print("[PROBE] ===== 结束：%d failure(s) =====" % _failures)
	get_tree().quit(1 if _failures > 0 else 0)
