extends Node

## 预览与出生点标记探针（RSI round-03 ✓）：
## ① 4 个标记必须**按世界坐标**映射到预览内（不是平均撒点 ✓）；
## ② 尺寸标签必须显示 尺寸 W×H（不能显示地图路径 ✗）；
## ③ 预览图存在 ⇒ 缺失态隐藏 ✓；预览图不存在（用生成图 ✓）⇒ 缺失态**可见** ✓。

const PAGE := "res://source/main-menu/StrategicSandboxPage.tscn"

var _failures := 0


func _process(_delta: float) -> void:
	if get_tree().paused:
		get_tree().paused = false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	get_tree().create_timer(180.0).timeout.connect(func() -> void:
		push_error("[PREVIEW] 超时")
		get_tree().quit(2))
	await _run()


func _run() -> void:
	# 第一张：PlainAndSimple（有预览图 ✓）
	await _check_page("res://source/match/maps/PlainAndSimple.tscn", true)
	# 第二张：生成图（前缀路径下大概率没有预览 ✓ ⇒ 验证缺失态 ✓）
	var generated := ""
	var all: Array = MatchSetupShared.map_paths()
	for mp in all:
		if str(mp).contains("generated"):
			generated = str(mp)
			break
	if generated != "":
		await _check_page(generated, true)   # 生成图也有预览（7 张 ✓）⇒ 缺失态应隐藏
	# 缺失态分支直接验证 ✓（提示词要求：无预览时必须有明确状态，不能留空白）
	await _check_missing_branch()
	await _check_cards_and_facts()
	await _check_chat_gating()
	print("Strategic preview probe completed: %d failure(s)" % _failures)
	get_tree().quit(0 if _failures == 0 else 1)


## 未选出生点时聊天必须禁用 ✓；选点后启用 + 历史里出现副官欢迎语 ✓（提示词 §3 右栏 2/3）。
## 出生点卡片信息 + 事实分组 + 「没有启动对局链路」的证明 ✓（提示词 §2/§3）。
func _check_cards_and_facts() -> void:
	var page: Control = load(PAGE).instantiate()
	page.set("map_path", "res://source/match/maps/PlainAndSimple.tscn")
	add_child(page)
	page.set_anchors_preset(Control.PRESET_FULL_RECT)
	page.size = Vector2(1600, 900)
	for _f in range(16):
		await get_tree().process_frame
	# ① 卡片信息 ✓
	var seen_bearing := 0
	var seen_res := 0
	for i in range(1, 5):
		var info: Label = page.find_child("SpawnInfo%d" % i, true, false)
		if info == null:
			_check(false, "出生点卡片 %d 必须有信息标签" % i)
			continue
		print("[PREVIEW] 卡片%d: %s" % [i, info.text.replace("\n", " / ")])
		if info.text.contains("方位"): seen_bearing += 1
		if info.text.contains("附近资源"): seen_res += 1
	_check(seen_bearing == 4, "4 张出生点卡片都要有方位描述（实际 %d）" % seen_bearing)
	_check(seen_res == 4, "4 张出生点卡片都要有附近资源行（实际 %d）" % seen_res)
	# ② 事实分组已填充 ✓
	var fk: Label = page.get("_facts_known")
	var fu: Label = page.get("_facts_unknown")
	_check(fk != null and fk.text.strip_edges() != "", "「已知地图事实」必须已填充（实际 %s）" % (fk.text.substr(0, 40) if fk != null else "<none>"))
	_check(fu != null and fu.text.strip_edges() != "", "「当前未知信息」必须已填充（实际 %s）" % (fu.text.substr(0, 40) if fu != null else "<none>"))
	print("[PREVIEW] 已知事实 = %s" % (fk.text.replace("\n", " / ").substr(0, 110) if fk != null else "<none>"))
	print("[PREVIEW] 未知信息 = %s" % (fu.text.replace("\n", " / ").substr(0, 110) if fu != null else "<none>"))
	# ③ 没有启动对局链路 ✓
	var root := get_tree().root
	_check(root.find_child("Match", true, false) == null, "不得创建 Match ✓")
	_check(root.find_child("SimulationClock", true, false) == null, "不得创建 SimulationClock ✓")
	_check(not NetSession.is_networked(), "不得调用 NetSession.host()（is_networked 必须为 false ✓）")
	# 【提示词 §6-10】还要证明**没有玩家/单位/资源实例** ✓
	var instance_check := {}
	for group in ["units", "players", "revealed_units", "resources", "obstacles"]:
		instance_check[group] = get_tree().get_nodes_in_group(group).size()
	for name in ["Players", "Units", "Resources", "SimulationClock", "Match", "Loading"]:
		instance_check[name] = root.find_child(name, true, false) != null
	print("[PREVIEW] 实例检查: %s" % JSON.stringify(instance_check))
	_check(int(instance_check["players"]) == 0, "不得有玩家实例（groups/players=%d）" % int(instance_check["players"]))
	_check(int(instance_check["units"]) == 0, "不得有单位实例（groups/units=%d）" % int(instance_check["units"]))
	_check(int(instance_check["resources"]) == 0, "不得有资源实例（groups/resources=%d）" % int(instance_check["resources"]))
	_check(not bool(instance_check["Players"]) and not bool(instance_check["Units"]) and not bool(instance_check["Resources"]), "不得存在 Players/Units/Resources 节点 ✓")
	_check(not bool(instance_check["Loading"]), "不得进入 Loading 链路 ✓")
	print("[PREVIEW] 对局链路检查: Match=%s SimulationClock=%s networked=%s" % [
		str(root.find_child("Match", true, false) != null),
		str(root.find_child("SimulationClock", true, false) != null),
		str(NetSession.is_networked())])
	page.queue_free()
	for _f in range(6):
		await get_tree().process_frame


