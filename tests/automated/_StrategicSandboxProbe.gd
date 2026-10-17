extends Node

## 战略沙盒模式探针（2026-10-05）：验证入口 + 无对局证明 + 5 轮 + 重进。
## 不用 change_scene_to_file（会释放探针自身）；改用 add_child 挂载页面。

const PLAY_SCENE := "res://source/main-menu/Play.tscn"
const SANDBOX_SCENE := "res://source/main-menu/StrategicSandboxPage.tscn"
const ChatService = preload("res://source/ui/AdjutantChatService.gd")
const ModelService = preload("res://source/ui/AdjutantModelService.gd")

var _fails := 0
var _pages: Array = []


func _check(cond: bool, label: String) -> void:
	if cond:
		print("[SB-PASS] ", label)
	else:
		print("[SB-FAIL] ", label)
		_fails += 1


func _shot(filename: String, label: String) -> void:
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var image := get_viewport().get_texture().get_image()
	DirAccess.make_dir_recursive_absolute("res://agent/runs/2026-10-05-sandbox/screenshots")
	image.save_png("res://agent/runs/2026-10-05-sandbox/screenshots/" + filename)
	print("[SB] 截图[%s] %s" % [label, filename])


func _ready() -> void:
	if DisplayServer.get_name() == "headless":
		print("[SB] FAIL 需要可见实例")
		get_tree().quit(1)
		return

	# ── 1. 加载 Play 页面（add_child 不用 change_scene）──
	var play_page: Node = load(PLAY_SCENE).instantiate()
	get_tree().root.add_child(play_page)
	_pages.append(play_page)
	await get_tree().create_timer(1.5).timeout
	print("[SB] Play 页加载完成")

	# ── 2. 验证三按钮 ──
	var vbox: Node = play_page.get_node_or_null("CenterContainer/PanelContainer/MarginContainer/VBoxContainer")
	_check(vbox != null, "Play 页布局存在")
	var start_btn: Button = null
	var sandbox_btn: Button = null
	var back_btn: Button = null
	if vbox != null:
		start_btn = vbox.get_node_or_null("ReadyRow/StartButton")
		back_btn = vbox.get_node_or_null("BackButton")
	# .tscn 硬编码节点：按路径直接获取（不依赖 _apply_mode deferred 创建）
	if vbox != null:
		sandbox_btn = vbox.get_node_or_null("SandboxButton")
	_check(start_btn != null, "开始游戏按钮存在")
	_check(sandbox_btn != null, "战略模式（测试）按钮存在")
	_check(back_btn != null, "返回按钮存在")
	var ready_idx: int = vbox.get_children().find(start_btn.get_parent()) if start_btn != null else -1
	var sandbox_idx: int = vbox.get_children().find(sandbox_btn) if sandbox_btn != null else -1
	var back_idx: int = vbox.get_children().find(back_btn) if back_btn != null else -1
	_check(ready_idx >= 0 and sandbox_idx > ready_idx and back_idx > sandbox_idx,
		"顺序：开始→战略→返回")
	await _shot("01_menu_3buttons.png", "菜单三按钮")

	# ── 3. 点击战略模式 → 无对局证明 ──
	# Play 页是 add_child 的，change_scene_to_file 会释放 current_scene（probe 自身）
	# → 不能从 Play 页 emit pressed。改为直接释放 Play 页 + 加载沙盒页。
	for pg in _pages:
		if is_instance_valid(pg):
			pg.queue_free()
	_pages.clear()
	await get_tree().process_frame
	var sandbox_page: Node = load(SANDBOX_SCENE).instantiate()
	get_tree().root.add_child(sandbox_page)
	_pages.append(sandbox_page)
	await get_tree().create_timer(1.0).timeout
	print("[SB] 加载沙盒页 current_scene=%s" % get_tree().current_scene.name)
	_check(not sandbox_page.name.begins_with("Match"), "当前场景不是 Match")
	var sim_clock: Node = sandbox_page.get_node_or_null("SimulationClock")
	_check(sim_clock == null, "无 SimulationClock")
	# autoload（MatchHistoryHook 等）名字也以 Match 开头但不是对局实例；
	# 真正的 Match 有 get_local_player 方法（Match.gd 唯有）。
	var has_match_scene := false
	for child in get_tree().root.get_children():
		if child is Node and child.has_method("get_local_player"):
			has_match_scene = true
	_check(not has_match_scene, "场景树无 Match 游戏实例（autoload 不算）")
	var adapter: Node = sandbox_page.get("_adapter")
	_check(adapter != null, "沙盒适配层已创建")
	if adapter == null:
		print("[SB-DONE] failures=%d" % _fails)
		get_tree().quit(1)
		return

	# 等模型预热或直接用（ModelService.ensure_started 已在页面 _ready 调用）
	print("[SB] 等模型就绪…当前状态=%s" % ModelService.state())
	var warm_waited := 0.0
	while not ModelService.is_ready() and warm_waited < 120.0:
		await get_tree().create_timer(1.0).timeout
		warm_waited += 1.0
	print("[SB] 模型状态=%s（等了 %.0fs）" % [ModelService.state(), warm_waited])

	# ── 4. 冷启动 + 5 轮 ──
	# 选出生点（聊天在选点前禁用是设计行为）
	if sandbox_page.has_method("_on_spawn_selected"):
		sandbox_page._on_spawn_selected(0)
		print("[SB] 已选出生点 0")
	var chat_input: LineEdit = sandbox_page.get("_chat_input")
	var send_btn: Button = sandbox_page.get("_send_button")
	_check(chat_input != null, "沙盒输入框存在")
	var questions := [
		"这局的战略重点应该是什么？",
		"经济和出兵的比例怎么平衡？",
		"如果敌人 Rush 我该怎么防守？",
		"侦察应该什么时候做？",
		"总结你到现在给我的建议。",
	]
	for i in range(questions.size()):
		var q: String = questions[i]
		var hist_before: int = adapter.history.size()
		chat_input.text = q
		sandbox_page._on_send()
		var waited := 0.0
		while sandbox_page._chat_busy and waited < 90.0:
			await get_tree().create_timer(0.25).timeout
			waited += 0.25
		var reply := ""
		for j in range(adapter.history.size() - 1, -1, -1):
			if str(adapter.history[j].get("role")) == "assistant":
				reply = str(adapter.history[j].get("content"))
				break
		var ok := waited < 90.0 and reply.length() > 5
		print("[SB] 第%d轮 ok=%s 等待=%.1fs 字数=%d | %s" % [
			i + 1, str(ok), waited, reply.length(), reply.left(60).replace("\n", " ")])
		if not ok:
			_fails += 1
		await get_tree().create_timer(0.3).timeout
	_check(adapter.history.size() >= 10, "5 轮后历史 ≥ 10 条（实际 %d）" % adapter.history.size())
	await _shot("02_sandbox_5rounds.png", "5 轮对话")

	# ── 5. 返回 → 重进 → 新会话 ──
	var old_conv: String = adapter.conversation_id
	var old_hist: int = adapter.history.size()
	# 释放旧页面和适配层（不用 _cleanup_and_back——那会 change_scene 链锁死探针）
	if adapter != null and is_instance_valid(adapter):
		adapter.cancel_pending()
		adapter.queue_free()
	if is_instance_valid(sandbox_page):
		sandbox_page.queue_free()
	for pg in _pages:
		if is_instance_valid(pg) and pg != sandbox_page:
			pg.queue_free()
	_pages.clear()
	await get_tree().process_frame
	await get_tree().process_frame
	# 直接创建新沙盒页面（add_child，不走 change_scene 链）
	var sandbox2: Node = load(SANDBOX_SCENE).instantiate()
	get_tree().root.add_child(sandbox2)
	_pages.append(sandbox2)
	await get_tree().create_timer(1.5).timeout
	var adapter2: Node = sandbox2.get("_adapter")
	_check(adapter2 != null, "重进后适配层已创建")
	if adapter2 != null:
		var new_conv: String = adapter2.conversation_id
		_check(new_conv != old_conv, "重进换新 conversation_id（旧=%s 新=%s）" % [old_conv, new_conv])
		_check(adapter2.history.is_empty(), "重进历史清空")
	else:
		_fails += 1
	await _shot("03_reentered.png", "重进后")

	# ── 清理 ──
	for pg in _pages:
		if is_instance_valid(pg):
			pg.queue_free()
	_pages.clear()
	await get_tree().process_frame
	print("[SB-DONE] failures=%d" % _fails)
	get_tree().quit(1 if _fails > 0 else 0)
