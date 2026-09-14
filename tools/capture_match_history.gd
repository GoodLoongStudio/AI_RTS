extends Node

## 历史对局页面视觉取证：**必须带窗口**才能出图（headless 拿不到帧，存出来全黑）。
##
## 用法（窗口移到屏幕外，不抢前台）：
##   godot --path . --position -4000,-4000 res://tools/capture_match_history.tscn -- --res=1280x720
## 输出：res://tmp_ui_shots/match_history_<res>/*.png
##
## 两条纪律：
## 1. 数据用**探针自己的临时档案**重新播种。玩家真实档案可能被并行会话写脏，
##    取证要的是"确定性的 10 场 Demo"，不是"这台机器上当前的存档"。
## 2. 带窗口运行时 `--resolution` 对本项目不生效（project 设了 viewport 1920x1080
##    且没有 window override），必须在这里显式改 `get_window().size`。

const SHOT_DIR := "res://tmp_ui_shots"
const DEFAULT_RES := "1280x720"
const DETAIL_SCENE := "res://source/main-menu/MatchDetail.tscn"
const LIST_SCENE := "res://source/main-menu/MatchHistory.tscn"
## 与 MatchDetail.gd 的 TABS 一一对应；文件名用 ASCII，避免路径编码问题。
const TAB_SLUGS := ["overview", "economy", "production", "combat", "timeline", "growth_hermes"]

var _shot_dir := SHOT_DIR


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	var spec := _requested_resolution()
	var size := _parse_size(spec)
	if size != Vector2i.ZERO:
		get_window().size = size
		for _i in range(3):
			await get_tree().process_frame
	_seed_isolated_store()
	var dir := "%s/match_history_%s" % [SHOT_DIR, spec]
	DirAccess.make_dir_recursive_absolute(dir)
	_shot_dir = dir
	await _capture_list()
	await _capture_detail_tabs()
	await _capture_aborted()
	print("[CAPTURE] >>> done | display=%s viewport=%s dir=%s" % [
		DisplayServer.get_name(), str(get_viewport().get_visible_rect().size), dir,
	])
	SmokeTestExit.request(get_tree(), 0)


func _requested_resolution() -> String:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--res="):
			return arg.substr("--res=".length())
	return DEFAULT_RES


func _parse_size(spec: String) -> Vector2i:
	var parts := spec.split("x", false)
	if parts.size() != 2:
		return Vector2i.ZERO
	return Vector2i(int(parts[0]), int(parts[1]))


## 切到探针专用临时档案并重新播种 10 场 Demo，与玩家真实档案隔离。
func _seed_isolated_store() -> void:
	var store: Node = get_node_or_null("/root/MatchReportStore")
	if store == null:
		print("[CAPTURE] MatchReportStore 未加载")
		return
	var save_path := "user://capture_match_history.json"
	var legacy_path := "user://capture_match_history_legacy.json"
	DirAccess.remove_absolute(ProjectSettings.globalize_path(save_path))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(legacy_path))
	store.configure_paths(save_path, legacy_path)
	print("[CAPTURE] 隔离档案已就绪：%d 条" % (store.reports as Array).size())


## 按 outcome / hermes 状态挑一条报告 id。
func _pick(outcome: String, hermes_status: String) -> String:
	var store: Node = get_node_or_null("/root/MatchReportStore")
	if store == null:
		return ""
	for report in store.reports:
		var entry: Dictionary = report
		if outcome != "" and str(entry.get("outcome", "")) != outcome:
			continue
		var hermes: Dictionary = entry.get("hermes_analysis", {}) if entry.get("hermes_analysis", {}) is Dictionary else {}
		if hermes_status != "" and str(hermes.get("status", "")) != hermes_status:
			continue
		return str(entry.get("report_id", ""))
	return ""


func _capture_list() -> void:
	MatchHistoryNav.reset()
	var page := await _open(LIST_SCENE)
	if page == null:
		return
	await _shoot("01_list")
	page.queue_free()
	await get_tree().process_frame


func _capture_detail_tabs() -> void:
	var report_id := _pick("victory", "completed")
	if report_id.is_empty():
		print("[CAPTURE] 找不到「已分析的胜局」，跳过详情页取证")
		return
	var offset := _scroll_offset()
	for tab in range(TAB_SLUGS.size()):
		MatchHistoryNav.open_detail(report_id, tab)
		var page := await _open(DETAIL_SCENE)
		if page == null:
			return
		await _apply_scroll(page, offset)
		var suffix := ""
		if offset > 0:
			suffix = "_s%d" % offset
		await _shoot("02_detail_%02d_%s%s" % [tab, TAB_SLUGS[tab], suffix])
		page.queue_free()
		await get_tree().process_frame


## 可选参数：`--scroll=<px>` —— 把详情页滚动容器下移指定像素后再截图。
##
## 为什么需要它：详情页内容天然超过 1280×720，新加的分区常落在**折叠线以下**，
## 不滚动就永远只能拿到页面上半段的画面证据（"探针说有，截图看不见"）。
func _scroll_offset() -> int:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--scroll="):
			return int(arg.substr("--scroll=".length()))
	return 0


func _apply_scroll(page: Node, offset: int) -> void:
	if offset <= 0:
		return
	# ⚠️ 详情页是**每个标签页各一个 ScrollContainer**，共用一个页面节点。
	# 按 `bars[0]` 取会永远滚到不可见的 Tab0 ⇒ 截图前后字节完全一致（实测踩过）。
	# 必须挑 `is_visible_in_tree()` 的那个。
	var bars := page.find_children("*", "ScrollContainer", true, false)
	var target: ScrollContainer = null
	for node in bars:
		if (node as ScrollContainer).is_visible_in_tree():
			target = node as ScrollContainer
			break
	if target == null:
		print("[CAPTURE] 没有可见的 ScrollContainer（共 %d 个），--scroll 被忽略" % bars.size())
		return
	target.scroll_vertical = offset
	# 滚动是下一帧才生效的布局变化，必须等它落定再截图，否则拍到的还是旧位置。
	await get_tree().process_frame
	await get_tree().process_frame
	print("[CAPTURE] scroll: 请求 %d，实际 %d（可滚范围 %.0f）"
		% [offset, target.scroll_vertical, target.get_v_scroll_bar().max_value])
	if target.scroll_vertical != offset:
		print("[CAPTURE] 滚动未落在请求值上：该页可滚范围不足，截图会比预期更靠上")


func _capture_aborted() -> void:
	## 半途退出的对局：DataCompleteness 低、Hermes 无分析 —— 空状态取证。
	var report_id := _pick("aborted", "")
	if report_id.is_empty():
		print("[CAPTURE] 找不到「半途退出」的对局，跳过")
		return
	for tab in [0, 5]:
		MatchHistoryNav.open_detail(report_id, tab)
		var page := await _open(DETAIL_SCENE)
		if page == null:
			return
		await _shoot("03_aborted_%02d_%s" % [tab, TAB_SLUGS[tab]])
		page.queue_free()
		await get_tree().process_frame


func _open(path: String) -> Node:
	if not ResourceLoader.exists(path):
		print("[CAPTURE] 缺场景：%s" % path)
		return null
	var page := (load(path) as PackedScene).instantiate()
	add_child(page)
	for _i in range(4):
		await get_tree().process_frame
	return page


func _shoot(name: String) -> void:
	await RenderingServer.frame_post_draw
	var image := get_viewport().get_texture().get_image()
	var out := "%s/%s.png" % [_shot_dir, name]
	var err := image.save_png(out)
	print("[CAPTURE] %s -> %s (err=%d size=%s)" % [name, out, err, str(image.get_size())])