func _check_chat_gating() -> void:
	var page: Control = load(PAGE).instantiate()
	page.set("map_path", "res://source/match/maps/PlainAndSimple.tscn")
	add_child(page)
	page.set_anchors_preset(Control.PRESET_FULL_RECT)
	page.size = Vector2(1600, 900)
	for _f in range(16):
		await get_tree().process_frame
	var input: LineEdit = page.get("_chat_input")
	var send: Button = page.get("_chat_send")
	var history: VBoxContainer = page.get("_chat_history")
	_check(input != null and send != null, "必须有聊天输入框与发送按钮")
	if input == null or send == null:
		page.queue_free()
		return
	_check(input.editable == false and send.disabled, "未选出生点时输入与发送必须 disabled（editable=%s disabled=%s）" % [str(input.editable), str(send.disabled)])
	_check(input.placeholder_text.contains("出生点"), "未选点时提示文案应要求先选出生点（实际 %s）" % input.placeholder_text)
	page.call("_on_spawn_selected", 2)
	for _f in range(8):
		await get_tree().process_frame
	_check(input.editable and not send.disabled, "选点后输入与发送必须启用（editable=%s disabled=%s）" % [str(input.editable), str(send.disabled)])
	# 【口径修正】选点会 clear() 旧历史再写欢迎语 ⇒ 比行数没意义 ✗，要看**内容** ✓
	if history != null:
		# 历史行用的是 RichTextLabel ✓（不是 Label ✗）⇒ 两种都要扫 ✓
		var text_all := ""
		for child in history.get_children():
			if child is RichTextLabel:
				text_all += (child as RichTextLabel).text + "\n"
			elif child is Label:
				text_all += (child as Label).text + "\n"
			for sub in child.find_children("*", "RichTextLabel", true, false):
				text_all += (sub as RichTextLabel).text + "\n"
			for sub2 in child.find_children("*", "Label", true, false):
				text_all += (sub2 as Label).text + "\n"
		_check(text_all.contains("出生点") and text_all.contains("副官"), "选点后历史里应出现副官欢迎语（实际含出生点=%s）" % str(text_all.contains("出生点")))
		print("[PREVIEW] 历史首行片段 = %s" % text_all.strip_edges().substr(0, 90).replace("\n", " / "))
	_check(int(page.get("_selected_spawn")) == 2, "选点应记录为出生点索引 2（实际 %s）" % str(page.get("_selected_spawn")))
	page.queue_free()
	for _f in range(6):
		await get_tree().process_frame


