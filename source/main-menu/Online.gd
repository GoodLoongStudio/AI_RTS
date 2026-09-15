extends "res://source/main-menu/MatchSetupPage.gd"

## 在线匹配页（统一大厅布局的 online 实例，共享布局见 MatchSetupPage.tscn/.gd）。
##
## RA3 式联机大厅：左侧 4 个玩家槽位（颜色/昵称/准备状态，房主可加撤 AI），
## 右侧地图卡（预览/名称/人数/尺寸，仅房主可选），顶部昵称，底部准备与房主开局。
## 槽位与地图状态由服务器全量广播；客户端只读展示，不覆盖服务器状态。


func _extend_ready() -> void:
	_host_edit.text = NetSession.DEFAULT_HOST
	_port_edit.text = str(NetSession.DEFAULT_PORT)
	_name_edit.text = NetSession.local_player_name
	_status_label.text = NetSession.get_status()
	NetSession.status_changed.connect(_on_status_changed)
	NetSession.lobby_updated.connect(_on_lobby_updated)
	NetSession.lobby_map_changed.connect(_on_lobby_map_changed)
	_refresh_connection_ui()
	var args := OS.get_cmdline_user_args()
	# 正式联机入口默认直接连接云端局服，避免玩家误进入本机 listen server。
	# 自动化仍可用 --autojoin 覆盖为连接后立即开局；本机房仅显式调试参数开放。
	if not NetSession.is_networked() and not args.has("--allow-local-host") \
			and not args.has("--autolobby"):
		call_deferred("_on_join_button_pressed")
	# 调试钩子：-- --autolobby 直接本机开房（可带 --port N 指定端口），供自动化截图与自测。
	if args.has("--autolobby"):
		var port := _automation_port()
		_port_edit.text = str(port)
		NetSession.host(port)
	# 调试钩子：-- --autojoin（或 res://autojoin.txt 存在）直接加入默认服务器并立即开局，
	# 供 Godot MCP 一键开出「已在对局中」的游戏窗口。
	if args.has("--autojoin"):
		_auto_join_solo()
	# 调试控制端点已改为 autoload 自挂载（project.godot 注册，带 --debugport 才启用），
	# 客户端与专用服进程均可使用，此处不再手动挂载。
	if args.has("--autoshot"):
		_auto_screenshot()
	if args.has("--smokeclient"):
		# 冒烟监控挂 root（不随场景切换释放），逻辑全在 SmokeClient.gd。
		var smoke := Node.new()
		smoke.set_script(load("res://source/net/SmokeClient.gd"))
		get_tree().root.add_child.call_deferred(smoke)


func _process(_delta: float) -> void:
	# ENet 状态可能在信号回调与场景切换之间变化；持续校正一次即可避免
	# 出现“已连接”但仍显示“加入局服”的不可点击假状态。
	var connected := NetSession.is_networked()
	if connected != _last_connection_state:
		_last_connection_state = connected
		_refresh_connection_ui()


# ---------------- 地图选择（房主权威 + 客户端只读同步） ----------------

## 房主改图：走服务器权威广播；客户端下拉本身不可用（_map_select.disabled）。
func _on_map_changed(path: String) -> void:
	if not NetSession.is_networked() or not NetSession.is_room_owner():
		return
	NetSession.set_lobby_map(path)


## 客户端收到服务器地图同步：只更新展示，不回写服务器状态。
func _on_lobby_map_changed(path: String) -> void:
	var idx := _map_paths.find(path)
	if _map_select != null and idx >= 0:
		_map_select.select(idx)
	_refresh_map_view()


# ---------------- 连接状态与大厅控件 ----------------

func _refresh_connection_ui() -> void:
	var connected := NetSession.is_networked()
	_last_connection_state = connected
	var is_host := NetSession.is_room_owner()
	# 两段式流程（2026-09-05）：未连接只给「加入局服」；
	# 进房后才出现 地图/槽位/准备，开局按钮仅房主可见。
	_join_button.visible = not connected
	# 本机 listen server 不属于 Hermes 云端托管链路；仅显式调试时显示。
	_local_host_button.visible = not connected \
		and OS.get_cmdline_user_args().has("--allow-local-host")
	_host_row.visible = not connected
	_ready_button.visible = connected
	_start_button.visible = connected and is_host
	_main_row.visible = connected
	_name_edit.editable = not connected
	if _map_select != null:
		_map_select.disabled = not connected or not is_host
	# 连接/断开/重连后都要把准备按钮文案拉回权威状态。
	_refresh_ready_button()


func _on_status_changed(text: String) -> void:
	_status_label.text = text
	# 连接状态由 NetSession 异步回调产生；同步刷新大厅控件，
	# 否则会出现“已连接，请点准备”但仍显示“加入局服”的假死界面。
	_refresh_connection_ui()


