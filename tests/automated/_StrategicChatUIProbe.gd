extends Node

## 阶段1 可见实例验收（2026-10-04 生命周期修复版）：
## ① 有界等待副官面板安装完成（5 个聊天节点全部有效，超时非零退出）；
## ② 全场景 [UIPROBE] 验收行：展开/发送/回复/暂停(时钟冻结)/超时/503/重复点击/零副作用；
## ③ 状态文案断言：首条真实回复后顶部不得再有"副官尚未启动"，必须出现"战略聊天可用"；
## ④ 关闭/重开聊天区、结束 Match 重新进入：新 conversation_id、旧会话历史清空；
## ⑤ 退出前清理本探针创建的 Match 与适配层。
## 本探针必须以**可见实例**运行（headless 下面板不安装，直接失败退出——这是产品语义）。

const SHOT_DIR := "agent/runs/2026-10-04-stage1-fix/screenshots"
const INSTALL_WAIT_S := 30.0
const _STUB_BASE := 18400

var _match: Node
var _human: Node
var _button: Node
var _adapter: Node = null
var _stub_seq := 0
var _fails := 0


func _ready() -> void:
	if DisplayServer.get_name() == "headless":
		print("[UIPROBE] FAIL 本探针需要可见实例（headless 下副官面板不安装，无法验收 UI）")
		get_tree().quit(1)
		return
	await _build_match()
	var install_ok: bool = await _wait_for_install()
	if not install_ok:
		print("[UIPROBE] FAIL 副官面板 %ds 内未完成安装（_chat_* 节点不齐）" % int(INSTALL_WAIT_S))
		_cleanup()
		get_tree().quit(1)
		return
	print("[UIPROBE] 面板安装完成：section/adapter/input/status/send 全部有效")

	var tank: Node3D = await _spawn_tank(Vector3(30, 0, 30))
	tank.find_child("Selection").select()

	# ── 场景 1：展开聊天区（初始态）──
	_button._toggle_chat()
	_check(_button._chat_section.visible, "展开后聊天区可见")
	await _shot("01_opened.png", "初始展开态")

	# ── 场景 2：发送第 1 问 → 等待战略层 ──
	var clock: Node = _match.get_node("SimulationClock")
	var conv_before: String = _adapter.conversation_id
	print("[UIPROBE] 会话=%s 模拟时钟=%dms" % [conv_before, clock.get_msec()])
	_button._chat_input.text = "这局的战略重点应该是什么？"
	_button._on_chat_send_pressed()
	var busy: bool = _button._chat_busy
	print("[UIPROBE] 发送后 busy=%s 状态行=%s" % [str(busy), _button._chat_status_label.text])
	_check(busy, "发送后应处于等待状态（防重复提交）")
	await _shot("02_waiting.png", "等待战略层")
	var waited: float = await _wait_reply(60.0)
	print("[UIPROBE] 第1问回复耗时=%.1fs 状态=%s" % [waited, _button._chat_status_label.text])
	_check(waited < 60.0, "第1问应在超时前收到回复")

	# ── 场景 3：状态文案断言（复核第 3 项的核心）──
	var title_text: String = str(_button._title_label.text)
	print("[UIPROBE] 回复后：标题=%s 状态行=%s" % [title_text, _button._chat_status_label.text])
	_check(not title_text.contains("副官尚未启动"), "回复成功后标题不得再显示副官尚未启动")
	_check(title_text.contains("战略聊天可用"),
		"标题必须体现战略聊天可用（实际 %s）" % title_text)
	await _shot("03_replied.png", "已回复+状态已更新")

	# ── 场景 4：运行中追问（上下文）──
	_button._chat_input.text = "为什么这个重点比先出击更重要？"
	_button._on_chat_send_pressed()
	waited = await _wait_reply(60.0)
	print("[UIPROBE] 第2问回复：%.1fs 状态=%s" % [waited, _button._chat_status_label.text])
	_check(waited < 60.0, "第2问（上下文追问）应正常回复")

	# ── 场景 5：暂停中聊天（模拟时钟冻结）──
	var gate: Node = _match.get_node_or_null("PauseGate")
	if gate != null and gate.has_method("acquire"):
		gate.acquire("chat_probe")
	else:
		get_tree().paused = true
	await get_tree().create_timer(0.3).timeout
	var clock_before: int = clock.get_msec()
	print("[UIPROBE] 已暂停 模拟时钟=%dms" % clock_before)
	_button._chat_input.text = "暂停期间应该怎么调整战略？"
	_button._on_chat_send_pressed()
	waited = await _wait_reply(60.0)
	var clock_after: int = clock.get_msec()
	var drift: int = clock_after - clock_before
	print("[UIPROBE] 暂停中回复：耗时=%.1fs 时钟 %d→%d（差 %d，必须 0）状态=%s" % [
		waited, clock_before, clock_after, drift, _button._chat_status_label.text])
	_check(drift == 0, "暂停期间模拟时钟必须冻结（差 0）")
	_check(waited < 60.0, "暂停中聊天应正常回复")
	await _shot("04_paused_chat.png", "暂停中聊天")
	if gate != null and gate.has_method("release"):
		gate.release("chat_probe")
	else:
		get_tree().paused = false
	await get_tree().create_timer(0.2).timeout

	# ── 场景 6：超时（挂起桩 + 3s 短超时）──
	var hang_pid: int = await _launch_stub("hang")
	_adapter.request_timeout_s = 3.0
	_adapter.endpoint_override = _stub_endpoint()
	_button._chat_input.text = "这条应该超时（挂起桩）"
	_button._on_chat_send_pressed()
	waited = await _wait_reply(15.0)
	var timeout_status: String = _button._chat_status_label.text
	print("[UIPROBE] 超时态：%.1fs 状态=%s" % [waited, timeout_status])
	_check(timeout_status.contains("超时"), "挂起桩应产生超时错误态")
	await _shot("05_timeout.png", "超时态")
	_kill_stub(hang_pid)

	# ── 场景 7：503（服务异常降级）──
	var p503_pid: int = await _launch_stub("error503")
	_adapter.endpoint_override = _stub_endpoint()
	_button._chat_input.text = "这条应该 503（错误桩）"
	_button._on_chat_send_pressed()
	waited = await _wait_reply(15.0)
	var e503_status: String = _button._chat_status_label.text
	print("[UIPROBE] 503态：%.1fs 状态=%s（游戏仍在运行）" % [waited, e503_status])
	_check(e503_status.contains("503"), "503 应有明确降级文案")
	await _shot("05_error.png", "错误降级态")
	_kill_stub(p503_pid)
	_adapter.endpoint_override = ""

	# ── 场景 8：重复点击抑制 ──
	_adapter.endpoint_override = _real_endpoint()
	_button._chat_input.text = "重复点击抑制测试"
	_button._on_chat_send_pressed()
	var second: Dictionary = _adapter.send("重复请求")
	print("[UIPROBE] 重复点击：second.queued=%s error=%s" % [
		str(second.get("queued")), str(second.get("error_code", ""))])
	_check(not bool(second.get("queued")), "在途期间重复发送必须被抑制")
	waited = await _wait_reply(60.0)
	print("[UIPROBE] 重复场景回复完成：%.1fs" % waited)

	# ── 场景 9：零副作用 ──
	var gateway = _human.get_node_or_null("UnitCommandGateway")
	var my_orders: String = "n/a"
	if gateway != null and gateway.has_method("GetActiveOrderState"):
		my_orders = str(gateway.GetActiveOrderState(tank))
	var res_a = _human.get("resource_a")
	print("[UIPROBE] 零副作用：资源A=%s（未扣） 坦克活动订单=%s（应为空）" % [
		str(res_a), my_orders])
	_check(str(res_a) == "10000", "聊天不得扣除资源")

	# ── 场景 10：关闭/重开聊天区 ──
	_button._toggle_chat()
	_check(not _button._chat_section.visible, "收起后聊天区应隐藏")
	_button._toggle_chat()
	_check(_button._chat_section.visible, "重开后聊天区应可见且历史保留")
	_check(_button._chat_history_box.get_child_count() > 0, "重开后历史应保留")

	# ── 场景 11：结束 Match 重新进入 → 新会话 ──
	var old_conv: String = _adapter.conversation_id
	var old_history_size: int = _adapter.history.size()
	_adapter.cancel_pending()
	_match.queue_free()
	await get_tree().process_frame
	await get_tree().process_frame
	await _build_match(false)
	var install2: bool = await _wait_for_install()
	_check(install2, "重进 Match 后面板应重新安装")
	var new_conv: String = _adapter.conversation_id
	print("[UIPROBE] 重进对局：旧会话=%s(%d条历史) → 新会话=%s" % [
		old_conv, old_history_size, new_conv])
	_check(new_conv != old_conv, "重进对局必须换新 conversation_id")
	_check(_adapter.history.is_empty(), "重进对局必须清空旧历史")
	var tank2: Node3D = await _spawn_tank(Vector3(30, 0, 30))
	tank2.find_child("Selection").select()

	# ── 汇总 ──
	print("[UIPROBE] 全部场景完成 failures=%d" % _fails)
	_cleanup()
	get_tree().quit(1 if _fails > 0 else 0)