func _check_missing_branch() -> void:
	var page: Control = load(PAGE).instantiate()
	page.set("map_path", "res://source/match/maps/PlainAndSimple.tscn")
	add_child(page)
	page.set_anchors_preset(Control.PRESET_FULL_RECT)
	page.size = Vector2(1600, 900)
	for _f in range(12):
		await get_tree().process_frame
	var missing: Label = page.find_child("PreviewMissing", true, false)
	_check(missing != null, "必须有 PreviewMissing 节点")
	if missing != null:
		page.call("_show_preview_missing", "res://assets/map_previews/__missing__.png", "尚未生成")
		await get_tree().process_frame
		_check(missing.visible and missing.text.contains("__missing__"), "缺失态必须可见并带上缺失路径（实际 %s）" % missing.text.replace("\n", " / "))
	page.queue_free()
	for _f in range(6):
		await get_tree().process_frame


func _check_page(map_path: String, expect_preview: bool) -> void:
	var page: Control = load(PAGE).instantiate()
	page.set("map_path", map_path)
	add_child(page)
	page.set_anchors_preset(Control.PRESET_FULL_RECT)
	page.size = Vector2(1600, 900)
	for _f in range(20):
		await get_tree().process_frame
	var world: Vector2 = page.call("_map_world_size")
	var spawns: Array = (page.get("_intel") as Dictionary).get("spawn_points", [])
	var frame: Control = page.find_child("MapPreviewWithMarkers", true, false)
	var missing: Label = page.find_child("PreviewMissing", true, false)
	var size_label: Variant = page.get("_map_size_label")
	print("[PREVIEW] map=%s 世界=%s 出生点=%d 预览容器=%s 缺失标签=%s" % [
		map_path.get_file(), str(world), spawns.size(), str(frame != null), str(missing != null)])
	if size_label is Label:
		print("[PREVIEW] 尺寸标签 = %s" % (size_label as Label).text)
		_check((size_label as Label).text.begins_with("尺寸 "), "尺寸标签必须显示尺寸（实际 %s）" % (size_label as Label).text)
	# 标记按世界坐标映射 ✓
	var ok_positions := 0
	for i in range(mini(4, spawns.size())):
		var mk: Label = page.find_child("SpawnMarker%d" % (i + 1), true, false)
		if mk == null or not mk.visible:
			_check(false, "出生点标记 %d 必须存在且可见" % (i + 1))
			continue
		var sp: Dictionary = spawns[i]
		var uv := Vector2(float(sp["world_x"]) / maxf(1.0, world.x), float(sp["world_z"]) / maxf(1.0, world.y))
		var expect := uv * frame.size
		var actual: Vector2 = mk.position + mk.size * 0.5
		var dist := actual.distance_to(expect)
		print("[PREVIEW] 标记%d 世界=(%.1f,%.1f) uv=(%.3f,%.3f) 期望像素=(%.1f,%.1f) 实际=(%.1f,%.1f) 差=%.2fpx" % [
			i + 1, sp["world_x"], sp["world_z"], uv.x, uv.y, expect.x, expect.y, actual.x, actual.y, dist])
		_check(dist <= 3.0, "标记 %d 必须落在世界坐标映射处（差 %.2fpx）" % [i + 1, dist])
		ok_positions += 1
	_check(ok_positions == 4, "必须放置 4 个出生点标记（实际 %d）" % ok_positions)
	# 【用户要求 + 塌陷防线】预览必须**可见且近方形**（208×208 地图 ⇒ 正方形 ✓）
	# 【防假通过 ✓】frame 必须存在；不存在就是失败 ✗（此前 if frame != null 会静默跳过 ✗）
	_check(frame != null, "必须存在 MapPreviewWithMarkers 预览容器")
	if frame != null:
		print("[PREVIEW] 预览容器尺寸 = %s" % str(frame.size))
		_check(frame.size.y >= 100.0, "预览必须可见（高度 ≥100，实际 %.0f）" % frame.size.y)
		var ratio := frame.size.x / maxf(1.0, frame.size.y)
		_check(absf(ratio - 1.0) <= 0.15, "预览必须近方形（宽高比 %.2f，应 ≈1.00）" % ratio)
	# 缺失态 ✓
	if missing != null:
		if expect_preview:
			_check(not missing.visible, "有预览图时缺失态必须隐藏")
		else:
			_check(missing.visible, "无预览图时**必须显示缺失态**（不能留空白冒充成功）")
			print("[PREVIEW] 缺失态文案 = %s" % missing.text.replace("\n", " / "))
	page.queue_free()
	for _f in range(6):
		await get_tree().process_frame


func _check(cond: bool, msg: String) -> void:
	if cond:
		print("[PREVIEW] OK: " + msg)
	else:
		_failures += 1
		push_error("[PREVIEW] FAIL: " + msg)
