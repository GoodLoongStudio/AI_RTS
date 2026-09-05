extends Node

## 联机步兵冒烟测试（客户端进程）：
## 1) 连接本地专用服 → start_solo(true) 带 AI 开局
## 2) 校验 RA3 侧栏页签包含 步兵/兵营（共用场景 → 联机同源）
## 3) 指挥中心生产工人（NetSync 转发链路 + 新平衡配置）
## 4) 兵营生产步兵（转发 → 服务器入队 → 部署 → 复制回客户端）

const InfantryScene = preload("res://source/match/units/Infantry.tscn")
const WorkerScene = preload("res://source/match/units/Worker.tscn")
const InfantryScript = preload("res://source/match/units/Infantry.gd")

var _failures := 0


func _check(condition: bool, message: String) -> void:
	if condition:
		return
	_failures += 1
	push_error("Net infantry assertion failed: %s" % message)


func _ready() -> void:
	var tabs = load("res://source/match/hud/ra3/Ra3Sidebar.gd").TABS
	var tab_ids := []
	for tab in tabs:
		tab_ids.append(tab.get("id", ""))
	_check("infantry" in tab_ids, "侧栏应包含步兵页签（联机共用场景）")
	var structure_items = tabs[0].get("items", [])
	_check(
		structure_items.any(func(item): return "Barracks" in str(item.get("scene", ""))),
		"建筑页签应包含兵营蓝图"
	)

	NetSession.join("127.0.0.1", 24682)
	var deadline := Time.get_ticks_msec() + 15000
	while not NetSession.is_networked() and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	_check(NetSession.is_networked(), "应成功连接本地专用服")
	if not NetSession.is_networked():
		_finish()
		return

	NetSession.start_solo(true)
	deadline = Time.get_ticks_msec() + 90000
	while get_tree().get_first_node_in_group("units") == null and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	var match_node = get_tree().root.get_node_or_null("Match")
	_check(match_node != null, "联机对局应完成加载并出现 Match")
	if match_node == null:
		_finish()
		return
	deadline = Time.get_ticks_msec() + 20000
	while match_node.get_local_player() == null and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	var local_player = match_node.get_local_player()
	_check(local_player != null, "应能定位本地玩家")
	if local_player == null:
		_finish()
		return

	var command_center = local_player.get_node_or_null("CommandCenter")
	var barracks = local_player.get_node_or_null("Barracks")
	_check(command_center != null, "本地玩家应有指挥中心（开局初始单位）")
	_check(barracks != null, "passive_ai_test 局应预置已完成兵营")
	if command_center == null or barracks == null:
		_finish()
		return

	# 步兵应从兵营生产（客户端转发 → 服务器入队）
	var queue = barracks.production_queue
	_check(queue.produce(InfantryScene) == null, "联机客户端 produce 转发返回 null 属预期")

	# 等待服务器入队快照同步回客户端 + 步兵部署复制回客户端
	deadline = Time.get_ticks_msec() + 60000
	var soldier_seen := false
	while Time.get_ticks_msec() < deadline:
		await get_tree().create_timer(0.5).timeout
		for unit in get_tree().get_nodes_in_group("units"):
			if unit.get_script() == InfantryScript:
				soldier_seen = true
				break
		if soldier_seen:
			break
	_check(soldier_seen, "联机模式下步兵应经转发在服务器部署并复制回客户端")

	# 控制中心生产工人：验证既有转发链路在新平衡配置下不受影响
	var cc_queue = command_center.production_queue
	cc_queue.produce(WorkerScene)
	deadline = Time.get_ticks_msec() + 40000
	var worker_seen := false
	while Time.get_ticks_msec() < deadline:
		await get_tree().create_timer(0.5).timeout
		for unit in get_tree().get_nodes_in_group("units"):
			if str(unit.get_script().resource_path).ends_with("Worker.gd"):
				worker_seen = true
				break
		if worker_seen:
			break
	_check(worker_seen, "指挥中心工人生产转发链路应正常（新平衡配置下）")

	print("Net infantry smoke test completed: %d failure(s)" % _failures)
	_finish()


func _finish() -> void:
	get_tree().quit(0 if _failures == 0 else 1)