func _check(cond: bool, label: String) -> void:
	if cond:
		print("[UIPROBE-PASS] ", label)
	else:
		print("[UIPROBE-FAIL] ", label)
		_fails += 1


func _build_match(reset_adapter := true) -> void:
	var settings = load("res://source/data-model/MatchSettings.gd").new()
	var hs = load("res://source/data-model/PlayerSettings.gd").new()
	hs.controller = Constants.PlayerType.HUMAN
	hs.color = Color.BLUE
	settings.players.append(hs)
	settings.visible_player = 0
	_match = load("res://source/match/Match.tscn").instantiate()
	_match.settings = settings
	_match.map = load("res://source/match/maps/PlainAndSimple.tscn").instantiate()
	add_child(_match)
	get_tree().current_scene = _match
	for _f in range(200):
		await get_tree().physics_frame
	_human = _match.get_node("Players").get_children()[0]
	_button = get_node_or_null("/root/AdjutantButton")
	if reset_adapter and _adapter != null and is_instance_valid(_adapter):
		_adapter.cancel_pending()
		_adapter.queue_free()
		_adapter = null


## 有界等待副官面板安装完成（5 个聊天节点全部有效；headless 直接 false）。
func _wait_for_install() -> bool:
	if DisplayServer.get_name() == "headless":
		return false
	var waited := 0.0
	while waited < INSTALL_WAIT_S:
		_button = get_node_or_null("/root/AdjutantButton")
		var panel: Control = _button._panel if _button != null else null
		var adapter: Node = _button._chat_adapter if _button != null else null
		if panel != null and is_instance_valid(panel) \
				and adapter != null and is_instance_valid(adapter) \
				and _button._chat_section != null and is_instance_valid(_button._chat_section) \
				and _button._chat_input != null and _button._chat_status_label != null \
				and _button._chat_send_button != null:
			_adapter = adapter
			return true
		await get_tree().create_timer(0.25).timeout
		waited += 0.25
	return false