func _on_join_button_pressed() -> void:
	if NetSession.is_networked():
		_refresh_connection_ui()
		return
	# 加入局服 = 只进大厅，绝不自动开局：先清掉任何残留的单人开局意图。
	NetSession.clear_auto_start_intent()
	var err := NetSession.join(_host_edit.text.strip_edges(), _port())
	if err != OK:
		_status_label.text = "连接失败：%s" % err


## 本机开房（单人测试）：不连云服，本机即服即玩；默认只保留本机人类。
## AI 必须由房主在槽位上显式点击「＋AI」后才加入。
func _on_local_host_button_pressed() -> void:
	NetSession.clear_auto_start_intent()
	var err := NetSession.host(_port())
	if err != OK:
		_status_label.text = "本机开房失败（端口被占用？）：%s" % err
	else:
		_status_label.text = "本机房已开：默认仅 1 名玩家；需要电脑时请在槽位上点击「＋AI」"


func _on_ready_button_pressed() -> void:
	# 准备状态必须**可撤销**（用户 2026-09-15 要求：“已准备也要能取消准备”）。
	# 判据取**权威大厅快照**而不是本地翻转：服务器可能拒绝、或状态被他人改动，
	# 本地翻转会与实际状态脱节（按钮显示“已准备”而服务器认的是“未准备”）。
	NetSession.set_ready(not _local_ready())
	_refresh_ready_button()


## 本机玩家（自身槽位）当前是否已准备；没有权威快照时按未准备处理。
func _local_ready() -> bool:
	var slot := NetSession.local_slot
	if slot < 0 or slot >= NetSession.last_lobby_slots.size():
		return false
	return bool((NetSession.last_lobby_slots[slot] as Dictionary).get("ready", false))


## 准备按钮文案由权威状态驱动：未准备 →「准备」，已准备 →「取消准备」。
## 文案写清“点下去会发生什么”，玩家不必猜同一个按钮第二次点的语义。
func _refresh_ready_button() -> void:
	if not NetSession.is_networked():
		_ready_button.text = "准备"
		return
	_ready_button.text = "取消准备" if _local_ready() else "准备"


## 大厅广播后同步按钮文案（槽位卡片由父类刷新，这里只补按钮）。
func _on_lobby_updated(slots: Array) -> void:
	super(slots)
	_refresh_ready_button()


func _on_start_button_pressed() -> void:
	# 立即开局 = 正式单人对局：不隐式添加 AI，开局仅主基地+1无人机+2工人。
	# 需要电脑时由房主先在大厅槽位显式添加 AI，再点击此按钮。
	NetSession.start_solo(false, false)


func _on_name_edit_text_changed(new_text: String) -> void:
	NetSession.set_local_name(new_text)


func _port() -> int:
	return int(_port_edit.text)


## 自动化端口覆盖：--port N 优先（供验收脚本隔离端口，避免占用玩家/默认端口）。
func _automation_port() -> int:
	var args := OS.get_cmdline_user_args()
	var index := args.find("--port")
	if index >= 0 and index + 1 < args.size() and str(args[index + 1]).is_valid_int():
		return int(args[index + 1])
	return _port()


# ---------------- 调试钩子 ----------------

func _auto_screenshot() -> void:
	await get_tree().create_timer(1.5).timeout
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	img.save_png("G:/AIRTS/临时文件夹/deploy_ai_rts/lobby_preview.png")
	print("LOBBY_SHOT saved")
	get_tree().quit()


## 调试钩子：--autojoin 或 res://autojoin.txt 存在时，直接加入默认服务器并立即开局，
## 供 Godot MCP 一键开出「已在对局中」的游戏窗口（免去人工点菜单）。
func _auto_join_solo() -> void:
	# 冒烟测试可通过 --smokehost/--smokeport 指向本机专用服；普通
	# --autojoin 仍使用大厅默认的云端地址。
	var args := OS.get_cmdline_user_args()
	var host := NetSession.DEFAULT_HOST
	var port := NetSession.DEFAULT_PORT
	var host_index := args.find("--smokehost")
	if host_index >= 0 and host_index + 1 < args.size():
		host = str(args[host_index + 1])
	var port_index := args.find("--smokeport")
	if port_index >= 0 and port_index + 1 < args.size():
		port = int(args[port_index + 1])
	_host_edit.text = host
	_port_edit.text = str(port)
	_on_join_button_pressed()
	var waited := 0
	while waited < 60:
		await get_tree().create_timer(1.0).timeout
		waited += 1
		if not NetSession.is_networked():
			continue
		if NetSession.local_slot >= 0:
			if args.has("--autojoin-lobby"):
				_status_label.text = "已连接，等待调试开局…"
				return
			_status_label.text = "自动开局中…"
			NetSession.start_solo()
			return
	_status_label.text = "自动加入超时"