func _wait_reply(timeout_s: float) -> float:
	var waited := 0.0
	while _button._chat_busy and waited < timeout_s:
		await get_tree().create_timer(0.25).timeout
		waited += 0.25
	return waited


func _stub_endpoint() -> String:
	return "http://127.0.0.1:%d/v1" % int(_adapter.get_meta("stub_port", 0))


func _real_endpoint() -> String:
	return ""


func _launch_stub(mode: String) -> int:
	_stub_seq += 1
	var port: int = _STUB_BASE + _stub_seq
	var pid: int = OS.create_process("python", PackedStringArray([
		"tests/automated/_stub_strategic_model.py", str(port), mode]), false)
	var waited := 0.0
	while waited < 5.0:
		await get_tree().create_timer(0.2).timeout
		waited += 0.2
		var peer := StreamPeerTCP.new()
		if peer.connect_to_host("127.0.0.1", port) == OK:
			peer.poll()
			var connected: bool = int(peer.get_status()) == int(StreamPeerTCP.STATUS_CONNECTED)
			peer.disconnect_from_host()
			if connected:
				_adapter.set_meta("stub_port", port)
				return pid
	return -1


func _kill_stub(pid: int) -> void:
	if pid > 0 and OS.is_process_running(pid):
		OS.kill(pid)


func _spawn_tank(pos: Vector3) -> Node3D:
	var inst = load("res://source/match/units/Tank.tscn").instantiate()
	MatchSignals.setup_and_spawn_unit.emit(inst, Transform3D(Basis.IDENTITY, pos), _human)
	for _f in range(3):
		await get_tree().physics_frame
	return inst


func _shot(filename: String, label: String) -> void:
	await get_tree().process_frame
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var image := get_viewport().get_texture().get_image()
	var path := "%s/%s" % [SHOT_DIR, filename]
	DirAccess.make_dir_recursive_absolute("res://" + SHOT_DIR)
	image.save_png("res://" + path)
	print("[UIPROBE] 截图[%s] %s" % [label, ProjectSettings.globalize_path("res://" + path)])


func _cleanup() -> void:
	if _adapter != null and is_instance_valid(_adapter):
		_adapter.cancel_pending()
	if _match != null and is_instance_valid(_match):
		_match.queue_free()
	await get_tree().process_frame
